import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../lib/src/models/detection_result.dart';
import '../lib/src/models/snore_recording_info.dart';
import '../lib/src/services/recording_state_machine.dart';
import '../lib/src/services/recording_storage_service.dart';
import '../lib/src/utils/audio_processor.dart';

void main() {
  late Directory tempDir;
  late RecordingStorageService storage;
  late List<SnoreRecordingInfo> saved;
  late List<Duration> discarded;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('snore_episode_test_');
    storage = RecordingStorageService();
    storage.setCustomRecordingsDirectory(tempDir.path);
    saved = [];
    discarded = [];
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  RecordingStateMachine buildMachine({
    Duration closeSilence = const Duration(seconds: 11),
    Duration minDuration = Duration.zero,
    Duration maxGap = const Duration(seconds: 11),
    bool requireMinEvents = true,
    bool measureFromEnd = true,
  }) {
    return RecordingStateMachine(
      episodeOpenSnoreCount: 3,
      episodeOpenWindow: Duration(
        milliseconds: 2 * maxGap.inMilliseconds + 10000,
      ),
      episodeCloseSilence: closeSilence,
      minEpisodeDuration: minDuration,
      minInterSnoreGap: const Duration(seconds: 2),
      maxInterSnoreGap: maxGap,
      snoreBurstEndSilence: const Duration(seconds: 2),
      requireMinSnoreEventsToSave: requireMinEvents,
      measureGapsFromEventEnd: measureFromEnd,
      storageService: storage,
      onRecordingSaved: saved.add,
      onEpisodeDiscarded: discarded.add,
    );
  }

  DetectionResult snoreResult(bool isSnoring) => DetectionResult(
        isSnoring: isSnoring,
        snoringConfidence: isSnoring ? 0.9 : 0.1,
        noiseConfidence: isSnoring ? 0.1 : 0.9,
      );

  List<int> silentPcm() =>
      List<int>.filled(AudioProcessor.targetSampleRate, 0);

  Future<void> feed(
    RecordingStateMachine sm,
    DateTime t,
    bool isSnoring,
  ) async {
    await sm.processDetectionResult(
      snoreResult(isSnoring),
      silentPcm(),
      now: t,
    );
  }

  /// Snore at [t]; burst ends at t+3 (2s quiet after first non-snore).
  Future<void> feedDiscreteSnore(
    RecordingStateMachine sm,
    DateTime t,
  ) async {
    await feed(sm, t, true);
    await feed(sm, t.add(const Duration(seconds: 1)), false);
    await feed(sm, t.add(const Duration(seconds: 2)), false);
    await feed(sm, t.add(const Duration(seconds: 3)), false);
  }

  /// Open with 3 snores. Burst ends ~t+3; next starts at +7 → end→start gap ≈4s.
  Future<DateTime> openEpisode(RecordingStateMachine sm, DateTime t0) async {
    await feedDiscreteSnore(sm, t0);
    await feedDiscreteSnore(sm, t0.add(const Duration(seconds: 7)));
    await feedDiscreteSnore(sm, t0.add(const Duration(seconds: 14)));
    final hold = t0.add(const Duration(seconds: 18));
    await feed(sm, hold, true);
    expect(sm.state, RecordingState.recording);
    return hold;
  }

  group('RecordingStateMachine episode open', () {
    test('1–2 snores do not open', () async {
      final sm = buildMachine();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);

      await feedDiscreteSnore(sm, t0);
      expect(sm.state, RecordingState.idle);

      await feedDiscreteSnore(sm, t0.add(const Duration(seconds: 7)));
      expect(sm.state, RecordingState.idle);
      await sm.stop();
    });

    test('3 snores with end→start gaps 2–11s open an episode', () async {
      final sm = buildMachine();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);

      await openEpisode(sm, t0);
      expect(sm.isRecording, isTrue);
      await sm.stop();
    });

    test('end→start gap >11s resets candidate and does not open', () async {
      final sm = buildMachine();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);

      // Burst ends t0+3; next at t0+16 → gap 13s > 11
      await feedDiscreteSnore(sm, t0);
      await feedDiscreteSnore(sm, t0.add(const Duration(seconds: 16)));
      await feedDiscreteSnore(sm, t0.add(const Duration(seconds: 32)));

      expect(sm.state, RecordingState.idle);
      expect(sm.isRecording, isFalse);
      await sm.stop();
    });
  });

  group('RecordingStateMachine close / extend', () {
    test('quiet 10s keeps episode; 11s since event end closes', () async {
      final sm = buildMachine();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);

      final hold = await openEpisode(sm, t0);

      final quietStart = hold.add(const Duration(seconds: 1));
      await feed(sm, quietStart, false);
      await feed(sm, quietStart.add(const Duration(seconds: 1)), false);
      await feed(sm, quietStart.add(const Duration(seconds: 2)), false);
      final eventEnd = quietStart.add(const Duration(seconds: 2));

      await feed(sm, eventEnd.add(const Duration(seconds: 10)), false);
      expect(sm.isRecording, isTrue);

      await feed(sm, eventEnd.add(const Duration(seconds: 11)), false);
      expect(sm.state, RecordingState.idle);
      expect(saved.length, 1);
      expect(saved.first.snoreEventCount, greaterThanOrEqualTo(3));
      await sm.stop();
    });

    test('resume within 11s extends same episode', () async {
      final sm = buildMachine();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);

      final hold = await openEpisode(sm, t0);

      final quietStart = hold.add(const Duration(seconds: 1));
      await feed(sm, quietStart, false);
      await feed(sm, quietStart.add(const Duration(seconds: 2)), false);
      expect(sm.state, RecordingState.pendingClose);

      final resume = quietStart.add(const Duration(seconds: 6));
      await feed(sm, resume, true);
      expect(sm.state, RecordingState.recording);
      expect(saved, isEmpty);

      final closeBurst = resume.add(const Duration(seconds: 1));
      await feed(sm, closeBurst, false);
      await feed(sm, closeBurst.add(const Duration(seconds: 2)), false);
      final eventEnd = closeBurst.add(const Duration(seconds: 2));
      await feed(sm, eventEnd.add(const Duration(seconds: 11)), false);

      expect(sm.state, RecordingState.idle);
      expect(saved.length, 1);
      expect(saved.first.snoreEventCount, greaterThanOrEqualTo(4));
      await sm.stop();
    });
  });

  group('RecordingStateMachine discard / save', () {
    test('stop with open episode saves when ≥3 events (no 60s floor)', () async {
      final sm = buildMachine();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);

      await openEpisode(sm, t0);
      await sm.stop();

      expect(discarded, isEmpty);
      expect(saved.length, 1);
      expect(saved.first.snoreEventCount, greaterThanOrEqualTo(3));
      expect(File(saved.first.filePath).existsSync(), isTrue);
    });

    test('5 snores with ~10s end→start gaps save one episode', () async {
      final sm = buildMachine();
      final t0 = DateTime(2026, 1, 1, 1, 0, 0);

      // Burst ends +3; next start +13 → gap ~10s
      await feedDiscreteSnore(sm, t0);
      await feedDiscreteSnore(sm, t0.add(const Duration(seconds: 13)));
      await feedDiscreteSnore(sm, t0.add(const Duration(seconds: 26)));
      expect(sm.isRecording, isTrue);

      await feedDiscreteSnore(sm, t0.add(const Duration(seconds: 39)));
      await feedDiscreteSnore(sm, t0.add(const Duration(seconds: 52)));

      final eventEnd = t0.add(const Duration(seconds: 55));
      await feed(sm, eventEnd.add(const Duration(seconds: 11)), false);

      expect(sm.state, RecordingState.idle);
      expect(saved.length, 1);
      expect(saved.first.snoreEventCount, greaterThanOrEqualTo(5));
      await sm.stop();
    });
  });
}

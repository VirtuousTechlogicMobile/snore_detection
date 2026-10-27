import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:snore_detection/snore_detection.dart';

void main() {
  group('dbfs', () {
    test('silence clamps to floor', () {
      expect(dbfs(List.filled(1600, 0.0)), -120);
    });

    test('full scale is near 0', () {
      final db = dbfs(List.filled(1600, 1.0));
      expect(db, closeTo(0.0, 0.01));
    });

    test('half amplitude is about -6 dB', () {
      final db = dbfs(List.filled(1600, 0.5));
      expect(db, closeTo(20 * math.log(0.5) / math.ln10, 0.01));
    });
  });

  group('LevelMeter', () {
    test('emits one frame per 1600 samples at 16 kHz', () {
      final meter = LevelMeter(sampleRate: 16000, frameMs: 100);
      final frames = meter.addSamples(List.filled(1600, 16384));
      expect(frames, hasLength(1));
      expect(frames.first, lessThan(0));
      expect(frames.first, greaterThan(-20));
      expect(meter.totalSamples, 1600);
    });

    test('counts clipped samples at full scale', () {
      final meter = LevelMeter(sampleRate: 16000, frameMs: 100);
      meter.addSamples([32767, -32768, 0, 100]);
      expect(meter.clippedSamples, 2);
      expect(meter.totalSamples, 4);
    });
  });

  group('episodeLevels', () {
    test('power-domain mean and max over snore events', () {
      // 10 frames: quiet then loud snore window
      final frames = <double>[
        -50, -48, -52, -49, -51, // room
        -16, -14, -15, -13, -17, // snore
      ];
      final levels = episodeLevels(
        frames: frames,
        events: const [SnoreLevelEvent(startMs: 500, endMs: 1000)],
        frameMs: 100,
        clippedSamples: 0,
        totalSamples: 16000,
      );
      expect(levels.noiseFloorDb, closeTo(-52, 0.01)); // 10th pct of 10 → index 0
      expect(levels.snoreLevelDb, greaterThan(-20));
      expect(levels.snoreLevelDb, lessThan(-10));
      expect(levels.maxSnoreDb, closeTo(levels.snoreLevelDb, 0.01));
      expect(levels.clippedPercent, 0);
    });

    test('empty snore frames fall back to -120', () {
      final levels = episodeLevels(
        frames: const [-40.0, -41.0],
        events: const [],
        frameMs: 100,
        clippedSamples: 10,
        totalSamples: 100,
      );
      expect(levels.snoreLevelDb, -120);
      expect(levels.maxSnoreDb, -120);
      expect(levels.clippedPercent, 10);
    });
  });

  group('meanDb', () {
    test('does not understate loud frames vs arithmetic mean of dB', () {
      final dbs = [-10.0, -30.0];
      final powerMean = meanDb(dbs);
      final arithMean = (dbs[0] + dbs[1]) / 2;
      expect(powerMean, greaterThan(arithMean));
    });
  });
}

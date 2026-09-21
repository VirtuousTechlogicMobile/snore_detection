import 'dart:collection';
import 'dart:io';
import '../models/detection_result.dart';
import '../models/snore_recording_info.dart';
import '../utils/wav_writer.dart';
import '../utils/audio_processor.dart';
import 'recording_storage_service.dart';

/// Recording states for episode-based snore capture.
enum RecordingState {
  idle,
  recording,
  pendingClose,
}

/// Timed discrete snore event (start + end/offset).
class _SnoreEventMark {
  DateTime start;
  DateTime end;

  _SnoreEventMark(this.start) : end = start;
}

/// Timed PCM chunk for the rolling pre-open buffer.
class _PcmChunk {
  final DateTime timestamp;
  final List<int> samples;

  _PcmChunk(this.timestamp, this.samples);
}

/// State machine for episode-based recording during live detection.
///
/// Client heuristic (locked defaults):
/// - Discrete snore events; gaps outside [[minInterSnoreGap], [maxInterSnoreGap]]
///   reset the idle candidate chain.
/// - Open after [episodeOpenSnoreCount] consecutive events with valid gaps;
///   start backdated to the first of those events.
/// - Close after [episodeCloseSilence] with no new snore event (from event end).
/// - Save if event count ≥ open count; optional [minEpisodeDuration] floor.
/// - Trim trailing close-silence from the saved WAV.
class RecordingStateMachine {
  final RecordingStorageService _storageService;
  final int episodeOpenSnoreCount;
  final Duration episodeOpenWindow;
  final Duration episodeCloseSilence;
  final Duration minEpisodeDuration;
  final Duration minInterSnoreGap;
  final Duration maxInterSnoreGap;
  final Duration snoreBurstEndSilence;
  final bool requireMinSnoreEventsToSave;
  /// When true, open/extend gaps use previous event end → next event start.
  final bool measureGapsFromEventEnd;
  final String Function(int index, DateTime startTimestamp)? fileNameBuilder;
  final void Function(SnoreRecordingInfo info)? onRecordingSaved;
  final void Function(Duration duration)? onEpisodeDiscarded;
  final DateTime Function() _clock;

  RecordingState _state = RecordingState.idle;
  WavWriter? _wavWriter;
  File? _currentRecordingFile;
  DateTime? _episodeStartTime;
  DateTime? _lastActivityTime;
  /// End/offset of the last discrete snore event (close timer anchor).
  DateTime? _lastSnoreEventEndTime;
  int _recordingIndex = 0;
  final List<int> _audioBuffer = [];

  /// Discrete snore events in the candidate chain / episode.
  final ListQueue<_SnoreEventMark> _snoreEvents = ListQueue<_SnoreEventMark>();
  final List<int> _interSnoreGapsMs = [];
  int _episodeSnoreEventCount = 0;

  bool _inSnoreBurst = false;
  DateTime? _burstQuietSince;

  /// Rolling PCM for seeding WAV when an episode opens.
  final ListQueue<_PcmChunk> _rollingPcm = ListQueue<_PcmChunk>();

  /// Quiet audio held during pendingClose; flushed on resume, dropped on finalize.
  final List<int> _pendingClosePcm = [];

  /// Creates a recording state machine with client episode defaults.
  RecordingStateMachine({
    this.episodeOpenSnoreCount = 3,
    this.episodeOpenWindow = const Duration(seconds: 22),
    this.episodeCloseSilence = const Duration(seconds: 11),
    this.minEpisodeDuration = Duration.zero,
    this.minInterSnoreGap = const Duration(seconds: 2),
    this.maxInterSnoreGap = const Duration(seconds: 11),
    this.snoreBurstEndSilence = const Duration(seconds: 2),
    this.requireMinSnoreEventsToSave = true,
    this.measureGapsFromEventEnd = true,
    this.fileNameBuilder,
    this.onRecordingSaved,
    this.onEpisodeDiscarded,
    RecordingStorageService? storageService,
    DateTime Function()? clock,
  })  : _storageService = storageService ?? RecordingStorageService(),
        _clock = clock ?? DateTime.now;

  /// Processes a detection result and updates episode state.
  ///
  /// [audioSamples] are raw PCM Int16 samples from the shared mic stream
  /// for this ~1s window.
  Future<void> processDetectionResult(
    DetectionResult result,
    List<int> audioSamples, {
    DateTime? now,
  }) async {
    final timestamp = now ?? _clock();
    final isSnoring = result.isSnoring;

    _appendRollingPcm(timestamp, audioSamples);
    final discreteSnore = _updateDiscreteSnore(isSnoring, timestamp);

    switch (_state) {
      case RecordingState.idle:
        if (discreteSnore) {
          _registerSnoreEvent(timestamp, forEpisode: false);
          if (_shouldOpenEpisode(timestamp)) {
            await _openEpisode(timestamp);
          }
        }
        break;

      case RecordingState.recording:
        _audioBuffer.addAll(audioSamples);
        if (_audioBuffer.length >= AudioProcessor.targetSampleRate) {
          await _writeAudioBuffer();
        }

        if (discreteSnore) {
          _registerSnoreEvent(timestamp, forEpisode: true);
          _lastActivityTime = timestamp;
        } else if (isSnoring) {
          _lastActivityTime = timestamp;
        } else {
          _state = RecordingState.pendingClose;
          _pendingClosePcm
            ..clear()
            ..addAll(audioSamples);
          _audioBuffer.clear();
        }
        break;

      case RecordingState.pendingClose:
        if (isSnoring || discreteSnore) {
          // Merge: flush quiet gap into file and continue episode.
          if (_pendingClosePcm.isNotEmpty) {
            _audioBuffer.addAll(_pendingClosePcm);
            _pendingClosePcm.clear();
            await _writeAudioBuffer();
          }
          _state = RecordingState.recording;
          _audioBuffer.addAll(audioSamples);
          if (_audioBuffer.length >= AudioProcessor.targetSampleRate) {
            await _writeAudioBuffer();
          }
          if (discreteSnore) {
            _registerSnoreEvent(timestamp, forEpisode: true);
          }
          _lastActivityTime = timestamp;
        } else {
          _pendingClosePcm.addAll(audioSamples);
        }
        break;
    }

    await _maybeCloseForSilence(timestamp);
  }

  /// Close when [episodeCloseSilence] has passed since last snore event end
  /// and we are not currently in a snore burst / snoring frame.
  Future<void> _maybeCloseForSilence(DateTime timestamp) async {
    if (_state != RecordingState.recording &&
        _state != RecordingState.pendingClose) {
      return;
    }
    if (_inSnoreBurst) return;
    final eventEnd = _lastSnoreEventEndTime;
    if (eventEnd == null) return;
    if (timestamp.difference(eventEnd) >= episodeCloseSilence) {
      await _finalizeEpisode(timestamp);
    }
  }

  bool _updateDiscreteSnore(bool isSnoring, DateTime now) {
    if (isSnoring) {
      _burstQuietSince = null;
      if (!_inSnoreBurst) {
        _inSnoreBurst = true;
        return true;
      }
      return false;
    }

    // Non-snore frame
    if (_inSnoreBurst) {
      _burstQuietSince ??= now;
      if (now.difference(_burstQuietSince!) >= snoreBurstEndSilence) {
        _inSnoreBurst = false;
        // Event end/offset = when the burst is considered finished.
        _lastSnoreEventEndTime = now;
        if (_snoreEvents.isNotEmpty) {
          _snoreEvents.last.end = now;
        }
        _burstQuietSince = null;
      }
    }
    return false;
  }

  Duration _gapToPrevious(_SnoreEventMark previous, DateTime nextStart) {
    if (measureGapsFromEventEnd) {
      return nextStart.difference(previous.end);
    }
    return nextStart.difference(previous.start);
  }

  void _registerSnoreEvent(DateTime timestamp, {required bool forEpisode}) {
    if (_snoreEvents.isNotEmpty) {
      final gap = _gapToPrevious(_snoreEvents.last, timestamp);

      // Too close → ignore (same snore / fragment).
      if (gap < minInterSnoreGap) {
        return;
      }

      // Idle candidate: gap too large → start a fresh candidate chain.
      if (!forEpisode &&
          _state == RecordingState.idle &&
          gap > maxInterSnoreGap) {
        _snoreEvents.clear();
      } else if (forEpisode || _state != RecordingState.idle) {
        _interSnoreGapsMs.add(gap.inMilliseconds);
      }
    }

    _snoreEvents.addLast(_SnoreEventMark(timestamp));
    // Event end initially at start; updated when burst ends.
    _lastSnoreEventEndTime = timestamp;
    _pruneSnoreEvents(timestamp);

    if (forEpisode || _state == RecordingState.recording) {
      _episodeSnoreEventCount++;
    }
  }

  void _pruneSnoreEvents(DateTime now) {
    while (_snoreEvents.isNotEmpty &&
        now.difference(_snoreEvents.first.start) > episodeOpenWindow) {
      _snoreEvents.removeFirst();
    }
  }

  bool _shouldOpenEpisode([DateTime? now]) {
    _pruneSnoreEvents(now ?? _clock());
    if (_snoreEvents.length < episodeOpenSnoreCount) {
      return false;
    }

    final recent = _snoreEvents.toList().sublist(
          _snoreEvents.length - episodeOpenSnoreCount,
        );

    for (var i = 1; i < recent.length; i++) {
      final gap = _gapToPrevious(recent[i - 1], recent[i].start);
      if (gap < minInterSnoreGap || gap > maxInterSnoreGap) {
        return false;
      }
    }
    return true;
  }

  void _appendRollingPcm(DateTime timestamp, List<int> samples) {
    _rollingPcm.addLast(_PcmChunk(timestamp, List<int>.from(samples)));
    final cutoff = timestamp.subtract(episodeOpenWindow);
    while (_rollingPcm.isNotEmpty &&
        _rollingPcm.first.timestamp.isBefore(cutoff)) {
      _rollingPcm.removeFirst();
    }
  }

  Future<void> _openEpisode(DateTime openTime) async {
    final recent = _snoreEvents.toList().sublist(
          _snoreEvents.length - episodeOpenSnoreCount,
        );
    final seedFrom = recent.first.start;

    _episodeStartTime = seedFrom;
    _lastActivityTime = openTime;
    _lastSnoreEventEndTime = recent.last.end;
    _episodeSnoreEventCount = episodeOpenSnoreCount;
    _interSnoreGapsMs.clear();
    for (var i = 1; i < recent.length; i++) {
      _interSnoreGapsMs
          .add(_gapToPrevious(recent[i - 1], recent[i].start).inMilliseconds);
    }

    _recordingIndex++;
    final filePath = await _storageService.createRecordingFilePath(
      index: _recordingIndex,
      timestamp: seedFrom,
      fileNameBuilder: fileNameBuilder,
    );

    _currentRecordingFile = File(filePath);
    _wavWriter = WavWriter(
      file: _currentRecordingFile!,
      sampleRate: AudioProcessor.targetSampleRate,
      numChannels: 1,
      bitsPerSample: 16,
    );
    await _wavWriter!.open();
    _audioBuffer.clear();

    for (final chunk in _rollingPcm) {
      if (!chunk.timestamp.isBefore(seedFrom)) {
        _audioBuffer.addAll(chunk.samples);
      }
    }
    if (_audioBuffer.isNotEmpty) {
      await _writeAudioBuffer();
    }

    _state = RecordingState.recording;
    _pendingClosePcm.clear();
  }

  Future<void> _finalizeEpisode(DateTime closeTime) async {
    if (_wavWriter == null ||
        _currentRecordingFile == null ||
        _episodeStartTime == null) {
      _resetToIdle();
      return;
    }

    _pendingClosePcm.clear();
    if (_audioBuffer.isNotEmpty) {
      await _writeAudioBuffer();
    }

    await _wavWriter!.close();

    final activityEnd = _lastActivityTime ?? _episodeStartTime!;
    final keptDuration = activityEnd.difference(_episodeStartTime!);

    final file = _currentRecordingFile!;
    final path = file.absolute.path;

    final tooFewEvents = requireMinSnoreEventsToSave &&
        _episodeSnoreEventCount < episodeOpenSnoreCount;
    final tooShort = minEpisodeDuration > Duration.zero &&
        keptDuration < minEpisodeDuration;

    if (tooFewEvents || tooShort) {
      if (await file.exists()) {
        await file.delete();
      }
      onEpisodeDiscarded?.call(keptDuration);
      _resetToIdle();
      return;
    }

    final info = SnoreRecordingInfo(
      filePath: path,
      startTimestamp: _episodeStartTime!,
      duration: keptDuration,
      snoreEventCount: _episodeSnoreEventCount,
      interSnoreGapsMs: List<int>.from(_interSnoreGapsMs),
    );

    await _storageService.saveRecordingMetadata(info);
    onRecordingSaved?.call(info);
    _resetToIdle();
  }

  Future<void> _writeAudioBuffer() async {
    if (_wavWriter == null || _audioBuffer.isEmpty) {
      return;
    }

    final samples = _audioBuffer.map((sample) {
      return sample.clamp(-32768, 32767);
    }).toList();

    await _wavWriter!.writeSamples(samples);
    _audioBuffer.clear();
  }

  void _resetToIdle() {
    _state = RecordingState.idle;
    _wavWriter = null;
    _currentRecordingFile = null;
    _episodeStartTime = null;
    _lastActivityTime = null;
    _lastSnoreEventEndTime = null;
    _audioBuffer.clear();
    _pendingClosePcm.clear();
    _interSnoreGapsMs.clear();
    _episodeSnoreEventCount = 0;
    final now = _clock();
    _pruneSnoreEvents(now);
  }

  /// Finalizes any active episode (save or discard) without clearing candidates.
  Future<void> finalizeActiveEpisode() async {
    if (_state == RecordingState.recording ||
        _state == RecordingState.pendingClose) {
      await _finalizeEpisode(_clock());
    }
  }

  /// Stops any active recording and resets state.
  Future<void> stop() async {
    if (_state == RecordingState.recording ||
        _state == RecordingState.pendingClose) {
      await _finalizeEpisode(_clock());
    }

    _state = RecordingState.idle;
    _wavWriter = null;
    _currentRecordingFile = null;
    _episodeStartTime = null;
    _lastActivityTime = null;
    _lastSnoreEventEndTime = null;
    _audioBuffer.clear();
    _pendingClosePcm.clear();
    _snoreEvents.clear();
    _interSnoreGapsMs.clear();
    _episodeSnoreEventCount = 0;
    _rollingPcm.clear();
    _inSnoreBurst = false;
    _burstQuietSince = null;
  }

  /// Gets the current state.
  RecordingState get state => _state;

  /// Whether a recording is currently active (including pending close).
  bool get isRecording =>
      _state == RecordingState.recording ||
      _state == RecordingState.pendingClose;
}

import 'dart:async';
import 'dart:io';
import '../models/detection_result.dart';
import '../models/snore_recording_info.dart';
import '../utils/wav_writer.dart';
import '../utils/audio_processor.dart';
import 'recording_storage_service.dart';

/// Recording states for the state machine
enum RecordingState {
  idle,
  pendingStart,
  recording,
  pendingStop,
}

/// State machine for managing recording lifecycle during live detection.
///
/// **CRITICAL: No Microphone Access**
/// This class does NOT open a microphone. It receives raw PCM audio samples
/// from the SHARED microphone stream that is also used for snore detection.
/// The microphone is opened ONCE by [AudioRecorderService] and the same audio
/// frames are delivered to both detection and this recording state machine.
///
/// Handles the logic for starting/stopping recordings based on detection
/// results with configurable start and stop delays.
class RecordingStateMachine {

  final RecordingStorageService _storageService = RecordingStorageService();
  final Duration recordingStartDelay;
  final Duration recordingStopDelay;
  final String Function(int index, DateTime startTimestamp)? fileNameBuilder;
  final void Function(SnoreRecordingInfo info)? onRecordingSaved;

  RecordingState _state = RecordingState.idle;
  DateTime? _pendingStartTime;
  DateTime? _pendingStopTime;
  WavWriter? _wavWriter;
  File? _currentRecordingFile;
  DateTime? _recordingStartTime;
  int _recordingIndex = 0;
  final List<int> _audioBuffer = [];

  /// Creates a recording state machine.
  RecordingStateMachine({
    required this.recordingStartDelay,
    required this.recordingStopDelay,
    this.fileNameBuilder,
    this.onRecordingSaved,
  });

  /// Processes a detection result and updates state accordingly.
  ///
  /// **SINGLE MICROPHONE STREAM**: The [audioSamples] parameter contains raw PCM
  /// samples from the SHARED microphone stream (same source as snore detection).
  /// This method does NOT open a separate microphone - it only writes the
  /// received samples to a WAV file when in the recording state.
  ///
  /// This should be called for each detection result from live detection.
  /// The state machine will automatically start/stop recordings based on
  /// the detection results and configured delays.
  Future<void> processDetectionResult(
    DetectionResult result,
    List<int> audioSamples, // Raw PCM from shared mic stream
  ) async {
    final now = DateTime.now();
    final isSnoring = result.isSnoring;

    switch (_state) {
      case RecordingState.idle:
        if (isSnoring) {
          // Transition to pendingStart
          _state = RecordingState.pendingStart;
          _pendingStartTime = now;
        }
        break;

      case RecordingState.pendingStart:
        if (isSnoring) {
          // Check if start delay has elapsed
          final elapsed = now.difference(_pendingStartTime!);
          if (elapsed >= recordingStartDelay) {
            // Start recording
            await _startRecording(now);
          }
        } else {
          // Snoring stopped before delay elapsed - cancel
          _state = RecordingState.idle;
          _pendingStartTime = null;
        }
        break;

      case RecordingState.recording:
        // Write audio samples to file
        _audioBuffer.addAll(audioSamples);

        if (isSnoring) {
          // Continue recording
          // Flush buffer periodically (every ~1 second worth of samples)
          if (_audioBuffer.length >= AudioProcessor.targetSampleRate) {
            await _writeAudioBuffer();
          }
        } else {
          // Transition to pendingStop
          _state = RecordingState.pendingStop;
          _pendingStopTime = now;
        }
        break;

      case RecordingState.pendingStop:
        if (isSnoring) {
          // Snoring resumed - go back to recording
          _state = RecordingState.recording;
          _pendingStopTime = null;
        } else {
          // Check if stop delay has elapsed
          final elapsed = now.difference(_pendingStopTime!);
          if (elapsed >= recordingStopDelay) {
            // Stop recording
            await _stopRecording(now);
          }
        }
        break;
    }
  }

  /// Starts a new recording.
  Future<void> _startRecording(DateTime startTime) async {
    try {
      _recordingIndex++;
      _recordingStartTime = startTime;

      // Create file path
      final filePath = await _storageService.createRecordingFilePath(
        index: _recordingIndex,
        timestamp: startTime,
        fileNameBuilder: fileNameBuilder,
      );

      _currentRecordingFile = File(filePath);

      // Create WAV writer
      _wavWriter = WavWriter(
        file: _currentRecordingFile!,
        sampleRate: AudioProcessor.targetSampleRate,
        numChannels: 1,
        bitsPerSample: 16,
      );

      await _wavWriter!.open();
      _audioBuffer.clear();

      _state = RecordingState.recording;
    } catch (e) {
      // Error starting recording - reset state
      _state = RecordingState.idle;
      _pendingStartTime = null;
      _wavWriter = null;
      _currentRecordingFile = null;
      rethrow;
    }
  }

  /// Stops the current recording and saves metadata.
  Future<void> _stopRecording(DateTime stopTime) async {
    if (_wavWriter == null || _currentRecordingFile == null) {
      _state = RecordingState.idle;
      return;
    }

    try {
      // Write any remaining audio buffer
      if (_audioBuffer.isNotEmpty) {
        await _writeAudioBuffer();
      }

      // Close WAV file
      await _wavWriter!.close();

      // Calculate duration
      final duration = stopTime.difference(_recordingStartTime!);

      // Create recording info
      final recordingInfo = SnoreRecordingInfo(
        filePath: _currentRecordingFile!.absolute.path,
        startTimestamp: _recordingStartTime!,
        duration: duration,
      );

      // Save metadata
      await _storageService.saveRecordingMetadata(recordingInfo);

      // Call callback
      onRecordingSaved?.call(recordingInfo);

      // Reset state
      _state = RecordingState.idle;
      _wavWriter = null;
      _currentRecordingFile = null;
      _recordingStartTime = null;
      _audioBuffer.clear();
    } catch (e) {
      // Error stopping recording - try to clean up
      _state = RecordingState.idle;
      _wavWriter = null;
      _currentRecordingFile = null;
      _recordingStartTime = null;
      _audioBuffer.clear();
      rethrow;
    }
  }

  /// Writes buffered audio samples to file.
  Future<void> _writeAudioBuffer() async {
    if (_wavWriter == null || _audioBuffer.isEmpty) {
      return;
    }

    // Write samples (convert to Int16 range)
    final samples = _audioBuffer.map((sample) {
      // Clamp to Int16 range
      return sample.clamp(-32768, 32767);
    }).toList();

    await _wavWriter!.writeSamples(samples);
    _audioBuffer.clear();
  }

  /// Stops any active recording and resets state.
  ///
  /// This should be called when live detection stops to ensure
  /// any active recording is properly finalized.
  Future<void> stop() async {
    if (_state == RecordingState.recording || _state == RecordingState.pendingStop) {
      // Finalize current recording
      await _stopRecording(DateTime.now());
    }

    _state = RecordingState.idle;
    _pendingStartTime = null;
    _pendingStopTime = null;
    _wavWriter = null;
    _currentRecordingFile = null;
    _recordingStartTime = null;
    _audioBuffer.clear();
  }

  /// Gets the current state.
  RecordingState get state => _state;

  /// Whether a recording is currently active.
  bool get isRecording => _state == RecordingState.recording;
}


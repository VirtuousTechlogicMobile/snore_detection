import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/audio_processor.dart';

/// Service for recording and processing live audio.
///
/// **CRITICAL: Single Microphone Architecture**
/// This service maintains EXACTLY ONE microphone input stream that is shared
/// between snore detection and audio recording. Both detection and recording
/// receive PCM frames from the same underlying audio stream.
///
/// - The microphone is opened ONCE when [startRecording] is called.
/// - The same PCM frames are delivered to both:
///   - Detection callback (normalized doubles)
///   - Recording callback (raw Int16 samples)
/// - The microphone is closed ONCE when [stopRecording] is called.
/// - No separate recorder instances are created for recording.
class AudioRecorderService {
  /// Single AudioRecorder instance - the ONLY microphone input.
  /// This is shared between detection and recording.
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _audioStreamSubscription;
  bool _isRecording = false;

  final List<int> _audioBuffer = [];
  static const int _bufferSizeSeconds = 1;
  static const int _bufferSizeSamples =
      AudioProcessor.targetSampleRate * _bufferSizeSeconds;

  /// Check and request microphone permission
  Future<bool> requestPermission() async {
    // First check if permission is already granted
    final status = await Permission.microphone.status;
    if (status.isGranted) {
      return true;
    }

    // Request permission
    final newStatus = await Permission.microphone.request();
    return newStatus.isGranted;
  }

  /// Start recording with a callback for each audio window.
  ///
  /// **SINGLE MICROPHONE**: Opens the microphone ONCE and shares the same
  /// audio stream for both detection and recording.
  ///
  /// [onAudioWindow] receives normalized audio samples (doubles in range -1.0 to 1.0)
  /// for snore detection.
  /// [onRawAudioWindow] optionally receives raw Int16 PCM samples for recording.
  /// Both callbacks receive data from the SAME underlying microphone stream.
  ///
  /// Throws [StateError] if called when already recording (prevents duplicate mic opens).
  Future<void> startRecording({
    required Function(List<double> audioWindow) onAudioWindow,
    Function(List<int> rawSamples)? onRawAudioWindow,
    bool verboseDebug = false,
  }) async {
    // GUARD: Prevent duplicate microphone opens
    if (_isRecording) {
      if (verboseDebug) {
        print('⚠️ [AUDIO] startRecording() called but already recording. Ignoring duplicate call.');
      }
      throw StateError(
          'Microphone already in use. Call stopRecording() before starting again.');
    }

    if (verboseDebug) {
      print('🎤 [AUDIO] Opening microphone (SINGLE INSTANCE - shared for detection + recording)...');
    }

    // Check permission using record package's hasPermission
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      throw Exception('Microphone permission not granted');
    }

    // Clear buffer
    _audioBuffer.clear();

    // Configure recording
    const config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: AudioProcessor.targetSampleRate,
      numChannels: 1, // Mono
      bitRate: 128000,
    );

    // CRITICAL: Open microphone ONCE via startStream()
    // This is the ONLY place where the microphone is opened.
    // The same stream will feed both detection and recording.
    final stream = await _recorder.startStream(config);

    if (verboseDebug) {
      print('✅ [AUDIO] Microphone opened successfully. Stream active.');
      print('📡 [AUDIO] Audio frames will be dispatched to:');
      print('   - Detection callback (normalized doubles)');
      if (onRawAudioWindow != null) {
        print('   - Recording callback (raw Int16 PCM)');
      } else {
        print('   - Recording callback: NOT ACTIVE');
      }
    }

    _isRecording = true;

    // Process audio stream - frames from the SINGLE mic are delivered here
    _audioStreamSubscription = stream.listen((audioData) {
      _processAudioChunk(audioData, onAudioWindow, onRawAudioWindow, verboseDebug);
    });
  }

  /// Process incoming audio chunks from the shared microphone stream.
  ///
  /// This method receives raw audio bytes from the SINGLE microphone stream
  /// and dispatches them to both:
  /// 1. Detection callback (normalized doubles)
  /// 2. Recording callback (raw Int16 PCM) - if provided
  ///
  /// Both callbacks receive data from the SAME source - no duplicate mic access.
  void _processAudioChunk(
    Uint8List audioData,
    Function(List<double> audioWindow) onAudioWindow,
    Function(List<int> rawSamples)? onRawAudioWindow,
    bool verboseDebug,
  ) {
    // Convert bytes to Int16 PCM samples from the shared mic stream
    final samples = AudioProcessor.bytesToInt16(audioData);

    // Add to buffer
    _audioBuffer.addAll(samples);

    if (verboseDebug) {
      print(
          '🎤 [AUDIO] Buffer: ${_audioBuffer.length}/$_bufferSizeSamples samples (from shared mic stream)');
    }

    // Process complete windows
    while (_audioBuffer.length >= _bufferSizeSamples) {
      if (verboseDebug) {
        print('✅ [AUDIO] Processing 1-second window from shared mic stream...');
      }

      // Extract window from shared buffer
      final windowSamples = _audioBuffer.sublist(0, _bufferSizeSamples);
      _audioBuffer.removeRange(0, _bufferSizeSamples);

      // Convert to normalized doubles for detection
      final audioWindow = AudioProcessor.int16ToDouble(windowSamples);

      // DISPATCH TO DETECTION: Same PCM frames, normalized
      onAudioWindow(audioWindow);

      // DISPATCH TO RECORDING: Same PCM frames, raw Int16
      // This is the SAME audio data - no separate mic access
      if (onRawAudioWindow != null) {
        if (verboseDebug) {
          print('📝 [AUDIO] Dispatching raw samples to recording (same mic stream)');
        }
        onRawAudioWindow(windowSamples);
      }
    }
  }

  /// Stop recording and close the microphone.
  ///
  /// **SINGLE CLOSE**: This is the ONLY place where the microphone is closed.
  /// Both detection and recording stop when this is called.
  Future<void> stopRecording({bool verboseDebug = false}) async {
    if (!_isRecording) {
      if (verboseDebug) {
        print('⚠️ [AUDIO] stopRecording() called but not recording. Ignoring.');
      }
      return;
    }

    if (verboseDebug) {
      print('🛑 [AUDIO] Closing microphone (SINGLE INSTANCE - stops both detection + recording)...');
    }

    await _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;

    // CRITICAL: Close microphone ONCE
    // This closes the shared mic that was used for both detection and recording.
    await _recorder.stop();

    if (verboseDebug) {
      print('✅ [AUDIO] Microphone closed successfully.');
    }

    _isRecording = false;
    _audioBuffer.clear();
  }

  /// Check if currently recording
  bool get isRecording => _isRecording;

  /// Dispose resources
  void dispose() {
    stopRecording();
    _recorder.dispose();
  }
}

import 'dart:async';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'services/tflite_service.dart';
import 'services/audio_recorder_service.dart';
import 'services/recording_state_machine.dart';
import 'services/recording_storage_service.dart';
import 'utils/audio_processor.dart';
import 'models/detection_result.dart';
import 'models/snore_recording_info.dart';
import 'exceptions/snore_storage_permission_exception.dart';

/// Main API for snore detection using TensorFlow Lite.
///
/// Provides both live audio detection from the microphone and file-based
/// detection for analyzing pre-recorded audio. The detector uses a quantized
/// TensorFlow Lite model trained on snoring and noise samples.
///
/// ## Usage
///
/// Always call [initialize] before using any other methods:
///
/// ```dart
/// final detector = SnoreDetector();
/// await detector.initialize();
/// ```
///
/// ### Live Detection
///
/// Start real-time detection from the device microphone:
///
/// ```dart
/// await detector.startLiveDetection(
///   confidenceThreshold: 0.7,
///   onResult: (result) {
///     if (result.isSnoring) {
///       print('Snoring detected! Confidence: ${result.confidence}');
///     }
///   },
///   onError: (error) {
///     print('Detection error: $error');
///   },
/// );
///
/// // Stop when done
/// await detector.stopLiveDetection();
/// ```
///
/// ### File Detection
///
/// Analyze a pre-recorded audio file:
///
/// ```dart
/// final results = await detector.detectFromFile('/path/to/audio.wav');
/// for (final result in results) {
///   print('${result.timestamp}: ${result.isSnoring}');
/// }
/// ```
///
/// ### Cleanup
///
/// Always dispose the detector when done:
///
/// ```dart
/// detector.dispose();
/// ```
class SnoreDetector {
  final TFLiteService _tfliteService = TFLiteService();
  final AudioRecorderService _recorderService = AudioRecorderService();
  final RecordingStorageService _storageService = RecordingStorageService();

  bool _isInitialized = false;
  StreamController<DetectionResult>? _liveDetectionController;
  double _currentThreshold = 0.5;
  RecordingStateMachine? _recordingStateMachine;

  /// Sets a custom recordings directory path.
  ///
  /// If provided, all recordings will be saved to this directory instead of
  /// the default app documents directory.
  ///
  /// **Parameters:**
  /// - [directoryPath]: Absolute path to the directory where recordings should be saved.
  ///   If `null`, the default directory will be used.
  ///
  /// **Example:**
  /// ```dart
  /// detector.setRecordingsDirectory('/path/to/custom/recordings');
  /// ```
  void setRecordingsDirectory(String? directoryPath) {
    _storageService.setCustomRecordingsDirectory(directoryPath);
  }

  /// Initializes the detector by loading the TensorFlow Lite model.
  ///
  /// This must be called before using any other methods. It loads the
  /// quantized TFLite model from the package assets into memory.
  ///
  /// Throws an [Exception] if the model fails to load.
  ///
  /// Example:
  /// ```dart
  /// final detector = SnoreDetector();
  /// try {
  ///   await detector.initialize();
  ///   print('Detector ready!');
  /// } catch (e) {
  ///   print('Initialization failed: $e');
  /// }
  /// ```
  Future<void> initialize() async {
    if (_isInitialized) {
      return;
    }

    try {
      await _tfliteService.initialize();
      _isInitialized = true;
    } catch (e) {
      throw Exception('Failed to initialize SnoreDetector: $e');
    }
  }

  /// Requests microphone permission from the user.
  ///
  /// This should be called before starting live detection to ensure the app
  /// has the necessary permissions. On Android 6.0+ and iOS, this will show
  /// the system permission dialog if permission hasn't been granted yet.
  ///
  /// Returns `true` if permission is granted, `false` otherwise.
  ///
  /// Example:
  /// ```dart
  /// final hasPermission = await detector.requestMicrophonePermission();
  /// if (hasPermission) {
  ///   await detector.startLiveDetection(...);
  /// } else {
  ///   print('Microphone permission denied');
  /// }
  /// ```
  Future<bool> requestMicrophonePermission() async {
    return await _recorderService.requestPermission();
  }

  /// Requests storage permission from the user.
  ///
  /// This is required when [enableRecording] is `true` in [startLiveDetection].
  /// On Android, this requests storage permissions needed to save audio files.
  /// On iOS, storing in app documents typically doesn't require explicit permission.
  ///
  /// Returns `true` if permission is granted, `false` otherwise.
  ///
  /// Example:
  /// ```dart
  /// final hasStoragePermission = await detector.requestStoragePermission();
  /// if (hasStoragePermission) {
  ///   await detector.startLiveDetection(enableRecording: true, ...);
  /// }
  /// ```
  Future<bool> requestStoragePermission() async {
    if (Platform.isAndroid) {
      // On Android 13+ (API 33+), scoped storage is used
      // For app documents directory (getApplicationDocumentsDirectory),
      // we don't need storage permission - it's always accessible
      // We only need to verify we can create the directory
      try {
        // Test if we can access the documents directory
        final appDir = await getApplicationDocumentsDirectory();
        final testDir = Directory('${appDir.path}/snore_recordings');
        if (!await testDir.exists()) {
          await testDir.create(recursive: true);
        }
        // If we can create the directory, we have access
        return true;
      } catch (e) {
        // If we can't access documents directory, try requesting storage permission
        // This is mainly for older Android versions or edge cases
        try {
          final status = await Permission.storage.status;
          if (status.isGranted) {
            return true;
          }
          final newStatus = await Permission.storage.request();
          return newStatus.isGranted;
        } catch (e2) {
          // If permission request fails, still return true for app documents
          // as it should work without explicit permission
          print('Warning: Storage permission check failed, but app documents should work: $e2');
          return true;
        }
      }
    } else if (Platform.isIOS) {
      // iOS doesn't require explicit permission for app documents
      return true;
    } else {
      // Other platforms
      return true;
    }
  }

  /// Ensures storage permission is granted, throwing an exception if not.
  ///
  /// This should be called internally before creating any recording files.
  /// Throws [SnoreStoragePermissionException] if permission is not granted.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   await detector.ensureStoragePermissionOrThrow();
  ///   // Safe to create files
  /// } on SnoreStoragePermissionException catch (e) {
  ///   print('Storage permission required: $e');
  /// }
  /// ```
  Future<void> ensureStoragePermissionOrThrow() async {
    final hasPermission = await requestStoragePermission();
    if (!hasPermission) {
      throw SnoreStoragePermissionException(
        'Storage permission is required to save snore recordings.',
      );
    }
  }

  /// Starts live audio detection from the device microphone.
  ///
  /// Records audio in 1-second windows and analyzes each window for snoring.
  /// Results are delivered through both the returned stream and optional callbacks.
  ///
  /// **Parameters:**
  /// - [onResult]: Called for each detection result (once per second)
  /// - [onError]: Called if an error occurs during recording or inference
  /// - [confidenceThreshold]: Minimum confidence (0.0-1.0) required to classify as snoring. Default: 0.5
  /// - [verboseDebug]: Enable verbose console logging for debugging. Default: false
  /// - [enableRecording]: If `true`, automatically records snore episodes. Default: false
  /// - [episodeOpenSnoreCount]: Discrete snores required to open. Default: 3
  /// - [episodeOpenWindow]: Candidate window. Default: 22s ((count-1)*11s)
  /// - [episodeCloseSilence]: Quiet since last snore event end before close. Default: 11s
  /// - [minEpisodeDuration]: Optional duration floor (zero = off). Default: 0
  /// - [minInterSnoreGap] / [maxInterSnoreGap]: Event spacing gate. Default: 2s–11s
  /// - [snoreBurstEndSilence]: Quiet needed to end one discrete snore burst. Default: 2s
  /// - [requireMinSnoreEventsToSave]: Discard if event count < open count. Default: true
  /// - [fileNameBuilder]: Optional callback to generate custom filenames. If null, uses default format.
  /// - [onRecordingSaved]: Invoked when a kept episode is saved.
  /// - [onEpisodeDiscarded]: Invoked when an episode is discarded.
  ///
  /// **Returns:** A [Stream] of [DetectionResult]s that emits once per second
  ///
  /// **Throws:**
  /// - [StateError] if detection is already running
  /// - [Exception] if microphone permission is denied or recording fails
  /// - [SnoreStoragePermissionException] if `enableRecording` is `true` but storage permission is denied
  ///
  /// **Platform Requirements:**
  /// - iOS: Add `NSMicrophoneUsageDescription` to Info.plist
  /// - Android: Add `RECORD_AUDIO` permission to AndroidManifest.xml
  ///
  /// **Recording Behavior (episode heuristic):**
  /// - Opens after 3 consecutive discrete snores with gaps 2–11s.
  /// - Closes after 11s with no new snore event (from event end).
  /// - Saves if ≥3 snore events; no 60s duration floor by default.
  ///
  /// Example:
  /// ```dart
  /// await detector.startLiveDetection(
  ///   confidenceThreshold: 0.7,
  ///   onResult: (result) {
  ///     print('Snoring: ${result.isSnoring}');
  ///   },
  ///   enableRecording: true,
  ///   onRecordingSaved: (info) {
  ///     print('Saved episode: ${info.filePath}, ${info.duration.inSeconds}s');
  ///   },
  /// );
  /// ```
  Future<Stream<DetectionResult>> startLiveDetection({
    Function(DetectionResult result)? onResult,
    Function(dynamic error)? onError,
    double confidenceThreshold = 0.5,
    bool verboseDebug = false,
    bool enableRecording = false,
    int episodeOpenSnoreCount = 3,
    Duration? episodeOpenWindow,
    Duration episodeCloseSilence = const Duration(seconds: 11),
    Duration minEpisodeDuration = Duration.zero,
    Duration minInterSnoreGap = const Duration(seconds: 2),
    Duration maxInterSnoreGap = const Duration(seconds: 11),
    Duration snoreBurstEndSilence = const Duration(seconds: 2),
    bool requireMinSnoreEventsToSave = true,
    bool measureGapsFromEventEnd = true,
    String Function(int index, DateTime startTimestamp)? fileNameBuilder,
    void Function(SnoreRecordingInfo info)? onRecordingSaved,
    void Function(Duration duration)? onEpisodeDiscarded,
  }) async {
    _ensureInitialized();

    if (_liveDetectionController != null) {
      throw StateError(
          'Live detection already running. Call stopLiveDetection() first.');
    }

    // If recording is enabled, ensure storage permission
    if (enableRecording) {
      await ensureStoragePermissionOrThrow();
    }

    _liveDetectionController = StreamController<DetectionResult>.broadcast();

    _currentThreshold = confidenceThreshold;

    final resolvedOpenWindow = episodeOpenWindow ??
        Duration(
          milliseconds:
              (episodeOpenSnoreCount - 1) * maxInterSnoreGap.inMilliseconds,
        );

    // Initialize recording state machine if recording is enabled
    if (enableRecording) {
      _recordingStateMachine = RecordingStateMachine(
        episodeOpenSnoreCount: episodeOpenSnoreCount,
        episodeOpenWindow: resolvedOpenWindow,
        episodeCloseSilence: episodeCloseSilence,
        minEpisodeDuration: minEpisodeDuration,
        minInterSnoreGap: minInterSnoreGap,
        maxInterSnoreGap: maxInterSnoreGap,
        snoreBurstEndSilence: snoreBurstEndSilence,
        requireMinSnoreEventsToSave: requireMinSnoreEventsToSave,
        measureGapsFromEventEnd: measureGapsFromEventEnd,
        fileNameBuilder: fileNameBuilder,
        onRecordingSaved: onRecordingSaved,
        onEpisodeDiscarded: onEpisodeDiscarded,
        storageService: _storageService,
      );
    }

    // CRITICAL: Single Microphone Architecture
    // The microphone is opened ONCE here via _recorderService.startRecording().
    // The same audio stream feeds both:
    // 1. Snore detection (via onAudioWindow callback)
    // 2. Audio recording (via onRawAudioWindow callback)
    // No separate microphone or recorder instance is created for recording.
    if (verboseDebug) {
      print('🎯 [DETECTOR] Starting live detection with SINGLE microphone...');
      if (enableRecording) {
        print('   - Recording: ENABLED (will share same mic stream)');
      } else {
        print('   - Recording: DISABLED');
      }
    }

    try {
      // CRITICAL: Single Microphone Stream Architecture
      // Both onAudioWindow and onRawAudioWindow receive data from the SAME microphone stream.
      // When recording is enabled, we process detection in onRawAudioWindow to ensure
      // perfect synchronization between detection results and raw PCM samples for recording.
      // This avoids processing the same audio twice.
      await _recorderService.startRecording(
        onAudioWindow: enableRecording
            ? (audioWindow) async {
                // When recording is enabled, detection is processed in onRawAudioWindow
                // to ensure synchronization. This callback is kept for API compatibility
                // but does not process detection to avoid duplicate work.
                // The audioWindow parameter is from the SAME mic stream as onRawAudioWindow.
                if (verboseDebug) {
                  print('🔍 [DETECTOR] onAudioWindow called (recording enabled - detection processed in onRawAudioWindow to ensure sync)');
                }
              }
            : (audioWindow) async {
                // DISPATCH TO DETECTION: Normalized audio from shared mic stream
                // (Recording disabled - single callback path)
                try {
                  if (verboseDebug) {
                    print('🔍 [DETECTOR] Processing detection from shared mic stream (recording disabled)...');
                  }
                  final result = await _detectFromAudioWindow(audioWindow);
                  _liveDetectionController?.add(result);
                  onResult?.call(result);
                } catch (e) {
                  onError?.call(e);
                }
              },
        onRawAudioWindow: enableRecording && _recordingStateMachine != null
            ? (rawSamples) async {
                // DISPATCH TO BOTH DETECTION AND RECORDING: Raw PCM samples from SAME shared mic stream
                // This is the ONLY place where detection runs when recording is enabled,
                // ensuring perfect synchronization between detection results and raw samples.
                // No separate mic access - this is the same audio stream as onAudioWindow.
                try {
                  if (verboseDebug) {
                    print('📝 [DETECTOR] Processing detection + recording from shared mic stream (same PCM frames)...');
                  }
                  
                  // Convert raw samples to normalized for detection
                  final audioWindow = AudioProcessor.int16ToDouble(rawSamples);
                  
                  // Process detection (ONCE - not duplicated in onAudioWindow)
                  final result = await _detectFromAudioWindow(audioWindow);
                  
                  // Emit detection result
                  _liveDetectionController?.add(result);
                  onResult?.call(result);
                  
                  // DISPATCH TO RECORDING: Pass synchronized result + raw samples to state machine
                  // The raw samples are from the SAME mic stream - no separate recorder.
                  await _recordingStateMachine!.processDetectionResult(
                    result,
                    rawSamples,
                  );
                } catch (e) {
                  onError?.call(e);
                }
              }
            : null,
        verboseDebug: verboseDebug,
      );

      if (verboseDebug) {
        print('✅ [DETECTOR] Live detection started. Single mic stream active.');
        print('   - Detection: Processing normalized audio windows');
        if (enableRecording) {
          print('   - Recording: Processing raw PCM samples (same stream)');
        }
      }
    } catch (e) {
      // Clean up recording state machine on error
      if (_recordingStateMachine != null) {
        await _recordingStateMachine!.stop();
        _recordingStateMachine = null;
      }
      _liveDetectionController?.close();
      _liveDetectionController = null;
      rethrow;
    }

    return _liveDetectionController!.stream;
  }

  /// Stops live audio detection and releases microphone resources.
  ///
  /// **SINGLE MICROPHONE CLOSE**: This closes the shared microphone that was used
  /// for both detection and recording. The microphone is closed ONCE here.
  ///
  /// Safe to call even if detection is not running.
  /// If recording was active, it will be finalized before stopping.
  ///
  /// Example:
  /// ```dart
  /// await detector.stopLiveDetection();
  /// ```
  Future<void> stopLiveDetection({bool verboseDebug = false}) async {
    if (_liveDetectionController == null) {
      if (verboseDebug) {
        print('⚠️ [DETECTOR] stopLiveDetection() called but not detecting. Ignoring.');
      }
      return;
    }

    if (verboseDebug) {
      print('🛑 [DETECTOR] Stopping live detection (will close SINGLE shared microphone)...');
    }

    // Stop recording state machine if active (finalizes any active recording file)
    if (_recordingStateMachine != null) {
      if (verboseDebug) {
        print('📝 [DETECTOR] Finalizing active recording before closing mic...');
      }
      await _recordingStateMachine!.stop();
      _recordingStateMachine = null;
    }

    // CRITICAL: Close the SINGLE shared microphone
    // This stops both detection and recording since they share the same mic stream.
    await _recorderService.stopRecording(verboseDebug: verboseDebug);
    
    await _liveDetectionController?.close();
    _liveDetectionController = null;

    if (verboseDebug) {
      print('✅ [DETECTOR] Live detection stopped. Microphone closed.');
    }
  }

  /// Finalizes the current episode (save/discard) without stopping the mic.
  /// Prefer [stopLiveDetection] when pausing/ending a session.
  Future<void> finalizeActiveEpisode() async {
    await _recordingStateMachine?.finalizeActiveEpisode();
  }

  /// Detects snoring from a pre-recorded audio file.
  ///
  /// Analyzes the audio file in 1-second windows and returns results for each window.
  ///
  /// **Parameters:**
  /// - [filePath]: Absolute path to the audio file
  /// - [sampleRate]: Original sample rate of the audio (defaults to 16000 Hz if not specified)
  ///
  /// **Returns:** A list of [DetectionResult]s, one per 1-second window
  ///
  /// **Throws:**
  /// - [Exception] if file doesn't exist, is too short (< 1 second), or can't be read
  ///
  /// **Note:** Currently supports raw PCM files. WAV/MP3 support planned for future versions.
  ///
  /// Example:
  /// ```dart
  /// final results = await detector.detectFromFile(
  ///   '/path/to/recording.wav',
  ///   sampleRate: 16000,
  /// );
  ///
  /// print('Found ${results.where((r) => r.isSnoring).length} snoring events');
  /// ```
  Future<List<DetectionResult>> detectFromFile(
    String filePath, {
    int? sampleRate,
  }) async {
    _ensureInitialized();

    try {
      // Read audio file
      final audioData = await _readAudioFile(filePath, sampleRate);

      // Extract 1-second windows
      final windows = AudioProcessor.extractWindows(audioData);

      if (windows.isEmpty) {
        throw Exception(
            'Audio file too short. Need at least 1 second of audio.');
      }

      // Process each window
      final results = <DetectionResult>[];
      for (final window in windows) {
        final result = await _detectFromAudioWindow(window);
        results.add(result);
      }

      return results;
    } catch (e) {
      throw Exception('Failed to detect from file: $e');
    }
  }

  /// Detects snoring from a single 1-second audio window.
  ///
  /// **Parameters:**
  /// - [audioWindow]: Exactly 16000 normalized audio samples (-1.0 to 1.0)
  ///
  /// **Returns:** A [DetectionResult] for this audio window
  ///
  /// **Throws:** [ArgumentError] if window size is not exactly 16000 samples
  ///
  /// This is a low-level API. Most users should use [startLiveDetection]
  /// or [detectFromFile] instead.
  Future<DetectionResult> detectFromAudioWindow(
      List<double> audioWindow) async {
    _ensureInitialized();
    return _detectFromAudioWindow(audioWindow);
  }

  /// Internal method to process a single audio window
  Future<DetectionResult> _detectFromAudioWindow(
      List<double> audioWindow) async {
    // Normalize audio
    final normalizedAudio = AudioProcessor.normalize(audioWindow);

    // Extract spectrogram features
    final features = AudioProcessor.computeSpectrogramFeatures(normalizedAudio);

    // Run inference with current threshold
    final result = await _tfliteService.runInference(features,
        threshold: _currentThreshold);

    final hz = result.isSnoring
        ? AudioProcessor.estimateDominantFrequencyHz(normalizedAudio)
        : 0.0;

    return result.copyWith(dominantFrequencyHz: hz);
  }

  /// Read and preprocess audio file
  Future<List<double>> _readAudioFile(String filePath, int? sampleRate) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('File not found: $filePath');
    }

    // For now, we'll support raw PCM files
    // TODO: Add support for WAV, MP3, etc. using audio_processing packages
    final bytes = await file.readAsBytes();

    // Assume 16-bit PCM for now
    final samples = AudioProcessor.bytesToInt16(bytes);
    final audioData = AudioProcessor.int16ToDouble(samples);

    // Resample if needed
    if (sampleRate != null && sampleRate != AudioProcessor.targetSampleRate) {
      return AudioProcessor.resample(audioData, sampleRate);
    }

    return audioData;
  }

  /// Whether live detection is currently running.
  ///
  /// Returns `true` if [startLiveDetection] has been called and
  /// [stopLiveDetection] has not been called yet.
  bool get isLiveDetectionRunning => _liveDetectionController != null;

  /// Whether the detector has been successfully initialized.
  ///
  /// Returns `true` after [initialize] completes successfully.
  bool get isInitialized => _isInitialized;

  /// Ensure detector is initialized before use
  void _ensureInitialized() {
    if (!_isInitialized) {
      throw StateError(
          'SnoreDetector not initialized. Call initialize() first.');
    }
  }

  /// Lists all saved snore recordings.
  ///
  /// Returns a list of [SnoreRecordingInfo] objects containing metadata
  /// about each recording (file path, start timestamp, duration).
  ///
  /// Example:
  /// ```dart
  /// final recordings = await detector.listRecordings();
  /// for (final recording in recordings) {
  ///   print('${recording.filePath}: ${recording.duration.inSeconds}s');
  /// }
  /// ```
  Future<List<SnoreRecordingInfo>> listRecordings() async {
    return await _storageService.listRecordings();
  }

  /// Deletes a specific recording file.
  ///
  /// **Parameters:**
  /// - [filePath]: Absolute path to the recording file to delete
  ///
  /// The file and its metadata entry will be removed.
  ///
  /// Example:
  /// ```dart
  /// final recordings = await detector.listRecordings();
  /// if (recordings.isNotEmpty) {
  ///   await detector.deleteRecording(recordings.first.filePath);
  /// }
  /// ```
  Future<void> deleteRecording(String filePath) async {
    await _storageService.deleteRecording(filePath);
  }

  /// Deletes all saved recordings.
  ///
  /// Removes all recording files and clears the metadata.
  ///
  /// Example:
  /// ```dart
  /// await detector.deleteAllRecordings();
  /// ```
  Future<void> deleteAllRecordings() async {
    await _storageService.deleteAllRecordings();
  }

  /// Disposes all resources and stops any active detection.
  ///
  /// Always call this when done using the detector to free memory
  /// and release system resources.
  ///
  /// Example:
  /// ```dart
  /// @override
  /// void dispose() {
  ///   detector.dispose();
  ///   super.dispose();
  /// }
  /// ```
  void dispose() {
    stopLiveDetection();
    _recorderService.dispose();
    _tfliteService.dispose();
    _isInitialized = false;
  }
}

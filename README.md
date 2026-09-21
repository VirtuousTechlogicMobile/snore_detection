# Flutter Snore Detection

A Flutter package for detecting snoring in real-time audio streams or pre-recorded audio files using TensorFlow Lite.

## Features

- 🎤 **Live Audio Detection**: Real-time snoring detection from device microphone
- 📁 **File-Based Detection**: Analyze pre-recorded audio files
- 🎙️ **Automatic Recording**: Automatically record audio clips when snoring is detected
- 🚀 **Easy Integration**: Simple API for developers
- ⚡ **Efficient**: Uses quantized TensorFlow Lite model optimized for mobile devices
- 📱 **Cross-Platform**: Works on Android and iOS

## Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  snore_detection: ^0.3.0
```

Then run:
```bash
flutter pub get
```

For detailed installation instructions and platform setup, see the [Installation Guide](INSTALL_GUIDE.md).

## Usage

### Live Audio Detection

```dart
import 'package:snore_detection/snore_detection.dart';

// Initialize detector
final detector = SnoreDetector();
await detector.initialize();

// Request microphone permission
final hasPermission = await detector.requestMicrophonePermission();
if (!hasPermission) {
  print('Microphone permission denied');
  return;
}

// Start live detection
detector.startLiveDetection(
  onResult: (result) {
    print('Snoring detected: ${result.isSnoring}');
    print('Confidence: ${result.confidence}');
  },
);

// Stop detection
await detector.stopLiveDetection();
```

### Recording Snore Episodes

The package can automatically record audio when a snore **episode** is confirmed during live detection. This feature is optional and disabled by default.

**Key Features:**
- **Episode open**: Requires ~3 rhythmic discrete snores within 30 seconds
- **Episode close / merge**: Closes after 90 seconds of silence; shorter gaps stay in the same episode
- **Min duration**: Episodes under 60 seconds are discarded
- **Gap metadata**: Saved recordings include inter-snore gap stats
- **Automatic management**: Files are saved with metadata for easy listing and deletion

**Basic Usage:**

```dart
import 'package:snore_detection/snore_detection.dart';

final detector = SnoreDetector();
await detector.initialize();

// Request storage permission (required for recording)
final hasStoragePermission = await detector.requestStoragePermission();
if (!hasStoragePermission) {
  print('Storage permission required for recording');
  return;
}

// Start detection with episode recording enabled
await detector.startLiveDetection(
  onResult: (result) {
    // Detection results (same as before)
    print('Snoring: ${result.isSnoring}');
  },
  enableRecording: true,
  episodeOpenSnoreCount: 3,
  episodeOpenWindow: const Duration(seconds: 30),
  episodeCloseSilence: const Duration(seconds: 90),
  minEpisodeDuration: const Duration(seconds: 60),
  onRecordingSaved: (info) {
    print('Episode saved: ${info.filePath}');
    print('Duration: ${info.duration.inSeconds}s');
    print('Snore events: ${info.snoreEventCount}');
  },
  onEpisodeDiscarded: (duration) {
    print('Episode discarded (${duration.inSeconds}s < 60s)');
  },
);
```

**Behavior:**
- **Open**: 3 discrete snore bursts in 30s with inter-snore gaps between 2–6s (breath-rate gate).
- **Close**: After 90s continuous non-snore; quieter pauses merge into one episode.
- **Discard**: Kept audio shorter than 60s is deleted and not reported via `onRecordingSaved`.

**Managing Recordings:**

```dart
// List all recordings
final recordings = await detector.listRecordings();
for (final recording in recordings) {
  print('${recording.filePath}: ${recording.duration.inSeconds}s');
}

// Delete a specific recording
await detector.deleteRecording(recordings.first.filePath);

// Delete all recordings
await detector.deleteAllRecordings();
```

**Custom Filenames:**

```dart
await detector.startLiveDetection(
  enableRecording: true,
  fileNameBuilder: (index, startTimestamp) {
    // Custom filename format
    return 'my_snore_${index}_${startTimestamp.millisecondsSinceEpoch}.wav';
  },
  // ... other parameters
);
```

**Error Handling:**

If storage permission is denied when `enableRecording` is `true`, the library throws `SnoreStoragePermissionException`:

```dart
try {
  await detector.startLiveDetection(enableRecording: true, ...);
} on SnoreStoragePermissionException catch (e) {
  print('Storage permission required: $e');
  // Request permission and retry
  await detector.requestStoragePermission();
}
```

### File-Based Detection

```dart
import 'package:snore_detection/snore_detection.dart';

// Initialize detector
final detector = SnoreDetector();
await detector.initialize();

// Analyze audio file
final result = await detector.detectFromFile('/path/to/audio.wav');
print('Snoring detected: ${result.isSnoring}');
print('Confidence: ${result.confidence}');
```

## Running the Example App

To see the package in action, run the example app:

```bash
cd example
flutter pub get
flutter run
```

The example app demonstrates:
- Live audio detection with real-time results
- Visual feedback (icons, colors, confidence scores)
- Start/stop controls
- History of recent detections
- Recording snore audio clips with configurable delays
- Listing and managing saved recordings

Make sure you have a device or emulator connected, then select your target platform when prompted.

## Permissions

### Android

Add to your `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

**Note**: For recording functionality, storage permissions are handled automatically by the package. The package uses the app's documents directory which typically doesn't require explicit storage permissions on modern Android versions. However, if you encounter permission issues, you may need to add:

```xml
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" 
    android:maxSdkVersion="32" />
```

### iOS

Add to your `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to detect snoring</string>
```

## Model Information

- **Input**: 16 kHz mono audio, 1-second windows
- **Output**: Binary classification (noise vs snoring)
- **Model Type**: Quantized TensorFlow Lite (INT8)
- **Model Size**: 214 KB
- **Processing**: Spectrogram-based feature extraction
- **Inference Time**: ~50-100ms per 1-second window

## Documentation

- [Getting Started Guide](GETTING_STARTED.md) - Step-by-step tutorial with examples
- [API Documentation](API_DOCUMENTATION.md) - Complete API reference and advanced usage
- [Example App](example/) - Full working example with UI

## Troubleshooting

**Issue: Microphone permission denied**
- Ensure permissions are properly configured in platform-specific files
- Call `requestMicrophonePermission()` before starting detection (required on Android 6.0+ and iOS)

**Issue: Model fails to load**
- Make sure `flutter pub get` has been run
- Check that the asset is accessible in your build

**Issue: Low accuracy**
- Ensure quiet environment with minimal background noise
- Check microphone quality and placement
- Consider using confidence thresholds (e.g., > 0.85)

**Issue: Storage permission denied (when recording)**
- On Android, ensure you've called `requestStoragePermission()` before enabling recording
- The package uses app documents directory which typically doesn't require special permissions
- If issues persist, check Android version and storage permission requirements

## License

MIT License - see LICENSE file for details

## Credits

Based on the [Snoring Guardian](https://github.com/metanav/Snoring_Guardian) project.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
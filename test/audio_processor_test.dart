import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import '../lib/src/utils/audio_processor.dart';

void main() {
  group('AudioProcessor', () {
    test('normalize scales audio to -1.0 to 1.0 range', () {
      final audio = [0.0, 0.5, 1.0, -0.5, -1.0];
      final normalized = AudioProcessor.normalize(audio);

      expect(normalized.every((v) => v >= -1.0 && v <= 1.0), isTrue);
    });

    test('normalize handles all zeros', () {
      final audio = [0.0, 0.0, 0.0];
      final normalized = AudioProcessor.normalize(audio);

      expect(normalized, [0.0, 0.0, 0.0]);
    });

    test('bytesToInt16 converts bytes to 16-bit integers', () {
      final bytes = Uint8List.fromList([0, 0, 255, 127]); // Little-endian
      final samples = AudioProcessor.bytesToInt16(bytes);

      expect(samples.length, 2);
      expect(samples[0], 0);
      expect(samples[1], isNonZero);
    });

    test('int16ToDouble normalizes int16 samples to doubles', () {
      final samples = [0, 16384, -16384, 32767, -32768];
      final doubles = AudioProcessor.int16ToDouble(samples);

      expect(doubles.length, 5);
      expect(doubles[0], closeTo(0.0, 0.001));
      expect(doubles.every((v) => v >= -1.0 && v <= 1.0), isTrue);
    });

    test('extractWindows splits audio into 1-second chunks', () {
      final sampleRate = AudioProcessor.targetSampleRate;
      final audio = List.filled(sampleRate * 3, 0.0); // 3 seconds
      final windows = AudioProcessor.extractWindows(audio);

      expect(windows.length, 3);
      expect(windows[0].length, sampleRate);
      expect(windows[1].length, sampleRate);
      expect(windows[2].length, sampleRate);
    });

    test('extractWindows handles partial windows', () {
      final sampleRate = AudioProcessor.targetSampleRate;
      final audio = List.filled(sampleRate + 500, 0.0); // 1.5 seconds
      final windows = AudioProcessor.extractWindows(audio);

      expect(windows.length, 1); // Only complete windows
    });

    test('computeSpectrogramFeatures returns correct size', () {
      final sampleRate = AudioProcessor.targetSampleRate;
      final audio = List.filled(sampleRate, 0.0); // 1 second
      final features = AudioProcessor.computeSpectrogramFeatures(audio);

      expect(features.length, 4160); // Expected feature vector size
    });

    test('resample maintains audio length proportionally', () {
      final audio = List.filled(8000, 0.5); // 8kHz
      final resampled = AudioProcessor.resample(audio, 8000);

      expect(resampled.length, 16000); // Upsampled to 16kHz
    });

    test('resample handles downsampling', () {
      final audio = List.filled(32000, 0.5); // 32kHz
      final resampled = AudioProcessor.resample(audio, 32000);

      expect(resampled.length, 16000); // Downsampled to 16kHz
    });

    test('estimateDominantFrequencyHz finds in-band sine peak', () {
      const sampleRate = AudioProcessor.targetSampleRate;
      const targetHz = 80.0;
      final audio = List<double>.generate(sampleRate, (i) {
        return 0.5 *
            math.sin(2 * math.pi * targetHz * i / sampleRate);
      });

      final hz = AudioProcessor.estimateDominantFrequencyHz(audio);
      // FFT 2048 → bin ~7.8 Hz
      expect(hz, closeTo(targetHz, 10.0));
    });

    test('estimateDominantFrequencyHz returns 0 for silence', () {
      final silence = List.filled(AudioProcessor.targetSampleRate, 0.0);
      expect(AudioProcessor.estimateDominantFrequencyHz(silence), 0.0);
    });
  });
}

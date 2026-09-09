import 'dart:io';
import 'dart:typed_data';

/// Utility for writing WAV audio files.
///
/// **CRITICAL: No Microphone Access**
/// This class ONLY writes PCM audio data to disk in WAV format. It does NOT
/// open or access a microphone. The audio data must be provided via [writeSamples]
/// from an external source (e.g., the shared microphone stream used for detection).
///
/// Handles writing PCM audio data to WAV format with proper headers.
class WavWriter {
  /// Sample rate (Hz)
  final int sampleRate;

  /// Number of channels (1 = mono, 2 = stereo)
  final int numChannels;

  /// Bits per sample (typically 16)
  final int bitsPerSample;

  /// File handle
  final File _file;

  /// Random access file
  RandomAccessFile? _raf;

  /// Total number of samples written
  int _totalSamples = 0;

  /// Whether the file is open
  bool _isOpen = false;

  /// Creates a WAV writer for the given file.
  ///
  /// The file will be created and a WAV header will be written.
  /// Call [writeSamples] to add audio data, then [close] to finalize.
  WavWriter({
    required File file,
    this.sampleRate = 16000,
    this.numChannels = 1,
    this.bitsPerSample = 16,
  }) : _file = file;

  /// Opens the file and writes the WAV header.
  ///
  /// The header is initially written with a placeholder data size,
  /// which will be updated when [close] is called.
  Future<void> open() async {
    if (_isOpen) {
      throw StateError('WAV file already open');
    }

    _raf = await _file.open(mode: FileMode.write);
    _isOpen = true;
    _totalSamples = 0;

    // Write WAV header (will be updated on close)
    await _writeHeader();
  }

  /// Writes audio samples to the file.
  ///
  /// [samples] should be Int16 PCM samples (values from -32768 to 32767).
  Future<void> writeSamples(List<int> samples) async {
    if (!_isOpen || _raf == null) {
      throw StateError('WAV file not open. Call open() first.');
    }

    // Convert to bytes (little endian)
    final bytes = Uint8List(samples.length * 2);
    for (int i = 0; i < samples.length; i++) {
      final sample = samples[i].clamp(-32768, 32767);
      // Little endian: low byte first
      bytes[i * 2] = sample & 0xFF;
      bytes[i * 2 + 1] = (sample >> 8) & 0xFF;
    }

    await _raf!.writeFrom(bytes);
    _totalSamples += samples.length;
  }

  /// Closes the file and updates the WAV header with correct data size.
  ///
  /// This must be called to ensure the WAV file is valid.
  Future<void> close() async {
    if (!_isOpen || _raf == null) {
      return;
    }

    // Calculate data size
    final dataSize = _totalSamples * numChannels * (bitsPerSample ~/ 8);
    final fileSize = 36 + dataSize; // 36 = header size, dataSize = actual audio data

    // Seek to beginning and update header
    await _raf!.setPosition(0);
    await _writeHeader(dataSize: dataSize, fileSize: fileSize);

    // Close file
    await _raf!.close();
    _raf = null;
    _isOpen = false;
  }

  /// Writes the WAV file header.
  ///
  /// WAV file format:
  /// - RIFF header (12 bytes)
  /// - fmt chunk (24 bytes)
  /// - data chunk header (8 bytes)
  /// - audio data (dataSize bytes)
  Future<void> _writeHeader({
    int? dataSize,
    int? fileSize,
  }) async {
    if (_raf == null) {
      throw StateError('File not open');
    }

    final actualDataSize = dataSize ?? 0;
    final actualFileSize = fileSize ?? (36 + actualDataSize);
    final byteRate = sampleRate * numChannels * (bitsPerSample ~/ 8);
    final blockAlign = numChannels * (bitsPerSample ~/ 8);

    // RIFF header
    await _raf!.writeFrom('RIFF'.codeUnits);
    await _writeInt32(actualFileSize - 8); // File size - 8 (excluding RIFF and size fields)
    await _raf!.writeFrom('WAVE'.codeUnits);

    // fmt chunk
    await _raf!.writeFrom('fmt '.codeUnits);
    await _writeInt32(16); // fmt chunk size
    await _writeInt16(1); // Audio format (1 = PCM)
    await _writeInt16(numChannels);
    await _writeInt32(sampleRate);
    await _writeInt32(byteRate);
    await _writeInt16(blockAlign);
    await _writeInt16(bitsPerSample);

    // data chunk
    await _raf!.writeFrom('data'.codeUnits);
    await _writeInt32(actualDataSize);
  }

  /// Writes a 16-bit integer (little endian)
  Future<void> _writeInt16(int value) async {
    final bytes = Uint8List(2);
    bytes[0] = value & 0xFF;
    bytes[1] = (value >> 8) & 0xFF;
    await _raf!.writeFrom(bytes);
  }

  /// Writes a 32-bit integer (little endian)
  Future<void> _writeInt32(int value) async {
    final bytes = Uint8List(4);
    bytes[0] = value & 0xFF;
    bytes[1] = (value >> 8) & 0xFF;
    bytes[2] = (value >> 16) & 0xFF;
    bytes[3] = (value >> 24) & 0xFF;
    await _raf!.writeFrom(bytes);
  }

  /// Gets the current duration in seconds.
  double get durationSeconds => _totalSamples / sampleRate;
}


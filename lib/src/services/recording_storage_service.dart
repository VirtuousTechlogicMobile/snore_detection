import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/snore_recording_info.dart';

/// Service for managing snore recording files and metadata.
class RecordingStorageService {
  static const String _recordingsDirName = 'snore_recordings';
  static const String _metadataFileName = 'recordings.json';

  Directory? _recordingsDir;
  File? _metadataFile;
  String? _customRecordingsDirectory;

  /// Sets a custom recordings directory path.
  /// If set, this will be used instead of the default directory.
  void setCustomRecordingsDirectory(String? directoryPath) {
    _customRecordingsDirectory = directoryPath;
    _recordingsDir = null; // Reset cached directory
    _metadataFile = null; // Reset cached metadata file
  }

  /// Gets the recordings directory, creating it if necessary.
  Future<Directory> _getRecordingsDirectory() async {
    if (_recordingsDir != null) {
      return _recordingsDir!;
    }

    // Use custom directory if provided, otherwise use default
    if (_customRecordingsDirectory != null) {
      _recordingsDir = Directory(_customRecordingsDirectory!);
    } else {
      final appDir = await getApplicationDocumentsDirectory();
      _recordingsDir = Directory('${appDir.path}/$_recordingsDirName');
    }

    if (!await _recordingsDir!.exists()) {
      await _recordingsDir!.create(recursive: true);
    }

    return _recordingsDir!;
  }

  /// Gets the metadata file.
  Future<File> _getMetadataFile() async {
    if (_metadataFile != null) {
      return _metadataFile!;
    }

    final dir = await _getRecordingsDirectory();
    _metadataFile = File('${dir.path}/$_metadataFileName');
    return _metadataFile!;
  }

  /// Generates a default filename for a recording.
  ///
  /// Format: `snore_YYYYMMDD_HHMMSS_<index>.wav`
  String _generateDefaultFileName(int index, DateTime timestamp) {
    final year = timestamp.year.toString().padLeft(4, '0');
    final month = timestamp.month.toString().padLeft(2, '0');
    final day = timestamp.day.toString().padLeft(2, '0');
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final second = timestamp.second.toString().padLeft(2, '0');

    return 'snore_${year}${month}${day}_${hour}${minute}${second}_$index.wav';
  }

  /// Creates a new recording file path.
  ///
  /// Uses [fileNameBuilder] if provided, otherwise generates a default name.
  Future<String> createRecordingFilePath({
    required int index,
    required DateTime timestamp,
    String Function(int index, DateTime timestamp)? fileNameBuilder,
  }) async {
    final dir = await _getRecordingsDirectory();
    final fileName = fileNameBuilder != null
        ? fileNameBuilder(index, timestamp)
        : _generateDefaultFileName(index, timestamp);

    // Sanitize filename (remove path separators)
    final safeFileName = fileName.replaceAll(RegExp(r'[/\\]'), '_');

    return '${dir.path}/$safeFileName';
  }

  /// Saves recording metadata.
  Future<void> saveRecordingMetadata(SnoreRecordingInfo info) async {
    final metadataFile = await _getMetadataFile();
    final recordings = await listRecordings();

    // Add new recording
    recordings.add(info);

    // Write to file
    final jsonList = recordings.map((r) => r.toJson()).toList();
    await metadataFile.writeAsString(jsonEncode(jsonList));
  }

  /// Lists all recordings from metadata.
  Future<List<SnoreRecordingInfo>> listRecordings() async {
    final metadataFile = await _getMetadataFile();

    if (!await metadataFile.exists()) {
      return [];
    }

    try {
      final content = await metadataFile.readAsString();
      if (content.isEmpty) {
        return [];
      }

      final jsonList = jsonDecode(content) as List;
      final recordings = jsonList
          .map((json) => SnoreRecordingInfo.fromJson(json as Map<String, dynamic>))
          .toList();

      // Filter out recordings where files don't exist
      final validRecordings = <SnoreRecordingInfo>[];
      for (final recording in recordings) {
        final file = File(recording.filePath);
        if (await file.exists()) {
          validRecordings.add(recording);
        }
      }

      // Update metadata if any files were missing
      if (validRecordings.length != recordings.length) {
        final jsonList = validRecordings.map((r) => r.toJson()).toList();
        await metadataFile.writeAsString(jsonEncode(jsonList));
      }

      return validRecordings;
    } catch (e) {
      // If metadata is corrupted, return empty list
      return [];
    }
  }

  /// Deletes a recording file and removes it from metadata.
  Future<void> deleteRecording(String filePath) async {
    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
    }

    // Remove from metadata
    final recordings = await listRecordings();
    recordings.removeWhere((r) => r.filePath == filePath);

    final metadataFile = await _getMetadataFile();
    final jsonList = recordings.map((r) => r.toJson()).toList();
    await metadataFile.writeAsString(jsonEncode(jsonList));
  }

  /// Deletes all recordings and clears metadata.
  Future<void> deleteAllRecordings() async {
    final recordings = await listRecordings();

    // Delete all files
    for (final recording in recordings) {
      final file = File(recording.filePath);
      if (await file.exists()) {
        await file.delete();
      }
    }

    // Clear metadata
    final metadataFile = await _getMetadataFile();
    await metadataFile.writeAsString('[]');
  }

  /// Gets the recordings directory path.
  Future<String> getRecordingsDirectoryPath() async {
    final dir = await _getRecordingsDirectory();
    return dir.path;
  }
}


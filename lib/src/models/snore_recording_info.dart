/// Information about a saved snore recording.
///
/// Contains metadata about a recording file that was created during
/// live detection when snoring was detected.
class SnoreRecordingInfo {
  /// Absolute file path to the recording file.
  final String filePath;

  /// Timestamp when recording started.
  final DateTime startTimestamp;

  /// Duration of the recording.
  final Duration duration;

  /// Creates a recording info object.
  SnoreRecordingInfo({
    required this.filePath,
    required this.startTimestamp,
    required this.duration,
  });

  /// Creates a recording info from JSON.
  factory SnoreRecordingInfo.fromJson(Map<String, dynamic> json) {
    return SnoreRecordingInfo(
      filePath: json['filePath'] as String,
      startTimestamp: DateTime.parse(json['startTimestamp'] as String),
      duration: Duration(milliseconds: json['durationMs'] as int),
    );
  }

  /// Converts to JSON for storage.
  Map<String, dynamic> toJson() {
    return {
      'filePath': filePath,
      'startTimestamp': startTimestamp.toIso8601String(),
      'durationMs': duration.inMilliseconds,
    };
  }

  @override
  String toString() {
    return 'SnoreRecordingInfo(filePath: $filePath, '
        'startTimestamp: $startTimestamp, duration: ${duration.inSeconds}s)';
  }
}


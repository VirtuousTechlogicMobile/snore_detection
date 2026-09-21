/// Information about a saved snore episode recording.
///
/// Contains metadata about a recording file that was created during
/// live detection when a snore episode was confirmed and kept.
class SnoreRecordingInfo {
  /// Absolute file path to the recording file.
  final String filePath;

  /// Timestamp when the episode recording started
  /// (aligned with the first snore of the qualifying open pattern).
  final DateTime startTimestamp;

  /// Duration of the kept audio (trailing close-silence trimmed).
  final Duration duration;

  /// Number of discrete snore events detected during the episode.
  final int snoreEventCount;

  /// Gaps between consecutive discrete snores, in milliseconds.
  final List<int> interSnoreGapsMs;

  /// Largest inter-snore gap in milliseconds, or 0 if fewer than 2 snores.
  final int maxInterSnoreGapMs;

  /// Creates a recording info object.
  SnoreRecordingInfo({
    required this.filePath,
    required this.startTimestamp,
    required this.duration,
    this.snoreEventCount = 0,
    List<int>? interSnoreGapsMs,
    int? maxInterSnoreGapMs,
  })  : interSnoreGapsMs = List.unmodifiable(interSnoreGapsMs ?? const []),
        maxInterSnoreGapMs = maxInterSnoreGapMs ??
            ((interSnoreGapsMs == null || interSnoreGapsMs.isEmpty)
                ? 0
                : interSnoreGapsMs.reduce((a, b) => a > b ? a : b));

  /// Creates a recording info from JSON.
  factory SnoreRecordingInfo.fromJson(Map<String, dynamic> json) {
    final gapsRaw = json['interSnoreGapsMs'];
    final gaps = gapsRaw is List
        ? gapsRaw.map((e) => (e as num).toInt()).toList()
        : <int>[];

    return SnoreRecordingInfo(
      filePath: json['filePath'] as String,
      startTimestamp: DateTime.parse(json['startTimestamp'] as String),
      duration: Duration(milliseconds: json['durationMs'] as int),
      snoreEventCount: (json['snoreEventCount'] as num?)?.toInt() ?? 0,
      interSnoreGapsMs: gaps,
      maxInterSnoreGapMs: (json['maxInterSnoreGapMs'] as num?)?.toInt(),
    );
  }

  /// Converts to JSON for storage.
  Map<String, dynamic> toJson() {
    return {
      'filePath': filePath,
      'startTimestamp': startTimestamp.toIso8601String(),
      'durationMs': duration.inMilliseconds,
      'snoreEventCount': snoreEventCount,
      'interSnoreGapsMs': interSnoreGapsMs,
      'maxInterSnoreGapMs': maxInterSnoreGapMs,
    };
  }

  @override
  String toString() {
    return 'SnoreRecordingInfo(filePath: $filePath, '
        'startTimestamp: $startTimestamp, duration: ${duration.inSeconds}s, '
        'snoreEventCount: $snoreEventCount, '
        'maxInterSnoreGapMs: $maxInterSnoreGapMs)';
  }
}

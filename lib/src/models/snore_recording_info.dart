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

  /// Mean dBFS of snore-event frames only (power-domain average).
  final double? snoreLevelDb;

  /// dBFS of the loudest single snore event (per-event power mean).
  final double? maxSnoreDb;

  /// 10th percentile of all episode 100 ms dBFS frames (room floor).
  final double? noiseFloorDb;

  /// Share of Int16 samples at full scale (0–100).
  final double? clippedPercent;

  /// Count of inter-snore gaps of 10 s or more inside the episode.
  final int? pauseCount;

  /// Creates a recording info object.
  SnoreRecordingInfo({
    required this.filePath,
    required this.startTimestamp,
    required this.duration,
    this.snoreEventCount = 0,
    List<int>? interSnoreGapsMs,
    int? maxInterSnoreGapMs,
    this.snoreLevelDb,
    this.maxSnoreDb,
    this.noiseFloorDb,
    this.clippedPercent,
    this.pauseCount,
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
      snoreLevelDb: (json['snoreLevelDb'] as num?)?.toDouble(),
      maxSnoreDb: (json['maxSnoreDb'] as num?)?.toDouble(),
      noiseFloorDb: (json['noiseFloorDb'] as num?)?.toDouble(),
      clippedPercent: (json['clippedPercent'] as num?)?.toDouble(),
      pauseCount: (json['pauseCount'] as num?)?.toInt(),
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
      if (snoreLevelDb != null) 'snoreLevelDb': snoreLevelDb,
      if (maxSnoreDb != null) 'maxSnoreDb': maxSnoreDb,
      if (noiseFloorDb != null) 'noiseFloorDb': noiseFloorDb,
      if (clippedPercent != null) 'clippedPercent': clippedPercent,
      if (pauseCount != null) 'pauseCount': pauseCount,
    };
  }

  @override
  String toString() {
    return 'SnoreRecordingInfo(filePath: $filePath, '
        'startTimestamp: $startTimestamp, duration: ${duration.inSeconds}s, '
        'snoreEventCount: $snoreEventCount, '
        'maxInterSnoreGapMs: $maxInterSnoreGapMs, '
        'snoreLevelDb: $snoreLevelDb, maxSnoreDb: $maxSnoreDb)';
  }
}

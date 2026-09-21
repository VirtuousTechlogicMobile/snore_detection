/// Result of a single snore detection inference.
///
/// Contains confidence scores for both snoring and noise classes,
/// along with the final classification decision and timestamp.
class DetectionResult {
  /// Whether snoring was detected in this audio window.
  ///
  /// This is `true` if the snoring confidence exceeds the configured
  /// threshold and is higher than the noise confidence.
  final bool isSnoring;

  /// Confidence score for the snoring class (0.0 to 1.0).
  ///
  /// Higher values indicate stronger likelihood that snoring was present
  /// in the analyzed audio window.
  final double snoringConfidence;

  /// Confidence score for the noise class (0.0 to 1.0).
  ///
  /// Higher values indicate stronger likelihood that only noise (no snoring)
  /// was present in the analyzed audio window.
  final double noiseConfidence;

  /// Dominant frequency (Hz) from FFT peak in the snore band, or `0` if none.
  final double dominantFrequencyHz;

  /// Timestamp when this detection occurred.
  ///
  /// Defaults to [DateTime.now()] if not explicitly provided.
  final DateTime timestamp;

  /// Creates a detection result with explicit classification.
  ///
  /// Use [DetectionResult.withThreshold] for automatic threshold-based classification.
  DetectionResult({
    required this.isSnoring,
    required this.snoringConfidence,
    required this.noiseConfidence,
    this.dominantFrequencyHz = 0.0,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Creates a detection result by applying a confidence threshold.
  ///
  /// Classifies as snoring only if:
  /// - [snoringConfidence] exceeds [threshold]
  /// - [snoringConfidence] is higher than [noiseConfidence]
  factory DetectionResult.withThreshold({
    required double snoringConfidence,
    required double noiseConfidence,
    required double threshold,
    double dominantFrequencyHz = 0.0,
    DateTime? timestamp,
  }) {
    final isSnoring =
        snoringConfidence > threshold && snoringConfidence > noiseConfidence;

    return DetectionResult(
      isSnoring: isSnoring,
      snoringConfidence: snoringConfidence,
      noiseConfidence: noiseConfidence,
      dominantFrequencyHz: dominantFrequencyHz,
      timestamp: timestamp,
    );
  }

  /// Copy with optional field overrides.
  DetectionResult copyWith({
    bool? isSnoring,
    double? snoringConfidence,
    double? noiseConfidence,
    double? dominantFrequencyHz,
    DateTime? timestamp,
  }) {
    return DetectionResult(
      isSnoring: isSnoring ?? this.isSnoring,
      snoringConfidence: snoringConfidence ?? this.snoringConfidence,
      noiseConfidence: noiseConfidence ?? this.noiseConfidence,
      dominantFrequencyHz: dominantFrequencyHz ?? this.dominantFrequencyHz,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  /// Returns the confidence score of the predicted class.
  double get confidence => isSnoring ? snoringConfidence : noiseConfidence;

  @override
  String toString() {
    return 'DetectionResult(isSnoring: $isSnoring, confidence: ${confidence.toStringAsFixed(3)}, '
        'snoringConf: ${snoringConfidence.toStringAsFixed(3)}, '
        'noiseConf: ${noiseConfidence.toStringAsFixed(3)}, '
        'freqHz: ${dominantFrequencyHz.toStringAsFixed(1)})';
  }
}

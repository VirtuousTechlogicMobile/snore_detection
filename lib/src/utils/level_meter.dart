import 'dart:math' as math;

/// dB relative to full scale for one frame of samples scaled to -1.0..1.0.
/// Pure silence has no logarithm, so it is clamped to [floorDb].
double dbfs(List<double> frame, {double floorDb = -120}) {
  if (frame.isEmpty) return floorDb;
  var sum = 0.0;
  for (final s in frame) {
    sum += s * s;
  }
  final rms = math.sqrt(sum / frame.length);
  if (rms <= 0) return floorDb;
  return math.max(floorDb, 20 * math.log(rms) / math.ln10);
}

/// Feed raw 16-bit mono PCM samples from the shared mic / episode WAV path.
/// Returns one dBFS reading for every completed [frameMs] frame.
class LevelMeter {
  LevelMeter({required this.sampleRate, this.frameMs = 100})
      : _frameLength = sampleRate * frameMs ~/ 1000;

  final int sampleRate;
  final int frameMs;
  final int _frameLength;

  final List<double> _frame = [];
  int totalSamples = 0;
  int clippedSamples = 0;

  /// Adds Int16 PCM samples. Completes zero or more 100 ms dBFS frames.
  List<double> addSamples(List<int> pcm16) {
    final out = <double>[];
    for (final sample in pcm16) {
      _push(sample, out);
    }
    return out;
  }

  void reset() {
    _frame.clear();
    totalSamples = 0;
    clippedSamples = 0;
  }

  void _push(int sample, List<double> out) {
    totalSamples++;
    if (sample >= 32767 || sample <= -32768) clippedSamples++;
    _frame.add(sample / 32768.0);
    if (_frame.length == _frameLength) {
      out.add(dbfs(_frame));
      _frame.clear();
    }
  }
}

/// A snore event as milliseconds from the episode start.
class SnoreLevelEvent {
  const SnoreLevelEvent({required this.startMs, required this.endMs});
  final int startMs;
  final int endMs;
}

/// Per-episode loudness fields for the snoring upload API.
class EpisodeLevels {
  const EpisodeLevels({
    required this.snoreLevelDb,
    required this.maxSnoreDb,
    required this.noiseFloorDb,
    required this.clippedPercent,
  });

  final double snoreLevelDb;
  final double maxSnoreDb;
  final double noiseFloorDb;
  final double clippedPercent;
}

/// [frames] is every 100 ms dBFS reading from the episode's start to its end.
EpisodeLevels episodeLevels({
  required List<double> frames,
  required List<SnoreLevelEvent> events,
  required int frameMs,
  required int clippedSamples,
  required int totalSamples,
}) {
  final snoreFrames = <double>[];
  var maxSnore = double.negativeInfinity;

  for (final e in events) {
    final start = (e.startMs ~/ frameMs).clamp(0, frames.length);
    final end = (e.endMs / frameMs).ceil().clamp(start, frames.length);
    final slice = frames.sublist(start, end);
    if (slice.isEmpty) continue;
    snoreFrames.addAll(slice);
    maxSnore = math.max(maxSnore, meanDb(slice));
  }

  return EpisodeLevels(
    snoreLevelDb: snoreFrames.isEmpty ? -120 : meanDb(snoreFrames),
    maxSnoreDb: maxSnore.isFinite ? maxSnore : -120,
    noiseFloorDb: percentile(frames, 0.10),
    clippedPercent:
        totalSamples == 0 ? 0 : clippedSamples * 100 / totalSamples,
  );
}

/// Average in the power domain, then back to dB.
double meanDb(List<double> dbs) {
  if (dbs.isEmpty) return -120;
  var power = 0.0;
  for (final db in dbs) {
    power += math.pow(10, db / 10);
  }
  return 10 * math.log(power / dbs.length) / math.ln10;
}

double percentile(List<double> values, double p) {
  if (values.isEmpty) return -120;
  final sorted = List<double>.from(values)..sort();
  return sorted[((sorted.length - 1) * p).floor()];
}

/// Optional live PCM level hook for UI meters (mic-style bars).
///
/// Set [snoreLivePcmListener] from the app before
/// [SnoreDetector.startLiveDetection]. Clear on stop.
/// Receives raw Int16 PCM chunks from the shared mic stream.
///
/// Additive / optional: detection + recording behave the same when null.
library;

typedef SnoreLivePcmListener = void Function(List<int> pcm16Samples);

SnoreLivePcmListener? snoreLivePcmListener;

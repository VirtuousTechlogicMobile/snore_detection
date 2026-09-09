/// Exception thrown when storage permission is required but not granted.
///
/// This exception is thrown when recording is enabled but the app
/// doesn't have the necessary storage permissions to save audio files.
class SnoreStoragePermissionException implements Exception {
  /// Error message describing the permission issue.
  final String message;

  /// Creates a storage permission exception.
  SnoreStoragePermissionException(this.message);

  @override
  String toString() => 'SnoreStoragePermissionException: $message';
}


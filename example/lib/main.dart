import 'package:flutter/material.dart';
import 'package:snore_detection/snore_detection.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Snore Detection Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const SnoreDetectionDemo(),
    );
  }
}

class SnoreDetectionDemo extends StatefulWidget {
  const SnoreDetectionDemo({super.key});

  @override
  State<SnoreDetectionDemo> createState() => _SnoreDetectionDemoState();
}

class _SnoreDetectionDemoState extends State<SnoreDetectionDemo> {
  final SnoreDetector _detector = SnoreDetector();
  bool _isInitialized = false;
  bool _isDetecting = false;
  DetectionResult? _latestResult;
  final List<DetectionResult> _recentResults = [];
  String _statusMessage = 'Tap "Initialize" to start';
  double _confidenceThreshold = 0.5; // 50% threshold
  bool _verboseDebug = true; // Debug logging toggle
  
  // Recording settings
  bool _enableRecording = false;
  int _recordingStartDelaySeconds = 3;
  int _recordingStopDelaySeconds = 2;
  final List<SnoreRecordingInfo> _recordings = [];
  bool _isLoadingRecordings = false;

  @override
  void dispose() {
    _detector.dispose();
    super.dispose();
  }

  Future<void> _loadRecordings() async {
    setState(() {
      _isLoadingRecordings = true;
    });

    try {
      final recordings = await _detector.listRecordings();
      setState(() {
        _recordings.clear();
        _recordings.addAll(recordings);
        _isLoadingRecordings = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingRecordings = false;
        _statusMessage = 'Error loading recordings: $e';
      });
    }
  }

  Future<void> _deleteRecording(SnoreRecordingInfo recording) async {
    try {
      await _detector.deleteRecording(recording.filePath);
      await _loadRecordings();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recording deleted')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting recording: $e')),
        );
      }
    }
  }

  Future<void> _deleteAllRecordings() async {
    try {
      await _detector.deleteAllRecordings();
      await _loadRecordings();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All recordings deleted')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting recordings: $e')),
        );
      }
    }
  }

  Future<void> _initialize() async {
    setState(() {
      _statusMessage = 'Initializing...';
    });

    try {
      await _detector.initialize();
      setState(() {
        _isInitialized = true;
        _statusMessage = 'Ready! Tap "Start Detection" to begin.';
      });
      
      // Load existing recordings
      await _loadRecordings();
    } catch (e) {
      setState(() {
        _statusMessage = 'Error: $e';
      });
    }
  }

  Future<void> _startDetection() async {
    if (!_isInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please initialize first')),
      );
      return;
    }

    // Request microphone permission before starting
    final hasPermission = await _detector.requestMicrophonePermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission is required for detection'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    setState(() {
      _isDetecting = true;
      _statusMessage = 'Listening... (Processing 1-second windows)';
      _recentResults.clear();
    });

    // If recording is enabled, request storage permission
    if (_enableRecording) {
      try {
        final hasStoragePermission = await _detector.requestStoragePermission();
        if (!hasStoragePermission) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Storage permission is required for recording'),
                duration: Duration(seconds: 3),
              ),
            );
          }
          return;
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Storage permission error: $e')),
          );
        }
        return;
      }
    }

    try {
      await _detector.startLiveDetection(
        confidenceThreshold: _confidenceThreshold,
        verboseDebug: _verboseDebug,
        enableRecording: _enableRecording,
        recordingStartDelay: Duration(seconds: _recordingStartDelaySeconds),
        recordingStopDelay: Duration(seconds: _recordingStopDelaySeconds),
        onResult: (result) {
          if (_verboseDebug) {
            // ignore: avoid_print
            print(
                '📊 Detection result: ${result.isSnoring ? "SNORING" : "NOISE"} '
                '(confidence: ${(result.confidence * 100).toStringAsFixed(1)}%)');
          }

          setState(() {
            _latestResult = result;
            _recentResults.insert(0, result);
            if (_recentResults.length > 10) {
              _recentResults.removeLast();
            }

            if (result.isSnoring) {
              _statusMessage =
                  '🔴 Snoring detected! (${(result.confidence * 100).toStringAsFixed(1)}%)';
            } else {
              _statusMessage =
                  '🟢 No snoring (${(result.confidence * 100).toStringAsFixed(1)}%)';
            }
          });
        },
        onError: (error) {
          if (_verboseDebug) {
            // ignore: avoid_print
            print('❌ Detection error: $error');
          }
          setState(() {
            _statusMessage = 'Error: $error';
          });
        },
        onRecordingSaved: (info) {
          // ignore: avoid_print
          print('✅ Recording saved: ${info.filePath}');
          // ignore: avoid_print
          print('   Duration: ${info.duration.inSeconds}s');
          // ignore: avoid_print
          print('   Start: ${info.startTimestamp}');
          
          // Reload recordings list
          _loadRecordings();
        },
      );
    } catch (e) {
      if (_verboseDebug) {
        // ignore: avoid_print
        print('❌ Failed to start: $e');
      }
      setState(() {
        _isDetecting = false;
        _statusMessage = 'Error starting detection: $e';
      });
    }
  }

  Future<void> _stopDetection() async {
    await _detector.stopLiveDetection();
    setState(() {
      _isDetecting = false;
      _statusMessage = 'Stopped';
    });
    
    // Reload recordings after stopping
    if (_enableRecording) {
      await _loadRecordings();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Snore Detection Demo'),
        elevation: 2,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Status',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _statusMessage,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Latest Result Card
              if (_latestResult != null)
                Card(
                  color: _latestResult!.isSnoring
                      ? Colors.red.shade50
                      : Colors.green.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _latestResult!.isSnoring
                                  ? Icons.volume_up
                                  : Icons.volume_off,
                              size: 32,
                              color: _latestResult!.isSnoring
                                  ? Colors.red
                                  : Colors.green,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _latestResult!.isSnoring
                                        ? 'SNORING'
                                        : 'NOISE',
                                    style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: _latestResult!.isSnoring
                                          ? Colors.red
                                          : Colors.green,
                                    ),
                                  ),
                                  Text(
                                    'Confidence: ${(_latestResult!.confidence * 100).toStringAsFixed(1)}%',
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildConfidenceChip(
                              'Snoring',
                              _latestResult!.snoringConfidence,
                              Colors.red,
                            ),
                            _buildConfidenceChip(
                              'Noise',
                              _latestResult!.noiseConfidence,
                              Colors.green,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 16),

              // Settings Card
              if (_isInitialized) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Confidence Threshold Slider
                        if (!_isDetecting) ...[
                          Text(
                            'Confidence Threshold: ${(_confidenceThreshold * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Slider(
                            value: _confidenceThreshold,
                            min: 0.1,
                            max: 0.9,
                            divisions: 16,
                            label:
                                '${(_confidenceThreshold * 100).toStringAsFixed(0)}%',
                            onChanged: (value) {
                              setState(() => _confidenceThreshold = value);
                            },
                          ),
                          const Text(
                            'Higher threshold = fewer false positives',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const SizedBox(height: 16),
                          const Divider(),
                          const SizedBox(height: 8),
                        ],

                        // Verbose Debug Toggle
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Verbose Debug Logging',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: const Text(
                            'Log detection results to console',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          value: _verboseDebug,
                          onChanged: (value) {
                            setState(() => _verboseDebug = value);
                          },
                        ),
                        
                        if (!_isDetecting) ...[
                          const SizedBox(height: 16),
                          const Divider(),
                          const SizedBox(height: 8),
                          
                          // Recording Toggle
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              'Record Snore Audio',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: const Text(
                              'Automatically record audio when snoring is detected',
                              style: TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            value: _enableRecording,
                            onChanged: (value) {
                              setState(() => _enableRecording = value);
                            },
                          ),
                          
                          if (_enableRecording) ...[
                            const SizedBox(height: 16),
                            
                            // Recording Start Delay
                            Text(
                              'Recording Start Delay: ${_recordingStartDelaySeconds}s',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Slider(
                              value: _recordingStartDelaySeconds.toDouble(),
                              min: 1,
                              max: 10,
                              divisions: 9,
                              label: '${_recordingStartDelaySeconds}s',
                              onChanged: (value) {
                                setState(() => _recordingStartDelaySeconds = value.toInt());
                              },
                            ),
                            const Text(
                              'Minimum snore duration before recording starts',
                              style: TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            
                            const SizedBox(height: 16),
                            
                            // Recording Stop Delay
                            Text(
                              'Recording Stop Delay: ${_recordingStopDelaySeconds}s',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Slider(
                              value: _recordingStopDelaySeconds.toDouble(),
                              min: 1,
                              max: 10,
                              divisions: 9,
                              label: '${_recordingStopDelaySeconds}s',
                              onChanged: (value) {
                                setState(() => _recordingStopDelaySeconds = value.toInt());
                              },
                            ),
                            const Text(
                              'Minimum noise duration before recording stops',
                              style: TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Control Buttons
              if (!_isInitialized)
                ElevatedButton.icon(
                  onPressed: _initialize,
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('Initialize Detector'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),

              if (_isInitialized && !_isDetecting)
                ElevatedButton.icon(
                  onPressed: _startDetection,
                  icon: const Icon(Icons.mic),
                  label: const Text('Start Detection'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),

              if (_isDetecting)
                ElevatedButton.icon(
                  onPressed: _stopDetection,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop Detection'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                ),

              const SizedBox(height: 16),

              // Recordings Section
              if (_enableRecording || _recordings.isNotEmpty) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Recordings',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_recordings.isNotEmpty)
                      TextButton.icon(
                        onPressed: _isDetecting ? null : _deleteAllRecordings,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('Delete All'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_isLoadingRecordings)
                  const Center(child: CircularProgressIndicator())
                else if (_recordings.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Text(
                        _enableRecording
                            ? 'No recordings yet. Start detection to record snoring episodes.'
                            : 'Enable recording to save snoring audio clips.',
                        style: const TextStyle(color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      itemCount: _recordings.length,
                      itemBuilder: (context, index) {
                        final recording = _recordings[index];
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.audiotrack, color: Colors.blue),
                            title: Text(
                              recording.filePath.split('/').last,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Duration: ${recording.duration.inSeconds}s'),
                                Text(
                                  'Start: ${_formatDateTime(recording.startTimestamp)}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: _isDetecting
                                  ? null
                                  : () => _deleteRecording(recording),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 16),
              ],

              // Recent Results
              if (_recentResults.isNotEmpty) ...[
                const Text(
                  'Recent Detections',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: _recentResults.length,
                    itemBuilder: (context, index) {
                      final result = _recentResults[index];
                      return ListTile(
                        leading: Icon(
                          result.isSnoring ? Icons.volume_up : Icons.volume_off,
                          color: result.isSnoring ? Colors.red : Colors.green,
                        ),
                        title: Text(
                          result.isSnoring ? 'Snoring' : 'Noise',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          '${(result.confidence * 100).toStringAsFixed(1)}% confidence',
                        ),
                        trailing: Text(
                          _formatTime(result.timestamp),
                          style: const TextStyle(fontSize: 12),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConfidenceChip(String label, double confidence, Color color) {
    return Chip(
      label: Text(
        '$label: ${(confidence * 100).toStringAsFixed(1)}%',
        style: const TextStyle(fontSize: 12),
      ),
      backgroundColor: color.withValues(alpha: 0.2),
      side: BorderSide(color: color),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }

  String _formatDateTime(DateTime time) {
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  }
}

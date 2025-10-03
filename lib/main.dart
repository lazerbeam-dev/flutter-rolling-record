import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'recording_repository.dart';
import 'recording_service.dart';
import 'api_client.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initBackgroundService();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rolling Recorder',
      theme: ThemeData(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final repo = RecordingRepository();
  final api = ApiClient(baseUrl: 'http://10.0.2.2:8000'); // change later
  final recorder = AudioRecorder(); // kept for local tests; not used for state

  bool _isRecording = false;
  List<FileSystemEntity> _segments = [];
  Timer? _segmentPoll;
  StreamSubscription<dynamic>? _stateSub;

  @override
  void initState() {
    super.initState();

    // Listen for state events from the service
    _stateSub = FlutterBackgroundService()
    .on(RecordingServiceController.stateEvent)
    .listen((event) {
  if (event == null) return; // nothing came through
  if (event is Map<String, dynamic>) {
    final rec = event['recording'] == true;
    if (mounted) {
      setState(() => _isRecording = rec);
    }
  }
});

    // Periodically ask for the current state (handles app resume / late start)
    Timer(const Duration(milliseconds: 300), _requestState); // small initial nudge
    Timer(const Duration(seconds: 1), _requestState);        // second nudge after service start
    _segmentPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _loadSegments();
      _requestState();
    });
  }

  void _requestState() {
    FlutterBackgroundService().invoke(RecordingServiceController.stateRequestEvent);
  }

  @override
  void dispose() {
    _segmentPoll?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }

  Future<void> _loadSegments() async {
    final items = await repo.listSegments();
    if (!mounted) return;
    setState(() => _segments = items);
  }

  Future<bool> _ensurePermissions() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return false;
    await Permission.notification.request(); // non-fatal if denied
    return true;
  }

  Future<void> _startRecording() async {
    if (!await _ensurePermissions()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission required.')),
      );
      return;
    }

    final service = FlutterBackgroundService();
    await service.startService();
    service.invoke(RecordingServiceController.actionStart);

    // Optimistic flip; service will confirm via event
    if (!mounted) return;
    setState(() => _isRecording = true);
    _requestState();
  }

  Future<void> _stopRecording() async {
    final service = FlutterBackgroundService();
    service.invoke(RecordingServiceController.actionStop);

    // Optimistic flip; service will confirm via event
    if (!mounted) return;
    setState(() => _isRecording = false);
    _requestState();
    await _loadSegments();
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rolling Recorder')),
      body: Column(
        children: [
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _isRecording ? null : _startRecording,
                icon: const Icon(Icons.fiber_manual_record),
                label: const Text('Start'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _isRecording ? _stopRecording : null,
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
            ],
          ),
          const Divider(height: 24),
          Expanded(
            child: _segments.isEmpty
                ? const Center(child: Text('No segments yet'))
                : ListView.separated(
                    itemCount: _segments.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final f = _segments[i] as File;
                      final stat = f.statSync();
                      final name = f.path.split('/').last;
                      final size = _fmtSize(stat.size);
                      final ts = stat.modified.toLocal();
                      return ListTile(
                        dense: true,
                        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${ts.toString().split(".").first}  •  $size'),
                        trailing: IconButton(
                          tooltip: 'Upload',
                          icon: const Icon(Icons.cloud_upload),
                          onPressed: () async {
                            try {
                              await api.uploadSegment(f);
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Uploaded ${f.path.split('/').last}')),
                              );
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Upload failed: $e')),
                              );
                            }
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// !!! DEMO ONLY: Do NOT ship API keys in the app.
/// For production, mint a short-lived token on your backend.
const String humeApiKey = 'LmHQ4hNRdmslV45cb4q0m3IaOTlXba9brsQnGF0CU2EpGknJ';
/// Create an EVI configuration in Hume console and paste its id:
const String humeConfigId = 'SLOthCGTBSYmfhpdYZAnvlRBoXZao1QmfGJzGQDZ0rC3D74QSUXiAeH3fY3xHu0F';

class HumeLiveSession {
  final _recorder = AudioRecorder();
  WebSocketChannel? _channel;
  StreamSubscription? _socketSub;
  Timer? _rotateTimer;

  final _transcriptCtrl = StreamController<String>.broadcast();
  Stream<String> get transcriptStream => _transcriptCtrl.stream;

  bool _connected = false;
  bool _recording = false;

  Future<void> connect() async {
    if (_connected) return;
    final url = 'wss://api.hume.ai/v0/evi/chat?api_key=$humeApiKey&config_id=$humeConfigId';
    _channel = WebSocketChannel.connect(Uri.parse(url));
    _connected = true;

    _socketSub = _channel!.stream.listen((evt) {
      try {
        final map = evt is String ? json.decode(evt) as Map<String, dynamic> : null;
        if (map == null) return;

        // Try a few likely shapes for user transcript text:
        final t1 = map['text'];
        final t2 = (map['user_message'] is Map) ? (map['user_message']['transcript']) : null;
        final text = (t1 is String && t1.trim().isNotEmpty)
            ? t1
            : (t2 is String && t2.trim().isNotEmpty ? t2 : null);
        if (text != null) _transcriptCtrl.add(text);
      } catch (_) {/* ignore */}
    }, onDone: () => _connected = false, onError: (_) => _connected = false);
  }

  Future<void> start() async {
    if (_recording) return;
    if (!_connected) await connect();
    _recording = true;

    await _startNewWavSegment();

    // Rotate every ~1s so each message is a complete WAV (header included).
    _rotateTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final finished = await _stopRecorder();
      if (finished != null) {
        final bytes = await File(finished).readAsBytes();
        _sendAudioWav(bytes);
        unawaited(File(finished).delete().catchError((_) {}));
      }
      await _startNewWavSegment();
    });
  }

  Future<void> stop() async {
    if (!_recording) return;
    _recording = false;
    _rotateTimer?.cancel();
    final finished = await _stopRecorder();
    if (finished != null) {
      final bytes = await File(finished).readAsBytes();
      _sendAudioWav(bytes);
      unawaited(File(finished).delete().catchError((_) {}));
    }
    _sendJson({'type': 'audio_end'});
    await disconnect();
  }

  Future<void> disconnect() async {
    _rotateTimer?.cancel();
    try { await _socketSub?.cancel(); } catch (_) {}
    try { await _channel?.sink.close(); } catch (_) {}
    _socketSub = null;
    _channel = null;
    _connected = false;
  }

  Future<void> _startNewWavSegment() async {
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, 'hume_${DateTime.now().millisecondsSinceEpoch}.wav');
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000, // safe for ASR, smaller payloads
      ),
      path: path,
    );
  }

  Future<String?> _stopRecorder() async {
    try {
      if (await _recorder.isRecording()) return await _recorder.stop();
    } catch (_) {}
    return null;
  }

  void _sendJson(Map<String, dynamic> data) {
    final ch = _channel;
    if (ch == null) return;
    try { ch.sink.add(json.encode(data)); } catch (_) {}
  }

  void _sendAudioWav(Uint8List bytes) {
    final b64 = base64Encode(bytes);
    _sendJson({
      'type': 'audio_input',
      'format': 'wav',
      'audio': b64,
    });
  }
}

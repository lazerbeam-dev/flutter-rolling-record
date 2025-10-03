import 'dart:async';
import 'dart:io';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:record/record.dart';

import 'recording_repository.dart';

const _notiChannelId = 'rollingrec_channel';
final FlutterLocalNotificationsPlugin _noti = FlutterLocalNotificationsPlugin();

class RecordingServiceController {
  static const String actionStart = 'startRecording';
  static const String actionStop = 'stopRecording';
  static const String actionPing = 'ping';
  static const String stateEvent = 'state';           // service -> UI
  static const String stateRequestEvent = 'state_request'; // UI -> service
}

/// Configure background service & notifications.
/// Call this very early (before runApp).
Future<void> initBackgroundService() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iOSInit = DarwinInitializationSettings();
  await _noti.initialize(const InitializationSettings(android: androidInit, iOS: iOSInit));

  const androidChannel = AndroidNotificationChannel(
    _notiChannelId,
    'Rolling Recorder',
    description: 'Records 30s audio segments in background',
    importance: Importance.low,
  );
  await _noti
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(androidChannel);

  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: _onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: _notiChannelId,
      initialNotificationTitle: 'Recording',
      initialNotificationContent: 'Idle',
      foregroundServiceNotificationId: 9001,
    ),
    iosConfiguration: IosConfiguration(
      onForeground: _onStart,
      onBackground: _onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  return true;
}

@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  final repo = RecordingRepository();
  final recorder = AudioRecorder();
  Timer? segmentTimer;
  bool running = false;          // segmentation loop alive
  bool isRecording = false;      // actual mic recording state

  void _broadcastState() {
    service.invoke(RecordingServiceController.stateEvent, {
      'recording': isRecording,
      'running': running,
    });
  }

  Future<void> startSegLoop() async {
    if (running) return;
    running = true;

    Future<void> startNewSegment() async {
      final path = await repo.nextFilePath();

      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: path,
      );
      isRecording = true;
      _broadcastState();

      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'Recording',
          content: 'Active segment: ${path.split('/').last}',
        );
      }
    }

    await startNewSegment();

    segmentTimer = Timer.periodic(const Duration(seconds: 30), (t) async {
      if (await recorder.isRecording()) {
        try {
          await recorder.stop(); // finalize
          await repo.enforceCap();
        } catch (_) {}
      }
      // After stopping one file, we immediately start another
      await startNewSegment();
    });
  }

  Future<void> stopSegLoop() async {
    segmentTimer?.cancel();
    if (await recorder.isRecording()) {
      try {
        await recorder.stop();
      } catch (_) {}
    }
    isRecording = false;
    running = false;
    _broadcastState();

    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Recording stopped',
        content: 'Idle',
      );
    }
  }

  // Handle UI commands
  service.on(RecordingServiceController.actionStart).listen((_) async {
    await startSegLoop();
  });

  service.on(RecordingServiceController.actionStop).listen((_) async {
    await stopSegLoop();
    if (service is AndroidServiceInstance) {
      await Future.delayed(const Duration(milliseconds: 300));
      await service.stopSelf();
    }
  });

  // Answer state requests
  service.on(RecordingServiceController.stateRequestEvent).listen((_) {
    _broadcastState();
  });

  // On boot, tell UI we’re idle
  isRecording = false;
  running = false;
  _broadcastState();
}

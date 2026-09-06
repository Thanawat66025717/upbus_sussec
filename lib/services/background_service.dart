import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_core/firebase_core.dart';
import '../firebase_options.dart';
import 'notification_service.dart';
import 'global_location_service.dart';

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  // Configure notifications for the background service (Android requirement)
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'my_foreground', // id
    'ระบบติดตามรถทำงานเบื้องหลัง', // title
    description:
        'แอปกำลังทำงานเพื่อแจ้งเตือนเมื่อรถออกนอกเส้นทาง', // description
    importance: Importance.low, // importance must be at low or higher level
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false, // We will start it manually when login/needed
      isForegroundMode: true,
      notificationChannelId: 'my_foreground',
      initialNotificationTitle: 'UP BUS กำลังทำงาน',
      initialNotificationContent: 'ระบบติดตามรถทำงานเบื้องหลัง',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase in isolate
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await NotificationService.initialize();

  // Initialize GlobalLocationService in Background Mode!
  // This will NOT request location permission, but WILL listen to Firebase RTDB and calculate off-routes
  final globalService = GlobalLocationService();
  await globalService.initialize(isBackground: true);

  Timer.periodic(const Duration(seconds: 15), (timer) async {
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: "UP BUS ระบบตามตำแหน่งหลบซ่อน",
          content: "ระบบกำลังเฝ้าระวัง...",
        );
      }
    }
  });

  debugPrint("✅ Background Service Isolate initialized and listening.");
}

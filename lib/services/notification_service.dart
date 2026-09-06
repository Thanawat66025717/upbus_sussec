import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter/material.dart'; // Needed for Color
import 'package:flutter/foundation.dart'; // Needed for kIsWeb

/// Service สำหรับจัดการ Push Notification และ Vibration
class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  /// Initialize notification service
  static Future<void> initialize() async {
    if (_initialized || kIsWeb) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(initSettings);
    _initialized = true;
  }

  /// คำนวณเวลาถึงโดยประมาณ (ETA) จากระยะทางและความเร็ว
  /// ความเร็วเฉลี่ย 35 km/h = 9.72 m/s
  static int calculateEtaSeconds(
    double distanceMeters, {
    double speedKmh = 35,
  }) {
    final speedMs = speedKmh * 1000 / 3600; // แปลงเป็น m/s
    return (distanceMeters / speedMs).round();
  }

  /// แปลงเวลาเป็นข้อความที่อ่านง่าย (รูปแบบนับถอยหลัง)
  static String formatEta(int etaSeconds) {
    if (etaSeconds <= 0) return 'ถึงแล้ว';
    if (etaSeconds < 60) {
      return '$etaSeconds วินาที';
    } else {
      final minutes = etaSeconds ~/ 60;
      final seconds = etaSeconds % 60;
      if (seconds == 0) return '$minutes นาที';
      return '$minutes นาที $seconds วินาที';
    }
  }

  /// แสดง Push Notification เมื่อรถบัสใกล้
  static Future<void> showBusNearbyNotification({
    required String busName,
    required double distanceMeters,
    int? etaSeconds,
    String? title,
  }) async {
    if (kIsWeb) return;
    if (!_initialized) await initialize();

    const androidDetails = AndroidNotificationDetails(
      'bus_proximity_channel',
      'Bus Proximity Alerts',
      channelDescription: 'แจ้งเตือนเมื่อรถบัสเข้าใกล้',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // สร้างข้อความ body พร้อม ETA
    String body = '$busName อยู่ห่าง ${distanceMeters.toStringAsFixed(0)} เมตร';
    if (etaSeconds != null) {
      body += ' (${formatEta(etaSeconds)})';
    }

    await _notifications.show(
      1,
      title ?? '🚌 รถบัสใกล้ถึงแล้ว!',
      body,
      details,
    );
  }

  /// แสดง Notification ทั่วไป (Generic)
  static Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (kIsWeb) return;
    if (!_initialized) await initialize();

    const androidDetails = AndroidNotificationDetails(
      'bus_alert_channel',
      'Bus Status Alerts',
      channelDescription: 'แจ้งเตือนสถานะรถบัส (เช่น ออกนอกเส้นทาง)',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      color: Color(0xFFFF3859),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notifications.show(id, title, body, details, payload: payload);
  }

  /// สั่นเตือน
  static Future<void> vibrate() async {
    if (kIsWeb) return;
    final hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator == true) {
      await Vibration.vibrate(duration: 1000, amplitude: 128);
    }
  }

  /// สั่นเตือนกรณีฉุกเฉิน (สั่นเป็นจังหวะรัวๆ)
  static Future<void> vibrateUrgent() async {
    if (kIsWeb) return;
    final hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator == true) {
      // สั่น 500ms, เงียบ 200ms, สั่น 500ms, เงียบ 200ms, สั่น 500ms (รวม 3 ครั้ง)
      await Vibration.vibrate(
        pattern: [0, 500, 200, 500, 200, 500],
        intensities: [0, 255, 0, 255, 0, 255],
      );
    }
  }

  /// แจ้งเตือนพร้อมสั่น
  static Future<void> alertBusNearby({
    required String busName,
    required double distanceMeters,
    int? etaSeconds,
    String? title,
  }) async {
    await Future.wait([
      showBusNearbyNotification(
        busName: busName,
        distanceMeters: distanceMeters,
        etaSeconds: etaSeconds,
        title: title,
      ),
      vibrate(),
    ]);
  }
}

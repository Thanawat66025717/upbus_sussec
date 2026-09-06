import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:projectapp/models/bus_route_data.dart';
import 'package:projectapp/services/route_manager_service.dart';

class DataMigrationPage extends StatefulWidget {
  const DataMigrationPage({super.key});

  @override
  State<DataMigrationPage> createState() => _DataMigrationPageState();
}

class _DataMigrationPageState extends State<DataMigrationPage> {
  bool _isUploading = false;
  String _statusMessage = 'พร้อมอัปโหลดข้อมูลเริ่มต้น...';

  Future<void> _startMigration() async {
    setState(() {
      _isUploading = true;
      _statusMessage = 'กำลังเริ่มอัปโหลด...';
    });

    try {
      final firestore = FirebaseFirestore.instance;

      // 1. อัปโหลด Bus Stops (ป้ายทั้งหมด)
      setState(() => _statusMessage = 'กำลังอัปโหลดป้ายรถ (Bus Stops)...');
      for (var stop in BusStops.all) {
        await firestore.collection('bus_stops').doc(stop.id).set({
          'id': stop.id,
          'name': stop.name,
          'shortName': stop.shortName ?? '',
          'location': stop.location,
        }, SetOptions(merge: true));
      }

      // 2. อัปโหลดข้อมูลสายรถหลัก (Routes Metadata)
      setState(() => _statusMessage = 'กำลังอัปโหลดข้อมูลสายรถ (Routes)...');
      for (var route in BusRoutes.all) {
        await firestore.collection('bus_routes').doc(route.routeId).set({
          'routeId': route.routeId,
          'name': route.name,
          'shortName': route.shortName,
          'colorValue': route.colorValue,
          'startHour': route.startHour,
          'endHour': route.endHour,
          // รายชื่อไอดีป้ายรถเมล์ที่ผ่าน
          'stops': route.stops.map((s) => s.id).toList(),
        }, SetOptions(merge: true));
      }

      // 3. อัปโหลดไฟล์ GeoJSON ไปที่ bus_routes/{id}/path
      setState(
        () => _statusMessage = 'กำลังอัปโหลดจุดพิกัดเส้นทาง (GeoJSON)...',
      );

      final Map<String, String> geoJsonFiles = {
        'S1-AM': 'assets/data/bus_route1_am.geojson',
        'S1-PM': 'assets/data/bus_route1_pm.geojson',
        'S2': 'assets/data/bus_route2.geojson',
        'S3': 'assets/data/bus_route3.geojson',
      };

      for (var entry in geoJsonFiles.entries) {
        String routeId = entry.key;
        String assetPath = entry.value;

        String geoJsonString = await rootBundle.loadString(assetPath);
        Map<String, dynamic> geoJsonMap = jsonDecode(geoJsonString);

        // ดึง Coordinates ออกมาแปลงเป็น GeoPoint List
        List<GeoPoint> pathPoints = [];
        try {
          var features = geoJsonMap['features'] as List;
          if (features.isNotEmpty) {
            var feature = features.first;
            var geometry = feature['geometry'];
            var coordinates = geometry['coordinates'] as List;

            // ปกติ GeoJSON ของเส้นทางจะเป็น MultiLineString หรือ LineString
            if (geometry['type'] == 'MultiLineString') {
              for (var line in coordinates) {
                for (var point in line) {
                  double lng = (point[0] as num).toDouble();
                  double lat = (point[1] as num).toDouble();
                  pathPoints.add(GeoPoint(lat, lng));
                }
              }
            } else if (geometry['type'] == 'LineString') {
              for (var point in coordinates) {
                double lng = (point[0] as num).toDouble();
                double lat = (point[1] as num).toDouble();
                pathPoints.add(GeoPoint(lat, lng));
              }
            }
          }
        } catch (e) {
          print('Error parsing GeoJSON for $routeId: $e');
        }

        // เซฟพิกัดลงใน Sub-collection 'path' -> document 'main' (หรือจะเก็บเป็น array ในตัวมันเองก็ได้)
        // กรณีเส้นทางยาวมาก เก็บแยก sub collection ปลอดภัยเรื่องขนาด limit document (1MB)
        await firestore
            .collection('bus_routes')
            .doc(routeId)
            .collection('path')
            .doc('main_path')
            .set({'points': pathPoints}, SetOptions(merge: true));
      }

      setState(() => _statusMessage = '✅ อัปโหลดสำเร็จสมบูรณ์!');
    } catch (e) {
      setState(() => _statusMessage = '❌ เกิดข้อผิดพลาด: $e');
    } finally {
      setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ติดตั้งฐานข้อมูล (Admin)')),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'หน้าเพจนี้ใช้สำหรับอัปโหลดข้อมูลจากแอปขึ้น Firebase (ทำแค่ครั้งแรก)',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30),
              if (_isUploading) const CircularProgressIndicator(),
              const SizedBox(height: 20),
              Text(
                _statusMessage,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: _isUploading ? null : _startMigration,
                icon: const Icon(Icons.cloud_upload),
                label: const Text('เริ่มการอัปโหลดข้อมูล (Migration)'),
              ),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _isUploading
                    ? null
                    : () => _runDelete(
                        confirmTitle: 'ลบป้ายรถเมล์ทั้งหมด?',
                        busyMessage: 'กำลังลบป้ายรถเมล์...',
                        doneMessage: '✅ ลบป้ายรถเมล์ทั้งหมดแล้ว',
                        action: () => RouteManagerService().deleteAllStops(),
                      ),
                icon: const Icon(Icons.delete_forever, color: Colors.red),
                label: const Text(
                  'ลบป้ายรถเมล์ทั้งหมด',
                  style: TextStyle(color: Colors.red),
                ),
                style: ElevatedButton.styleFrom(
                  side: const BorderSide(color: Colors.red),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: _isUploading
                    ? null
                    : () => _runDelete(
                        confirmTitle: 'ลบสายรถทั้งหมด?',
                        busyMessage: 'กำลังลบสายรถ...',
                        doneMessage: '✅ ลบสายรถทั้งหมดแล้ว',
                        action: () => RouteManagerService().deleteAllRoutes(),
                      ),
                icon: const Icon(Icons.delete_sweep, color: Colors.red),
                label: const Text(
                  'ลบสายรถทั้งหมด',
                  style: TextStyle(color: Colors.red),
                ),
                style: ElevatedButton.styleFrom(
                  side: const BorderSide(color: Colors.red),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: _isUploading
                    ? null
                    : () => _runDelete(
                        confirmTitle: 'ลบประวัติการเดินรถทั้งหมด?',
                        busyMessage: 'กำลังลบประวัติการเดินรถ...',
                        doneMessage: '✅ ลบประวัติการเดินรถทั้งหมดแล้ว',
                        action: () =>
                            RouteManagerService().deleteAllOperationLogs(),
                      ),
                icon: const Icon(Icons.history, color: Colors.orange),
                label: const Text(
                  'ลบประวัติการเดินรถทั้งหมด',
                  style: TextStyle(color: Colors.orange),
                ),
                style: ElevatedButton.styleFrom(
                  side: const BorderSide(color: Colors.orange),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: _isUploading
                    ? null
                    : () => _runDelete(
                        confirmTitle: 'ลบ Feedback ทั้งหมด?',
                        busyMessage: 'กำลังลบ Feedback...',
                        doneMessage: '✅ ลบ Feedback ทั้งหมดแล้ว',
                        action: () => RouteManagerService().deleteAllFeedbacks(),
                      ),
                icon: const Icon(Icons.comment_bank, color: Colors.blueGrey),
                label: const Text(
                  'ลบ Feedback ทั้งหมด',
                  style: TextStyle(color: Colors.blueGrey),
                ),
                style: ElevatedButton.styleFrom(
                  side: const BorderSide(color: Colors.blueGrey),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _showConfirmDialog(String title) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: const Text(
              'การดำเนินการนี้ไม่สามารถย้อนกลับได้ คุณแน่ใจหรือไม่?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('ยกเลิก'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  'ยืนยัน',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  /// ยืนยัน + ลบข้อมูล พร้อม try/catch/finally ครบ เพื่อไม่ให้ _isUploading
  /// ค้างเป็น true ตลอดไปถ้าเกิด error ระหว่างลบ (เช่น ตัดเน็ต/permission)
  Future<void> _runDelete({
    required String confirmTitle,
    required String busyMessage,
    required String doneMessage,
    required Future<void> Function() action,
  }) async {
    final confirmed = await _showConfirmDialog(confirmTitle);
    if (!confirmed) return;

    setState(() {
      _isUploading = true;
      _statusMessage = busyMessage;
    });
    try {
      await action();
      if (mounted) setState(() => _statusMessage = doneMessage);
    } catch (e) {
      if (mounted) setState(() => _statusMessage = '❌ เกิดข้อผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }
}

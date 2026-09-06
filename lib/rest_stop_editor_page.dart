import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'models/bus_route_data.dart';
import 'services/route_manager_service.dart';
import 'services/map_config.dart';

class RestStopEditorPage extends StatefulWidget {
  const RestStopEditorPage({super.key});

  @override
  State<RestStopEditorPage> createState() => _RestStopEditorPageState();
}

class _RestStopEditorPageState extends State<RestStopEditorPage> {
  final _routeManager = RouteManagerService();
  final MapController _mapController = MapController();

  void _onMapTap(TapPosition tapPosition, LatLng point) {
    // เช็คว่าแตะที่ zone เดิมหรือไม่
    final existingZone = _findZoneAt(point);
    if (existingZone != null) {
      _showEditZoneDialog(existingZone);
    } else {
      _showAddZoneDialog(point);
    }
  }

  RestStopData? _findZoneAt(LatLng point) {
    const distance = Distance();
    for (final zone in _routeManager.allRestStops) {
      final center = LatLng(zone.location.latitude, zone.location.longitude);
      final dist = distance.as(LengthUnit.Meter, point, center);
      if (dist <= zone.radius) {
        return zone;
      }
    }
    return null;
  }

  void _showAddZoneDialog(LatLng point) {
    final nameController = TextEditingController();
    double radius = 150.0;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('เพิ่มจุดพักรถใหม่'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'ชื่อจุดพัก',
                    hintText: 'เช่น หอพัก, จุดกลับรถ',
                    prefixIcon: Icon(Icons.label_outline),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    const Icon(
                      Icons.circle_outlined,
                      size: 18,
                      color: Colors.green,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'รัศมี: ${radius.toInt()} ม.',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Slider(
                  value: radius,
                  min: 50,
                  max: 500,
                  divisions: 18,
                  activeColor: Colors.green,
                  label: '${radius.toInt()} ม.',
                  onChanged: (v) => setDialogState(() => radius = v),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.location_on,
                        size: 16,
                        color: Colors.grey,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ยกเลิก'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.add_location, size: 18),
              label: const Text('เพิ่มจุดพัก'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final name = nameController.text.trim().isEmpty
                    ? 'จุดพัก ${_routeManager.allRestStops.length + 1}'
                    : nameController.text.trim();

                final id = 'rest_${DateTime.now().millisecondsSinceEpoch}';

                final newZone = RestStopData(
                  id: id,
                  name: name,
                  location: GeoPoint(point.latitude, point.longitude),
                  radius: radius,
                );

                await _routeManager.addRestStop(newZone);
                if (mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('เพิ่มจุดพัก "$name" แล้ว'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
                setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEditZoneDialog(RestStopData zone) {
    final nameController = TextEditingController(text: zone.name);
    double radius = zone.radius;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('แก้ไข: ${zone.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'ชื่อจุดพัก',
                    prefixIcon: Icon(Icons.label_outline),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    const Icon(
                      Icons.circle_outlined,
                      size: 18,
                      color: Colors.green,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'รัศมี: ${radius.toInt()} ม.',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Slider(
                  value: radius,
                  min: 50,
                  max: 500,
                  divisions: 18,
                  activeColor: Colors.green,
                  label: '${radius.toInt()} ม.',
                  onChanged: (v) => setDialogState(() => radius = v),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.location_on,
                        size: 16,
                        color: Colors.grey,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${zone.location.latitude.toStringAsFixed(6)}, ${zone.location.longitude.toStringAsFixed(6)}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            // ปุ่มลบ
            TextButton.icon(
              icon: const Icon(Icons.delete, size: 18),
              label: const Text('ลบ'),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () {
                Navigator.pop(ctx);
                _confirmDeleteZone(zone);
              },
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ยกเลิก'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.save, size: 18),
              label: const Text('บันทึก'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final updated = RestStopData(
                  id: zone.id,
                  name: nameController.text.trim().isEmpty
                      ? zone.name
                      : nameController.text.trim(),
                  location: zone.location,
                  radius: radius,
                );
                await _routeManager.updateRestStop(updated);
                if (mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('บันทึก "${updated.name}" แล้ว'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
                setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteZone(RestStopData zone) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ยืนยันการลบ'),
        content: Text('คุณต้องการลบจุดพัก "${zone.name}" ใช่หรือไม่?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ยกเลิก'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              await _routeManager.deleteRestStop(zone.id);
              if (mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('ลบจุดพัก "${zone.name}" แล้ว'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
              setState(() {});
            },
            child: const Text('ลบ'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _routeManager,
      builder: (context, _) {
        final zones = _routeManager.allRestStops;
        final routes = _routeManager.allRoutes;

        // สร้าง polylines จากเส้นทาง
        final polylines = <Polyline>[];
        for (final route in routes) {
          if (route.pathPoints != null && route.pathPoints!.isNotEmpty) {
            polylines.add(
              Polyline(
                points: route.pathPoints!
                    .map((p) => LatLng(p.latitude, p.longitude))
                    .toList(),
                color: Color(route.colorValue).withOpacity(0.5),
                strokeWidth: 3.0,
              ),
            );
          }
        }

        return Scaffold(
          body: Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: const LatLng(19.028, 99.895),
                  initialZoom: 14,
                  onTap: _onMapTap,
                ),
                children: [
                  TileLayer(
                    urlTemplate: MapConfig.tileUrlTemplate,
                    userAgentPackageName: MapConfig.userAgentPackageName,
                  ),
                  // เส้นทาง route (เพื่อให้เห็นว่าจุดพักอยู่ตรงไหนของเส้นทาง)
                  PolylineLayer(polylines: polylines),
                  // วงกลม rest stop zones
                  CircleLayer(
                    circles: zones.map((zone) {
                      final center = LatLng(
                        zone.location.latitude,
                        zone.location.longitude,
                      );
                      return CircleMarker(
                        point: center,
                        color: Colors.green.withOpacity(0.2),
                        borderColor: Colors.green.withOpacity(0.6),
                        borderStrokeWidth: 2,
                        radius: zone.radius,
                        useRadiusInMeter: true,
                      );
                    }).toList(),
                  ),
                  // Markers ที่กลางของแต่ละ zone (สำหรับแตะ)
                  MarkerLayer(
                    markers: zones.map((zone) {
                      final center = LatLng(
                        zone.location.latitude,
                        zone.location.longitude,
                      );
                      return Marker(
                        point: center,
                        width: 140,
                        height: 60,
                        child: GestureDetector(
                          onTap: () => _showEditZoneDialog(zone),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.green.shade700,
                                  borderRadius: BorderRadius.circular(8),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.2),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.local_parking,
                                      color: Colors.white,
                                      size: 14,
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        zone.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(
                                Icons.arrow_drop_down,
                                color: Colors.green,
                                size: 16,
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
              // Info banner
              Positioned(
                top: 20,
                left: 20,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 15,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.local_parking,
                          color: Colors.green,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 15),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'จัดการจุดพักรถ',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            Text(
                              'แตะบนแผนที่เพื่อเพิ่ม หรือแตะที่วงกลม/ป้ายเพื่อแก้ไข (${zones.length} จุดพัก)',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

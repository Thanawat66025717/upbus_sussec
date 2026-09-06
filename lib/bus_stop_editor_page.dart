import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'models/bus_route_data.dart';
import 'services/route_manager_service.dart';
import 'services/map_config.dart';

class BusStopEditorPage extends StatefulWidget {
  const BusStopEditorPage({super.key});

  @override
  State<BusStopEditorPage> createState() => _BusStopEditorPageState();
}

class _BusStopEditorPageState extends State<BusStopEditorPage> {
  final _routeManager = RouteManagerService();
  final MapController _mapController = MapController();

  void _onMapTap(TapPosition tapPosition, LatLng point) {
    setState(() {
      // _selectedStop = null; // Removed as _selectedStop is no longer a field
      // _previewLocation = point; // Removed as _previewLocation is no longer a field
    });
    _showAddStopDialog(point);
  }

  void _showAddStopDialog(LatLng point) {
    final nameController = TextEditingController();
    final shortNameController = TextEditingController();
    final idController = TextEditingController();
    final routeIdController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('เพิ่มป้ายจอดใหม่'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: idController,
                decoration: const InputDecoration(
                  labelText: 'Stop ID (เช่น namor)',
                  hintText: 'หากไม่ระบุจะสร้างอัตโนมัติ',
                ),
              ),
              TextField(
                controller: routeIdController,
                decoration: const InputDecoration(
                  labelText: 'Route ID (เช่น S1)',
                  hintText: 'ระบุรหัสสายรถเมล์',
                ),
              ),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'ชื่อเต็ม'),
              ),
              TextField(
                controller: shortNameController,
                decoration: const InputDecoration(labelText: 'ชื่อย่อ (ถ้ามี)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ยกเลิก'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (nameController.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('กรุณากรอกชื่อป้าย')),
                );
                return;
              }

              final stopId = idController.text.isEmpty
                  ? 'stop_${DateTime.now().millisecondsSinceEpoch}'
                  : idController.text;

              final newStop = BusStopData(
                id: stopId,
                name: nameController.text,
                shortName: shortNameController.text,
                location: GeoPoint(point.latitude, point.longitude),
                routes: routeIdController.text.isEmpty
                    ? null
                    : routeIdController.text,
              );

              await _routeManager.addStop(newStop);
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('บันทึก'),
          ),
        ],
      ),
    );
  }

  void _showEditStopDialog(BusStopData stop) {
    final nameController = TextEditingController(text: stop.name);
    final shortNameController = TextEditingController(text: stop.shortName);
    final idController = TextEditingController(text: stop.id);
    final routeIdController = TextEditingController(
      text: stop.routes?.toString() ?? '',
    );

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('แก้ไขป้ายจอด'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: idController,
                decoration: const InputDecoration(labelText: 'Stop ID'),
                // ถ้าเปลี่ยน ID จะเป็นการสร้างใหม่และลบของเดิม
              ),
              TextField(
                controller: routeIdController,
                decoration: const InputDecoration(labelText: 'Route ID'),
              ),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'ชื่อเต็ม'),
              ),
              TextField(
                controller: shortNameController,
                decoration: const InputDecoration(labelText: 'ชื่อย่อ (ถ้ามี)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: ctx,
                builder: (confirmCtx) => AlertDialog(
                  title: const Text('ยืนยันการลบ'),
                  content: Text('คุณต้องการลบป้าย "${stop.name}" ใช่หรือไม่?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(confirmCtx, false),
                      child: const Text('ยกเลิก'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(confirmCtx, true),
                      child: const Text(
                        'ลบ',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
              await _routeManager.deleteStop(stop.id);
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('ลบ', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ยกเลิก'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newId = idController.text;
              final updatedStop = BusStopData(
                id: newId,
                name: nameController.text,
                shortName: shortNameController.text,
                location: stop.location,
                routes: routeIdController.text.isEmpty
                    ? null
                    : routeIdController.text,
              );

              if (newId != stop.id) {
                // กรณีเปลี่ยน ID: ลบของเก่า สร้างของใหม่
                await _routeManager.deleteStop(stop.id);
                await _routeManager.addStop(updatedStop);
              } else {
                await _routeManager.updateStop(updatedStop);
              }

              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('บันทึก'),
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
        return Scaffold(
          body: Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: const LatLng(19.028, 99.895),
                  initialZoom: 15,
                  onTap: _onMapTap,
                ),
                children: [
                  TileLayer(
                    urlTemplate: MapConfig.tileUrlTemplate,
                    userAgentPackageName: MapConfig.userAgentPackageName,
                  ),
                  // --- วาดเส้นทางของแต่ละสาย ---
                  PolylineLayer(
                    polylines: _routeManager.allRoutes
                        .where(
                          (r) =>
                              r.pathPoints != null && r.pathPoints!.isNotEmpty,
                        )
                        .map(
                          (route) => Polyline(
                            points: route.pathPoints!
                                .map((p) => LatLng(p.latitude, p.longitude))
                                .toList(),
                            color: Color(route.colorValue).withOpacity(0.35),
                            strokeWidth: 3.0,
                          ),
                        )
                        .toList(),
                  ),
                  MarkerLayer(
                    markers: _routeManager.allStops.map((stop) {
                      final pos = stop.location != null
                          ? LatLng(
                              stop.location!.latitude,
                              stop.location!.longitude,
                            )
                          : const LatLng(0, 0);

                      return Marker(
                        point: pos,
                        width: 200,
                        height: 100,
                        child: GestureDetector(
                          onTap: () => _showEditStopDialog(stop),
                          child: Stack(
                            alignment: Alignment.bottomCenter,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Image.asset(
                                  'assets/images/bus-stopicon.png',
                                  width: 60,
                                  height: 60,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
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
                    color: Colors.white.withOpacity(0.9),
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
                          color: Colors.purple.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.info_outline,
                          color: Colors.purple,
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
                              'จัดการป้ายจอดรถ',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            Text(
                              'แตะบนแผนที่เพื่อเพิ่มป้าย หรือแตะที่หมุดเพื่อแก้ไข (${_routeManager.allStops.length} ป้าย)',
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

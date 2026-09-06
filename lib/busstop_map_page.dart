import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:projectapp/services/route_service.dart';
import 'package:projectapp/services/global_location_service.dart';
import 'package:projectapp/models/bus_route_data.dart';
import 'package:projectapp/services/map_config.dart';

class BusStopMapPage extends StatefulWidget {
  const BusStopMapPage({super.key});

  @override
  State<BusStopMapPage> createState() => _BusStopMapPageState();
}

class _BusStopMapPageState extends State<BusStopMapPage> {
  late final MapController _mapController;
  late LatLng _stopLocation;
  String _stopName = '';
  List<Map<String, dynamic>> _allBusStops = [];
  String? _selectedStopId;
  List<LatLng> _walkingPath = [];
  bool _isNavigating = false;
  String? _busRouteId;

  // --- Navigation tracking ---
  LatLng? _userPosition;
  double? _userHeading; // องศา (0 = เหนือ)
  StreamSubscription<Position>? _locationSub;
  bool _isRecalculating = false;
  bool _isNavigationActive = false; // true เมื่อกดนำทางและเส้นโหลดสำเร็จ

  // ระยะห่างจากเส้นทางที่ถือว่า "ออกนอกเส้นทาง" (เมตร)
  static const double _offRouteThreshold = 15.0;

  // --- [DEBUG] จำลองการเดิน ---
  final bool _debugMode = false;
  int _debugWaypointIndex = 1; // index ถัดไปที่จะกระโดดไป

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _stopLocation = const LatLng(19.03011372185138, 99.89781512200192);
    _userPosition = GlobalLocationService().userPosition;
    _fetchBusStops();
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    super.dispose();
  }

  // ─── [DEBUG] จำลองการเดิน ─────────────────────────────────────────────────

  /// กด 1 ครั้ง = เลื่อน user ไป waypoint ถัดไปบนเส้นทาง
  void _debugSimulateWalk() {
    if (_walkingPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠ กด "นำทางไปป้ายนี้" ก่อนนะครับ')),
      );
      return;
    }
    if (_debugWaypointIndex >= _walkingPath.length) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ถึงปลายทางแล้ว!')));
      return;
    }
    final nextPoint = _walkingPath[_debugWaypointIndex];
    setState(() {
      _userPosition = nextPoint;
      _debugWaypointIndex++;
    });
    _mapController.move(nextPoint, 18);
    // เรียก trim เหมือนได้รับ GPS จริง
    if (_isNavigationActive) _trimPath(nextPoint);
  }

  /// กด 1 ครั้ง = เลื่อน user ออกข้างๆ ~25 ม. (trigger recalculate)
  void _debugSimulateOffRoute() {
    if (_walkingPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠ กด "นำทางไปป้ายนี้" ก่อนนะครับ')),
      );
      return;
    }
    final current = _userPosition ?? _walkingPath.first;
    // เลื่อนออกไปทางตะวันออก ~25 เมตร (0.00025 องศา ≈ 27 ม.)
    final offPoint = LatLng(current.latitude, current.longitude + 0.00025);
    setState(() {
      _userPosition = offPoint;
    });
    _mapController.move(offPoint, 18);
    if (_isNavigationActive) _trimPath(offPoint);
  }

  Future<void> _fetchBusStops() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('bus_stops')
          .get();
      final stops = snapshot.docs.map((doc) {
        final stop = BusStopData.fromFirestore(doc);
        return {
          'id': stop.id,
          'name': stop.name,
          'lat': stop.location?.latitude ?? 0.0,
          'long': stop.location?.longitude ?? 0.0,
          'route_id': (doc.data())['route_id'],
        };
      }).toList();

      if (mounted) {
        setState(() {
          _allBusStops = stops;
        });
      }
    } catch (e) {
      debugPrint("Error fetching bus stops: $e");
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      final lat = double.tryParse(args['lat']?.toString() ?? '');
      final long = double.tryParse(args['long']?.toString() ?? '');
      final name = args['name']?.toString();
      final id = args['id']?.toString();
      final routeId = args['routeId']?.toString();

      if (lat != null && long != null) {
        _stopLocation = LatLng(lat, long);
      }
      if (name != null) _stopName = name;
      if (id != null) _selectedStopId = id;
      if (routeId != null) _busRouteId = routeId;
    }
  }

  // [HELPER] สร้าง Chip สีแสดงสายรถ
  Widget _buildRouteChips(dynamic routesData) {
    if (routesData == null) return const SizedBox.shrink();

    List<String> routes = [];
    if (routesData is List) {
      routes = routesData.map((e) => e.toString()).toList();
    } else if (routesData is String) {
      routes = routesData.split(',').map((e) => e.trim()).toList();
    }

    if (routes.isEmpty) return const SizedBox.shrink();
    routes.sort();

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.center,
      spacing: 4,
      children: routes.map((route) {
        Color color = Colors.grey;
        final upperRoute = route.toUpperCase().trim();
        if (upperRoute.contains('S1')) {
          color = const Color.fromRGBO(68, 182, 120, 1);
        } else if (upperRoute.contains('S2')) {
          color = const Color.fromRGBO(255, 56, 89, 1);
        } else if (upperRoute.contains('S3')) {
          color = const Color.fromRGBO(17, 119, 252, 1);
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            route,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 8,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      }).toList(),
    );
  }

  // ─── Navigation ────────────────────────────────────────────────────────────

  Future<void> _startNavigation() async {
    LatLng? userPos = GlobalLocationService().userPosition;

    if (userPos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ไม่พบ GPS: ใช้ตำแหน่งจำลอง (หน้ามอ) แทน'),
          duration: Duration(seconds: 2),
        ),
      );
      userPos = const LatLng(19.028000, 99.895000);
    }

    setState(() => _isNavigating = true);

    List<LatLng> path = [];
    try {
      path = await RouteService.getWalkingRoute(userPos, _stopLocation);
    } catch (_) {
      // ปล่อยให้ path ว่าง แล้วจัดการเหมือนกรณี "ไม่พบเส้นทาง" ด้านล่าง
      // สำคัญ: ต้องไม่ throw ทิ้งไว้เฉยๆ ไม่งั้นปุ่มนำทางจะค้างเป็น loading ตลอดไป
    }

    if (mounted) {
      setState(() {
        _walkingPath = path;
        _isNavigating = false;
        _isNavigationActive = path.isNotEmpty;
      });

      if (path.isNotEmpty) {
        final bounds = LatLngBounds.fromPoints([
          userPos,
          _stopLocation,
          ...path,
        ]);
        _mapController.fitCamera(
          CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(50)),
        );
        _startLocationTracking(); // เริ่ม track หลังโหลดเส้นสำเร็จ
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ไม่พบเส้นทางเดินเท้า กรุณาลองใหม่อีกครั้ง'),
          ),
        );
      }
    }
  }

  /// เริ่ม subscribe GPS stream เพื่อ heading + trim path + detect off-route
  void _startLocationTracking() {
    _locationSub?.cancel();
    _locationSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 3, // update ทุก 3 เมตร
          ),
        ).listen((Position pos) {
          final newPos = LatLng(pos.latitude, pos.longitude);
          final heading = pos.heading >= 0 ? pos.heading : null;

          setState(() {
            _userPosition = newPos;
            _userHeading = heading;
          });

          if (_isNavigationActive && _walkingPath.isNotEmpty) {
            _trimPath(newPos);
          }
        }, onError: (e) => debugPrint('Location stream error: $e'));
  }

  /// ตัดเส้นทางที่ผ่านแล้วออก (เส้นเริ่มจากตำแหน่งปัจจุบันเสมอ)
  void _trimPath(LatLng userPos) {
    if (_walkingPath.length < 2) return;

    final proj = RouteService.findClosestProjection(userPos, _walkingPath);
    if (proj == null) return;

    final distToPath = proj.distToPolyline;

    // ออกนอกเส้นทาง → recalculate
    if (distToPath > _offRouteThreshold && !_isRecalculating) {
      _recalculate(userPos);
      return;
    }

    // ตัด points ที่ผ่านแล้วออก (เก็บตั้งแต่ segment ที่ proj อยู่เป็นต้นไป)
    final newPath = <LatLng>[
      userPos, // จุดเริ่มต้นใหม่คือตำแหน่งผู้ใช้
      ..._walkingPath.sublist(proj.segmentIndex + 1),
    ];

    // ถ้าเหลือแต่จุด destination (ถึงแล้ว)
    if (newPath.length <= 1) {
      setState(() {
        _walkingPath = [];
        _isNavigationActive = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🎉 ถึงป้ายรถเมล์แล้ว!'),
          backgroundColor: Colors.green,
        ),
      );
      _locationSub?.cancel();
      return;
    }

    setState(() {
      _walkingPath = newPath;
    });
  }

  /// คำนวณเส้นทางใหม่จากตำแหน่งปัจจุบัน
  Future<void> _recalculate(LatLng userPos) async {
    setState(() => _isRecalculating = true);
    List<LatLng> newPath = [];
    try {
      newPath = await RouteService.getWalkingRoute(userPos, _stopLocation);
    } catch (_) {
      // ปล่อยให้ newPath ว่าง — สำคัญ: ต้องไม่ throw ทิ้งไว้ ไม่งั้นแบนเนอร์
      // "กำลังหาเส้นทางใหม่..." จะค้างแสดงตลอดไปโดยไม่มีทางลองใหม่
    }
    if (mounted) {
      setState(() {
        _walkingPath = newPath;
        _isRecalculating = false;
        _isNavigationActive = newPath.isNotEmpty;
      });
      if (newPath.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('คำนวณเส้นทางใหม่ไม่สำเร็จ กรุณาลองใหม่อีกครั้ง'),
          ),
        );
      }
    }
  }

  void _onBackPressed() {
    _locationSub?.cancel();
    Navigator.pushReplacementNamed(
      context,
      '/busStop',
      arguments: {'name': _stopName, 'routeId': _busRouteId},
    );
  }

  // ─── Navigation Banner ──────────────────────────────────────────────

  /// คำนวณทิศทาง (bearing) จาก [from] ไป [to] ในหน่วยองศา (0–360)
  double _bearingTo(LatLng from, LatLng to) {
    final lat1 = from.latitude * pi / 180;
    final lat2 = to.latitude * pi / 180;
    final dLng = (to.longitude - from.longitude) * pi / 180;
    final y = sin(dLng) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  /// Banner นำทาง: ลูกศรชี้เส้นทาง + ระยะทาง
  Widget _buildNavBanner() {
    if (_walkingPath.isEmpty || _userPosition == null) return const SizedBox();

    // waypoint ถัดไปคือ index 1 (เพราะ index 0 = ตำแหน่งผู้ใช้เอง)
    final nextWaypoint = _walkingPath.length > 1
        ? _walkingPath[1]
        : _walkingPath.first;

    // bearing จากผู้ใช้ → waypoint ถัดไป
    final targetBearing = _bearingTo(_userPosition!, nextWaypoint);

    // ถ้ารู้หัว heading → ใช้ relative bearing (ลูกศรจะชี้ตรงเมื่อเดินถูก)
    final arrowAngle = _userHeading != null
        ? ((targetBearing - _userHeading! + 360) % 360) * pi / 180
        : targetBearing * pi / 180;

    // ระยะทางเหลือถึงปลายทาง (Haversine)
    const dist = Distance();
    final remaining = dist.as(
      LengthUnit.Meter,
      _userPosition!,
      _walkingPath.last,
    );
    final distText = remaining >= 1000
        ? '${(remaining / 1000).toStringAsFixed(1)} กม.'
        : '${remaining.toStringAsFixed(0)} ม.';

    // ข้อความนำทาง
    final relativeDeg = _userHeading != null
        ? (targetBearing - _userHeading! + 360) % 360
        : targetBearing;
    String instruction;
    if (relativeDeg < 30 || relativeDeg > 330) {
      instruction = 'เดินตรงไป';
    } else if (relativeDeg <= 150) {
      instruction = 'เลี้ยวขวา';
    } else if (relativeDeg <= 210) {
      instruction = 'กลับหลัง';
    } else {
      instruction = 'เลี้ยวซ้าย';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        color: Colors.blue.shade800,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 8, offset: Offset(0, 3)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // ► ลูกศรหมุนตามทิศ
            Transform.rotate(
              angle: arrowAngle,
              child: const Icon(
                Icons.navigation,
                color: Colors.white,
                size: 48,
              ),
            ),
            const SizedBox(width: 16),
            // ► ข้อความ
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    instruction,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'เหลือ $distText ถึงป้าย',
                    style: TextStyle(color: Colors.blue.shade100, fontSize: 14),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Heading Arrow Widget ──────────────────────────────────────────────────

  /// Widget ลูกศรบอกทิศที่ผู้ใช้กำลังเดิน
  Widget _buildUserArrow(double? heading) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // วงกลมพื้นหลัง
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Colors.blueAccent,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ),
        // ลูกศร (ถ้ามี heading)
        if (heading != null)
          Transform.rotate(
            angle: heading * pi / 180,
            child: const Icon(Icons.navigation, color: Colors.white, size: 22),
          )
        else
          const Icon(Icons.my_location, color: Colors.white, size: 20),
      ],
    );
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final displayUserPos =
        _userPosition ?? GlobalLocationService().userPosition;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onBackPressed();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_stopName.isNotEmpty ? _stopName : 'ตำแหน่งป้ายรถเมล์'),
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          elevation: 1,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _onBackPressed,
          ),
        ),
        body: Stack(
          children: [
            // ─── แผนที่ ───────────────────────────────────────────────────
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _stopLocation,
                initialZoom: 18,
                onTap: (tapPos, point) {
                  setState(() => _selectedStopId = null);
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: MapConfig.tileUrlTemplate,
                  userAgentPackageName: MapConfig.userAgentPackageName,
                ),

                // [LAYER 0.5] เส้นทางเดินเท้า
                if (_walkingPath.isNotEmpty)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _walkingPath,
                        strokeWidth: 5.0,
                        color: Colors.blueAccent,
                      ),
                    ],
                  ),

                MarkerLayer(
                  markers: [
                    // [LAYER 1] ไอคอนป้ายรถเมล์ทุกป้าย
                    ..._allBusStops.map((stop) {
                      bool isSelected = _selectedStopId == stop['id'];
                      return Marker(
                        point: LatLng(stop['lat'], stop['long']),
                        width: 200,
                        height: 100,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedStopId = (_selectedStopId == stop['id'])
                                  ? null
                                  : stop['id'];
                            });
                          },
                          child: Stack(
                            alignment: Alignment.bottomCenter,
                            clipBehavior: Clip.none,
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
                              if (isSelected)
                                Positioned(
                                  bottom: 50,
                                  child: Container(
                                    width: 160,
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(8),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Colors.black26,
                                          blurRadius: 4,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          stop['name'] ?? '',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 4),
                                        _buildRouteChips(stop['route_id']),
                                        const SizedBox(height: 4),
                                        InkWell(
                                          onTap: () {
                                            setState(() {
                                              _stopLocation = LatLng(
                                                stop['lat'],
                                                stop['long'],
                                              );
                                              _stopName = stop['name'];
                                            });
                                            _startNavigation();
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.blue,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: const Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons.directions_walk,
                                                  color: Colors.white,
                                                  size: 12,
                                                ),
                                                SizedBox(width: 4),
                                                Text(
                                                  "นำทาง",
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 10,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    }),

                    // [LAYER 2] หมุดแดง (เป้าหมาย)
                    Marker(
                      point: _stopLocation,
                      width: 60,
                      height: 60,
                      alignment: Alignment.bottomCenter,
                      child: IgnorePointer(
                        child: Stack(
                          alignment: Alignment.bottomCenter,
                          children: [
                            const Icon(
                              Icons.location_on,
                              color: Colors.red,
                              size: 36,
                            ),
                          ],
                        ),
                      ),
                    ),

                    // [LAYER 3] ลูกศร User (heading)
                    if (displayUserPos != null)
                      Marker(
                        point: displayUserPos,
                        width: 44,
                        height: 44,
                        child: _buildUserArrow(_userHeading),
                      ),
                  ],
                ),
              ],
            ),

            // ─── Re-route Banner ─────────────────────────────────────────
            if (_isRecalculating)
              Positioned(
                top: 8,
                left: 16,
                right: 16,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade700,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 6,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(width: 10),
                        Text(
                          'กำลังหาเส้นทางใหม่…',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // ─── Nav Banner (ลูกศรนำทาง) ────────────────────────────────
            if (_isNavigationActive)
              Positioned(top: 0, left: 0, right: 0, child: _buildNavBanner()),

            // ─── Re-route Banner ─────────────────────────────────────────
            if (_isRecalculating)
              Positioned(
                top: _isNavigationActive ? 96 : 8,
                left: 16,
                right: 16,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade700,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 6,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(width: 10),
                        Text(
                          'กำลังหาเส้นทางใหม่…',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),

        // ─── FAB ─────────────────────────────────────────────────────────
        floatingActionButton: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // [DEBUG] ปุ่ม simulate เดิน
            if (_debugMode)
              ...([
                FloatingActionButton.extended(
                  heroTag: "debug_walk_btn",
                  onPressed: _debugSimulateWalk,
                  label: const Text("▶ เดินหน้า"),
                  icon: const Icon(Icons.directions_walk),
                  backgroundColor: Colors.green.shade700,
                  foregroundColor: Colors.white,
                ),
                const SizedBox(height: 8),
                FloatingActionButton.extended(
                  heroTag: "debug_offroute_btn",
                  onPressed: _debugSimulateOffRoute,
                  label: const Text("↗ ออกนอกทาง"),
                  icon: const Icon(Icons.alt_route),
                  backgroundColor: Colors.deepOrange,
                  foregroundColor: Colors.white,
                ),
                const SizedBox(height: 8),
              ]),
            FloatingActionButton.extended(
              heroTag: "navigate_btn",
              onPressed: _isNavigating ? null : _startNavigation,
              label: _isNavigating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text("นำทางไปป้ายนี้"),
              icon: _isNavigating ? null : const Icon(Icons.directions_walk),
              backgroundColor: Colors.blue,
            ),
            const SizedBox(height: 10),
            FloatingActionButton(
              heroTag: "center_btn",
              onPressed: () {
                _mapController.move(_stopLocation, 18);
              },
              child: const Icon(Icons.center_focus_strong),
            ),
          ],
        ),
      ),
    );
  }
}

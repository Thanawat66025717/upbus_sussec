import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import 'models/bus_model.dart';
import 'models/bus_route_data.dart';
import 'services/global_location_service.dart';
import 'package:flutter_map_animations/flutter_map_animations.dart';
import 'services/route_manager_service.dart';
import 'services/map_config.dart';
import 'widgets/colored_bus_icon.dart';

/// หน้าผู้จัดการ - ดู Report ของ Feedback และคนขับรถ
class ManagerPage extends StatefulWidget {
  const ManagerPage({super.key});

  @override
  State<ManagerPage> createState() => _ManagerPageState();
}

class _ManagerPageState extends State<ManagerPage>
    with SingleTickerProviderStateMixin {
  final user = FirebaseAuth.instance.currentUser;
  late TabController _tabController;

  // Search & Filter
  String _feedbackSearch = '';
  String _feedbackTypeFilter = 'all'; // all, complain, rating

  String _driverSearch = '';
  String _driverRouteFilter = 'all'; // all, green, red, blue

  // Off-route tracking
  Map<String, DateTime> _recentOffRoutes = {};

  // Schedule Data
  Map<String, String> _startSchedule = {}; // bus_id -> route (green, red, blue)
  DateTimeRange _selectedDateRange = DateTimeRange(
    start: DateTime.now(),
    end: DateTime.now(),
  );
  String _scheduleSearch = '';
  String _scheduleFilter = 'all'; // all, assigned, unassigned

  // Active Off-Route Alert
  Map<String, dynamic>? _activeOffRouteAlert;
  Timer? _alertDismissTimer;
  bool _isOffRouteBannerExpanded = false;

  // --- Live Map ---
  final MapController _liveMapController = MapController();
  // Polylines are now generated dynamically in _buildLiveMapTab for real-time updates.
  int _selectedLiveMapRouteIndex = 0; // 0=all, 1=green, 2=red, 3=blue

  // --- PKY Config (Green Route) ---
  String _greenPkyMode = 'custom'; // 'none' | 'always' | 'custom'
  int _greenPkyStartHour = 14;
  int _greenPkyStartMinute = 0;
  bool _pkyConfigLoading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _listenToOffRouteLogs();
    _loadTodaySchedule();
    _loadGreenRouteConfig();
  }

  Future<void> _loadTodaySchedule() async {
    // Load schedule for the START date of the range
    final dateStr =
        "${_selectedDateRange.start.year}-${_selectedDateRange.start.month}-${_selectedDateRange.start.day}";
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('bus_schedule')
          .doc(dateStr)
          .get();

      if (snapshot.exists && snapshot.data() != null) {
        final data = snapshot.data()!;
        setState(() {
          _startSchedule.clear();
          data.forEach((key, value) {
            // Filter out metadata like 'last_updated'
            if (key != 'last_updated') {
              _startSchedule[key] = value.toString();
            }
          });
        });
      } else {
        setState(() {
          _startSchedule.clear();
        });
      }
    } catch (e) {
      debugPrint("Error loading schedule: $e");
    }
  }

  /// โหลด PKY config ของวันที่เลือก (start date)
  Future<void> _loadGreenRouteConfig() async {
    final date = _selectedDateRange.start;
    final dateStr = "${date.year}-${date.month}-${date.day}";
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('route_config')
          .doc(dateStr)
          .get();
      if (mounted) {
        setState(() {
          if (snapshot.exists && snapshot.data() != null) {
            final data = snapshot.data()!;
            _greenPkyMode = data['green_pky_mode']?.toString() ?? 'custom';
            _greenPkyStartHour =
                (data['green_pky_start_hour'] as num?)?.toInt() ?? 14;
            _greenPkyStartMinute =
                (data['green_pky_start_minute'] as num?)?.toInt() ?? 0;
          } else {
            // ไม่มี config → ใช้ default
            _greenPkyMode = 'custom';
            _greenPkyStartHour = 14;
            _greenPkyStartMinute = 0;
          }
        });
      }
    } catch (e) {
      debugPrint("Error loading PKY config: $e");
    }
  }

  /// บันทึก PKY config ลง Firestore สำหรับทุกวันในช่วงที่เลือก
  Future<void> _saveGreenRouteConfig() async {
    setState(() => _pkyConfigLoading = true);
    try {
      int days = _selectedDateRange.end
          .difference(_selectedDateRange.start)
          .inDays;
      if (days < 0) days = 0;

      for (int i = 0; i <= days; i++) {
        final date = _selectedDateRange.start.add(Duration(days: i));
        final dateStr = "${date.year}-${date.month}-${date.day}";
        await FirebaseFirestore.instance
            .collection('route_config')
            .doc(dateStr)
            .set({
              'green_pky_mode': _greenPkyMode,
              'green_pky_start_hour': _greenPkyStartHour,
              'green_pky_start_minute': _greenPkyStartMinute,
              'last_updated': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✅ บันทึกการตั้งค่าสายหน้ามอเรียบร้อย"),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("เกิดข้อผิดพลาด: $e")));
      }
    } finally {
      if (mounted) setState(() => _pkyConfigLoading = false);
    }
  }

  Future<void> _saveSchedule(String busId, String route) async {
    try {
      // Loop through all days in the selected range
      int days = _selectedDateRange.end
          .difference(_selectedDateRange.start)
          .inDays;
      if (days < 0) days = 0;

      for (int i = 0; i <= days; i++) {
        final date = _selectedDateRange.start.add(Duration(days: i));
        final dateStr = "${date.year}-${date.month}-${date.day}";

        if (route == "unassigned") {
          // Delete or set to null
          await FirebaseFirestore.instance
              .collection('bus_schedule')
              .doc(dateStr)
              .set({
                busId: FieldValue.delete(),
                'last_updated': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
        } else {
          await FirebaseFirestore.instance
              .collection('bus_schedule')
              .doc(dateStr)
              .set({
                busId: route,
                'last_updated': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
        }
      }

      setState(() {
        if (route == "unassigned") {
          _startSchedule.remove(busId);
        } else {
          _startSchedule[busId] = route;
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            route == "unassigned"
                ? "ยกเลิกเส้นทางแล้ว"
                : "บันทึกตารางเดินรถเรียบร้อย (ทั้งช่วงเวลา)",
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("เกิดข้อผิดพลาด: $e")));
    }
  }

  Future<void> _clearAllSchedules() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("ยืนยันการล้างข้อมูล"),
        content: const Text(
          "คุณแน่ใจหรือไม่ที่จะลบตารางเดินรถทั้งหมดในช่วงวันที่เลือก? ข้อมูลจะหายไปถาวร",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("ยกเลิก"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("ยืนยัน", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        // Loop through all days in the selected range
        int days = _selectedDateRange.end
            .difference(_selectedDateRange.start)
            .inDays;
        if (days < 0) days = 0;

        for (int i = 0; i <= days; i++) {
          final date = _selectedDateRange.start.add(Duration(days: i));
          final dateStr = "${date.year}-${date.month}-${date.day}";

          await FirebaseFirestore.instance
              .collection('bus_schedule')
              .doc(dateStr)
              .delete();
        }

        setState(() {
          _startSchedule.clear();
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("ล้างตารางเดินรถเรียบร้อยแล้ว")),
        );
      } catch (e) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("เกิดข้อผิดพลาด: $e")));
      }
    }
  }

  void _listenToOffRouteLogs() {
    // Listen to recent off-route logs
    FirebaseFirestore.instance
        .collection('off_route_logs')
        .orderBy('timestamp', descending: true)
        .limit(1) // Just catch the latest one for banner
        .snapshots()
        .listen((snapshot) {
          if (!mounted) return;
          if (snapshot.docs.isEmpty) return;

          final data = snapshot.docs.first.data();
          final timestamp = data['timestamp'] as Timestamp?;
          if (timestamp == null) return;

          final logTime = timestamp.toDate();
          final now = DateTime.now();
          final diff = now.difference(logTime);

          // If log is recent (< 1 minute), show alert
          if (diff.inSeconds < 60) {
            setState(() {
              _activeOffRouteAlert = data;
              _activeOffRouteAlert!['id'] =
                  snapshot.docs.first.id; // Store Doc ID too
            });

            // Cancel old timer
            _alertDismissTimer?.cancel();

            // Set timer to auto-dismiss when it becomes old (> 60s)
            int remainingSeconds = 60 - diff.inSeconds;
            if (remainingSeconds < 5)
              remainingSeconds = 5; // Minimum display time 5s

            _alertDismissTimer = Timer(Duration(seconds: remainingSeconds), () {
              if (mounted) {
                setState(() {
                  _activeOffRouteAlert = null;
                });
              }
            });
          } else {
            // Log is old, clear alert
            if (_activeOffRouteAlert != null) {
              setState(() {
                _activeOffRouteAlert = null;
              });
            }
          }
        });
  }

  @override
  void dispose() {
    _alertDismissTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _handleLogout() async {
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('หน้าผู้จัดการ'),
        backgroundColor: const Color(0xFF9C27B0),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _handleLogout,
            tooltip: 'ออกจากระบบ',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(icon: Icon(Icons.feedback), text: 'Feedback'),
            Tab(icon: Icon(Icons.person), text: 'คนขับรถ'),
            Tab(icon: Icon(Icons.calendar_today), text: 'จัดตาราง'),
            Tab(icon: Icon(Icons.bar_chart), text: 'รายงาน'),
            Tab(icon: Icon(Icons.map), text: 'Live Map'),
          ],
        ),
      ),
      body: Column(
        children: [
          _buildOffRouteAlertBanner(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildFeedbackTab(),
                _buildDriverTab(),
                _buildScheduleTab(),
                _buildReportTab(),
                _buildLiveMapTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Live Map ───────────────────────────────────────────────────────────────

  // List<Polyline> generation is now moved to build for dynamic updates.
  List<Polyline> _generateLiveMapPolylines(
    List<BusRouteData> dynamicRoutes,
    GlobalLocationService locationService,
  ) {
    // 1. สร้าง paired list (route, polyline) — ไม่พึ่ง index
    final List<MapEntry<BusRouteData, Polyline>> routePolylines = [];
    for (var route in dynamicRoutes) {
      if (route.pathPoints != null && route.pathPoints!.isNotEmpty) {
        List<LatLng> points = route.pathPoints!
            .map((p) => LatLng(p.latitude, p.longitude))
            .toList();
        routePolylines.add(
          MapEntry(
            route,
            Polyline(
              points: points,
              color: Color(route.colorValue).withOpacity(1.0),
              strokeWidth: 4.0,
            ),
          ),
        );
      }
    }

    if (routePolylines.isEmpty) return [];

    // 2. ★ กรอง variant ซ้ำตามเวลา (เช่น หน้ามอ AM/PM → แสดงแค่ตัวที่ active)
    final shortNameCounts = <String, int>{};
    for (var entry in routePolylines) {
      final sn = entry.key.shortName;
      shortNameCounts[sn] = (shortNameCounts[sn] ?? 0) + 1;
    }

    final isPKYActive = locationService.isGreenPKYActive();
    final now = DateTime.now();
    final filtered = routePolylines.where((entry) {
      final route = entry.key;
      if ((shortNameCounts[route.shortName] ?? 1) > 1) {
        // ★ S1 routes → ใช้ manager PKY config
        if (route.routeId == 'S1-AM') return !isPKYActive;
        if (route.routeId == 'S1-PM') return isPKYActive;
        // สายอื่นๆ → ใช้ startHour/endHour ของ route เอง
        return route.isActiveAt(now);
      }
      return true;
    }).toList();

    // 3. ภาพรวม → แสดงทุกสาย (ที่กรองแล้ว)
    if (_selectedLiveMapRouteIndex == 0) {
      return filtered.map((e) => e.value).toList();
    }

    // 4. เลือกสายเฉพาะ → filter ตาม shortName
    final uniqueRoutes = <BusRouteData>[];
    final seenShortNames = <String>{};
    for (var route in dynamicRoutes) {
      if (!seenShortNames.contains(route.shortName)) {
        seenShortNames.add(route.shortName);
        uniqueRoutes.add(route);
      }
    }

    if (_selectedLiveMapRouteIndex <= uniqueRoutes.length) {
      final targetShortName =
          uniqueRoutes[_selectedLiveMapRouteIndex - 1].shortName;
      return filtered
          .where((e) => e.key.shortName == targetShortName)
          .map((e) => e.value)
          .toList();
    }

    return [];
  }

  void _filterLiveMapRoutes(int index) {
    setState(() {
      _selectedLiveMapRouteIndex = index;
    });
  }

  Color _busColor(String routeIdentifier) {
    try {
      final routeManager = Provider.of<RouteManagerService>(
        context,
        listen: false,
      );
      // Try to find route by color name or ID
      final route = routeManager.allRoutes.firstWhere(
        (r) =>
            r.routeId.toLowerCase() == routeIdentifier.toLowerCase() ||
            r.shortName.toLowerCase() == routeIdentifier.toLowerCase(),
      );
      return Color(route.colorValue);
    } catch (_) {}

    switch (routeIdentifier.toLowerCase()) {
      case 'green':
        return const Color(0xFF44B678);
      case 'red':
        return const Color(0xFFFF3859);
      case 'blue':
        return const Color(0xFF1177FC);
      default:
        return Colors.purple;
    }
  }

  // _busIconAsset ถูกแทนที่ด้วย ColoredBusIcon widget

  /// คืน label + สี schedule ปัจจุบันของสายหน้ามอ (อ่านจาก GlobalLocationService)
  ({String label, String sub, Color color}) _greenRouteMode(
    GlobalLocationService locationService,
  ) {
    final mode = locationService.greenPkyMode;
    final isPKYActive = locationService.isGreenPKYActive();

    if (mode == 'always') {
      return (
        label: 'สายหน้ามอ: เข้า PKY ทั้งวัน',
        sub: 'ตั้งค่าโดย Manager: เข้า PKY ตลอดวัน',
        color: const Color(0xFFFF8C00),
      );
    }
    if (mode == 'none') {
      return (
        label: 'สายหน้ามอ: ไม่เข้า PKY ทั้งวัน',
        sub: 'ตั้งค่าโดย Manager: วิ่งเส้นปกติตลอดวัน',
        color: const Color(0xFF44B678),
      );
    }
    // custom (default)
    final h = locationService.greenPkyStartHour.toString().padLeft(2, '0');
    final m = locationService.greenPkyStartMinute.toString().padLeft(2, '0');
    if (isPKYActive) {
      return (
        label: 'สายหน้ามอ: เข้า PKY',
        sub: '$h:$m – 00:00  วิ่งเข้าหอพัก PKY',
        color: const Color(0xFFFF8C00),
      );
    }
    return (
      label: 'สายหน้ามอ: วิ่งปกติ',
      sub: '05:00 – $h:$m  วิ่งเส้นทางปกติ',
      color: const Color(0xFF44B678),
    );
  }

  Widget _routeButton({
    required String label,
    required Color color,
    required bool isSelected,
    required VoidCallback onPressed,
  }) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: isSelected ? color : Colors.white,
        foregroundColor: isSelected ? Colors.white : color,
        side: BorderSide(color: color),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        padding: const EdgeInsets.symmetric(vertical: 8),
      ),
      onPressed: onPressed,
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }

  /// เมื่อรถหลายคันจอดรวมกันที่จุดเดียวกัน (เช่น จุดพักรถ) ให้กระจาย marker
  /// ออกเป็นวงกลมเล็กๆ รอบตำแหน่งจริง เพื่อไม่ให้เลขรถ/ป้ายออกนอกเส้นทางซ้อนทับ
  /// กันจนอ่านไม่ออก (ตำแหน่งจริงของรถ/off-route logic ไม่ถูกกระทบ ใช้เพื่อวาดเท่านั้น)
  Map<String, LatLng> _declutterMarkerPositions(List<Bus> buses) {
    final buckets = <String, List<Bus>>{};
    for (final b in buses) {
      final key =
          '${b.position.latitude.toStringAsFixed(4)},${b.position.longitude.toStringAsFixed(4)}';
      buckets.putIfAbsent(key, () => []).add(b);
    }
    final result = <String, LatLng>{};
    for (final group in buckets.values) {
      if (group.length == 1) {
        result[group.first.id] = group.first.position;
        continue;
      }
      const radius = 0.00006; // ~6-7 เมตร
      for (var i = 0; i < group.length; i++) {
        final angle = (2 * math.pi * i) / group.length;
        final base = group[i].position;
        result[group[i].id] = LatLng(
          base.latitude + radius * math.cos(angle),
          base.longitude + radius * math.sin(angle),
        );
      }
    }
    return result;
  }

  Widget _buildLiveMapTab() {
    const kUniversity = LatLng(19.03011372185138, 99.89781512200192);
    return Consumer<GlobalLocationService>(
      builder: (context, locationService, _) {
        final allBuses = locationService.buses;
        final routeManager = context.watch<RouteManagerService>();
        final dynamicRoutes = routeManager.allRoutes;

        // Filter buses based on selected route index
        // [MODIFICATION] Handle grouped shortNames. 'S1-AM' and 'S1-PM' are grouped under 'S1'.
        final uniqueRoutes = <BusRouteData>[];
        final seenShortNames = <String>{};
        for (var route in dynamicRoutes) {
          if (!seenShortNames.contains(route.shortName)) {
            seenShortNames.add(route.shortName);
            uniqueRoutes.add(route);
          }
        }

        final buses = allBuses.where((bus) {
          if (_selectedLiveMapRouteIndex == 0) return true; // Show all

          if (_selectedLiveMapRouteIndex <= uniqueRoutes.length) {
            // เลือกสีของรถให้ตรงกับสีของ route ที่เลือก
            final targetRoute = uniqueRoutes[_selectedLiveMapRouteIndex - 1];

            // Match bus กับ route ที่เลือก (รองรับทั้ง routeId ใหม่และชื่อสีเดิม)
            final bId = bus.routeId.toLowerCase();
            final bColor = bus.routeColor.toLowerCase();
            final targetShort = targetRoute.shortName.toLowerCase();

            // 1. Check by routeId/shortName matching
            final matchingRouteIds = dynamicRoutes
                .where((r) => r.shortName == targetRoute.shortName)
                .map((r) => r.routeId.toLowerCase())
                .toList();

            if (matchingRouteIds.contains(bId) ||
                matchingRouteIds.contains(bColor) ||
                bId.contains(targetShort) ||
                bColor.contains(targetShort)) {
              return true;
            }

            // 2. Legacy color name matching
            String targetColorStr = '';
            if (targetShort.contains('s1')) targetColorStr = 'green';
            if (targetShort.contains('s2')) targetColorStr = 'red';
            if (targetShort.contains('s3')) targetColorStr = 'blue';

            return targetColorStr.isNotEmpty &&
                (bColor == targetColorStr || bId == targetColorStr);
          }
          return true;
        }).toList();

        final displayLines = _generateLiveMapPolylines(
          dynamicRoutes,
          locationService,
        );
        final liveMapMarkerPositions = _declutterMarkerPositions(buses);

        return Column(
          children: [
            // --- แถบปุ่มเลือกสายรถ ---
            Padding(
              padding: const EdgeInsets.all(6.0),
              child: Row(
                children: [
                  Expanded(
                    child: _routeButton(
                      label: 'ภาพรวม',
                      color: const Color.fromRGBO(143, 55, 203, 1),
                      isSelected: _selectedLiveMapRouteIndex == 0,
                      onPressed: () => _filterLiveMapRoutes(0),
                    ),
                  ),
                  ...uniqueRoutes.asMap().entries.map((entry) {
                    int idx = entry.key + 1; // 1, 2, 3...
                    var route = entry.value;
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6.0),
                        child: _routeButton(
                          label: route.shortName,
                          color: route.colorValue == 0xFF000000
                              ? Colors.grey
                              : Color(route.colorValue).withValues(alpha: 1.0),
                          isSelected: _selectedLiveMapRouteIndex == idx,
                          onPressed: () => _filterLiveMapRoutes(idx),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
            // --- ตัวแผนที่ ---
            Expanded(
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: _liveMapController,
                    options: const MapOptions(
                      initialCenter: kUniversity,
                      initialZoom: 16.5,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: MapConfig.tileUrlTemplate,
                        userAgentPackageName: MapConfig.userAgentPackageName,
                      ),
                      // แสดงจุดพักรถ (Rest Stop Areas)
                      CircleLayer(
                        circles: locationService.restStopZones.map((zone) {
                          final center = LatLng(
                            zone.location.latitude,
                            zone.location.longitude,
                          );
                          return CircleMarker(
                            point: center,
                            color: Colors.green.withValues(alpha: 0.2),
                            borderColor: Colors.green.withValues(alpha: 0.5),
                            borderStrokeWidth: 1,
                            radius: zone.radius,
                            useRadiusInMeter: true,
                          );
                        }).toList(),
                      ),
                      PolylineLayer(polylines: displayLines),
                      AnimatedMarkerLayer(
                        markers: buses.map((Bus bus) {
                          final isOffRoute = locationService.isOffRoute(bus.id);
                          final routeColor = _busColor(bus.routeColor);

                          return AnimatedMarker(
                            key: ValueKey(bus.id),
                            point:
                                liveMapMarkerPositions[bus.id] ?? bus.position,
                            width: 64,
                            height: 72,
                            duration: const Duration(milliseconds: 2800),
                            curve: Curves.linear,
                            builder: (context, animation) => Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                // ป้ายเลขรถ
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: routeColor,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    bus.name.replaceAll('รถเบอร์ ', ''),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                // ไอคอนรถ + badge
                                Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        boxShadow: [
                                          BoxShadow(
                                            color: routeColor.withValues(
                                              alpha: 0.4,
                                            ),
                                            blurRadius: 6,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: ColoredBusIcon(
                                        color: routeColor,
                                        size: 42,
                                      ),
                                    ),
                                    // ⚠ badge ถ้า off-route
                                    if (isOffRoute)
                                      Positioned(
                                        top: -4,
                                        right: -4,
                                        child: Container(
                                          width: 18,
                                          height: 18,
                                          decoration: const BoxDecoration(
                                            color: Colors.orange,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Center(
                                            child: Text(
                                              '!',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),

                  // Legend (Dynamic)
                  Positioned(
                    bottom: 16,
                    left: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.4,
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // ใช้ uniqueRoutes (dedupe ตาม shortName) เหมือนแถบปุ่มกรองด้านบน
                          // ไม่งั้น S1-AM/S1-PM (สีเดียวกัน ชื่อย่อเดียวกัน) จะขึ้นเป็น 2 แถวซ้ำ
                          ...uniqueRoutes.map((route) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 4.0),
                              child: _legendRow(
                                route.colorValue == 0xFF000000
                                    ? Colors.grey
                                    : Color(route.colorValue).withOpacity(1.0),
                                '${route.name} (${route.shortName})',
                              ),
                            );
                          }),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Container(
                                width: 18,
                                height: 18,
                                decoration: const BoxDecoration(
                                  color: Colors.orange,
                                  shape: BoxShape.circle,
                                ),
                                child: const Center(
                                  child: Text(
                                    '!',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'ออกนอกเส้นทาง',
                                style: TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                        ),
                      ),
                    ),
                  ),

                  // ปุ่ม center
                  Positioned(
                    bottom: 16,
                    right: 16,
                    child: FloatingActionButton.small(
                      heroTag: 'live_map_center',
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black87,
                      onPressed: () =>
                          _liveMapController.move(kUniversity, 16.5),
                      child: const Icon(Icons.center_focus_strong),
                    ),
                  ),
                  // Schedule banner ด้านบน
                  Positioned(
                    top: 8,
                    left: 12,
                    right: 12,
                    child: Builder(
                      builder: (_) {
                        final mode = _greenRouteMode(locationService);
                        final now = DateTime.now();
                        final timeStr =
                            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: mode.color,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 6,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.schedule,
                                color: Colors.white,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      mode.label,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      mode.sub,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                timeStr,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),

                  // ไม่มีรถเลย (แยกข้อความ: ทั้งระบบไม่มีรถ vs แค่สายที่เลือกไม่มีรถวิ่ง
                  // ไม่งั้นเลือกกรองสายที่ไม่มีรถจะดูเหมือนระบบติดตามล่มทั้งหมด)
                  if (buses.isEmpty)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          allBuses.isEmpty
                              ? 'ยังไม่มีรถออนไลน์'
                              : 'ไม่มีรถวิ่งในสายนี้ตอนนี้',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _legendRow(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  Widget _buildOffRouteAlertBanner() {
    // ใช้ Selector แทน context.watch ตรงๆ เพื่อให้เฉพาะแบนเนอร์นี้รีบิลด์เวลา
    // currentOffRouteBuses เปลี่ยน แทนที่จะทำให้ ManagerPage ทั้งหน้า (ทุกแท็บ) รีบิลด์
    // ทุกครั้งที่รถขยับ ซึ่งเดิมทำให้แท็บอื่น (เช่น Feedback) เสีย scroll position ซ้ำๆ
    return Selector<GlobalLocationService, List<Map<String, dynamic>>>(
      selector: (_, service) => service.currentOffRouteBuses,
      builder: (context, offRouteBuses, _) {
        if (offRouteBuses.isEmpty) return const SizedBox.shrink();

        return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.red.shade900,
            Colors.red.shade700,
            Colors.orange.shade800,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.red.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
        border: Border.all(color: Colors.white.withOpacity(0.2), width: 1.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Theme(
          data: Theme.of(context).copyWith(
            dividerColor: Colors.transparent,
            splashColor: Colors.white.withOpacity(0.1),
          ),
          child: ExpansionTile(
            initiallyExpanded: _isOffRouteBannerExpanded,
            onExpansionChanged: (expanded) {
              setState(() => _isOffRouteBannerExpanded = expanded);
            },
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 8,
            ),
            iconColor: Colors.white,
            collapsedIconColor: Colors.white,
            leading: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                ),
                const Icon(
                  Icons.report_problem_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ],
            ),
            title: Text(
              offRouteBuses.length == 1
                  ? "ตรวจพบรถออกนอกเส้นทาง!"
                  : "แจ้งเตือนรถออกนอกเส้นทาง (${offRouteBuses.length} คัน)",
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 17,
                letterSpacing: 0.2,
              ),
            ),
            subtitle: Text(
              offRouteBuses.length == 1
                  ? "รถเบอร์ ${(offRouteBuses.first['bus'] as Bus).name} กำลังผิดเส้นทาง"
                  : "แตะเพื่อดูรายชื่อรถที่มีปัญหาทั้งหมด",
              style: TextStyle(
                color: Colors.white.withOpacity(0.8),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            children: [
              Container(
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.black.withOpacity(0.1), Colors.transparent],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24),
                      child: Divider(color: Colors.white24, height: 1),
                    ),
                    const SizedBox(height: 8),
                    ...offRouteBuses.asMap().entries.map((entry) {
                      final index = entry.key;
                      final item = entry.value;
                      final bus = item['bus'] as Bus;
                      final dist = item['dist'] as double;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: InkWell(
                          onTap: () {
                            _tabController.animateTo(1); // Driver tab
                            _showOffRouteDetail({
                              'bus_id': bus.id,
                              'bus_name': bus.name,
                              'driver_name': bus.driverName,
                              'route_id': bus.routeId,
                              'deviation_meters': dist,
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.1),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  backgroundColor: Colors.white.withOpacity(
                                    0.2,
                                  ),
                                  radius: 20,
                                  child: Text(
                                    "${index + 1}",
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        "${bus.name} • สาย: ${bus.routeId}",
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        "ระยะเบี่ยงเบน: ${dist.toStringAsFixed(0)} เมตร",
                                        style: const TextStyle(
                                          color: Colors.yellowAccent,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (bus.driverName.isNotEmpty)
                                        Text(
                                          "คนขับ: ${bus.driverName}",
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(
                                              0.6,
                                            ),
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.1),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.chevron_right_rounded,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
        );
      },
    );
  }

  void _showOffRouteDetail(Map<String, dynamic> data) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        elevation: 10,
        backgroundColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.warning,
                  color: Colors.red.shade700,
                  size: 40,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                "พบรถออกนอกเส้นทาง",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "กรุณาตรวจสอบสถานะคนขับและเส้นทาง",
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              _detailRow("🚌 เบอร์รถ", data['bus_name']),
              _detailRow("🛣️ สายรถ", data['route_id']),
              if (data['driver_name'] != null)
                _detailRow("👨‍✈️ คนขับ", data['driver_name']),
              _detailRow(
                "📏 ระยะทางเบี่ยงออก",
                "${double.parse(data['deviation_meters'].toString()).toStringAsFixed(1)} เมตร",
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    "กำลังดำเนินการตรวจสอบ",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String? value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
            ),
          ),
          Text(
            value ?? '-',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  /// Tab 3: จัดตารางเดินรถ (Assign Routes)
  Widget _buildScheduleTab() {
    final locationService = context.watch<GlobalLocationService>();

    // Combine all known bus IDs from RTDB and buses with existing schedules
    // Filter out any metadata keys like 'last_updated'
    final Set<String> busIdSet = {
      ...locationService.allKnownBusIds,
      ..._startSchedule.keys,
    }.where((id) => id.startsWith('bus_')).toSet();

    final List<String> busIds = busIdSet.toList();
    // Sort bus IDs numerically (bus_1, bus_2, ...)
    busIds.sort((a, b) {
      int idA = int.tryParse(a.split('_').last) ?? 0;
      int idB = int.tryParse(b.split('_').last) ?? 0;
      return idA.compareTo(idB);
    });

    // Calculate Counts & Filter

    final filteredBusIds = busIds.where((busId) {
      final isAssigned = _startSchedule[busId] != null;
      // Filter by Search (Bus Number)
      if (_scheduleSearch.isNotEmpty && !busId.contains(_scheduleSearch)) {
        return false;
      }
      // Filter by Status
      if (_scheduleFilter == 'assigned' && !isAssigned) return false;
      if (_scheduleFilter == 'unassigned' && isAssigned) return false;

      return true;
    }).toList();

    return Column(
      children: [
        // PKY Config Card (Green Route)
        _buildPkyConfigCard(),

        // Date Header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final picked = await showDateRangePicker(
                          context: context,
                          firstDate: DateTime.now(),
                          lastDate: DateTime.now().add(
                            const Duration(days: 365),
                          ),
                          initialDateRange: _selectedDateRange,
                        );
                        if (picked != null) {
                          setState(() {
                            _selectedDateRange = picked;
                          });
                          _loadTodaySchedule(); // Reload for start date
                          _loadGreenRouteConfig(); // Reload PKY config for start date
                        }
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.date_range,
                                color: Colors.purple,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                "ระยะเวลา:",
                                style: TextStyle(
                                  color: Colors.purple.shade900,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "${_selectedDateRange.start.day}/${_selectedDateRange.start.month}/${_selectedDateRange.start.year} - "
                            "${_selectedDateRange.end.day}/${_selectedDateRange.end.month}/${_selectedDateRange.end.year}",
                            style: const TextStyle(fontSize: 16),
                          ),
                          const Text(
                            "(แตะเพื่อเปลี่ยน)",
                            style: TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Reset All Schedules Button
                  if (_startSchedule.isNotEmpty)
                    TextButton.icon(
                      onPressed: _clearAllSchedules,
                      icon: const Icon(Icons.delete_forever),
                      label: const Text("รีเซ็ตทั้งหมด"),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red,
                        backgroundColor: Colors.red.shade50,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        // Search & Filter for Schedule
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.white,
          child: Column(
            children: [
              TextField(
                decoration: InputDecoration(
                  hintText: 'ค้นหาเบอร์รถ...',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  suffixIcon: _scheduleSearch.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(() => _scheduleSearch = ''),
                        )
                      : null,
                ),
                controller: TextEditingController(text: _scheduleSearch)
                  ..selection = TextSelection.fromPosition(
                    TextPosition(offset: _scheduleSearch.length),
                  ),
                onChanged: (value) {
                  // Update state without resetting controller every time if possible,
                  // but here we just set state. Controller needs to be managed or just use local var
                  // To keep it simple in this replace, we just update state.
                  // BUT setting controller in build is bad practice.
                  // Let's just use onChanged and not force controller text here if consistent.
                  setState(() => _scheduleSearch = value);
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text(
                    "สถานะ: ",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildScheduleFilterChip("ทั้งหมด", "all", busIds),
                          const SizedBox(width: 8),
                          _buildScheduleFilterChip(
                            "เลือกแล้ว",
                            "assigned",
                            busIds,
                          ),
                          const SizedBox(width: 8),
                          _buildScheduleFilterChip(
                            "ว่าง",
                            "unassigned",
                            busIds,
                          ),
                          const SizedBox(width: 8),
                          if (_scheduleFilter != 'all' ||
                              _scheduleSearch.isNotEmpty)
                            TextButton.icon(
                              onPressed: () {
                                setState(() {
                                  _scheduleFilter = 'all';
                                  _scheduleSearch = '';
                                });
                              },
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text("รีเซ็ต"),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: Colors.white,
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: filteredBusIds.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final busId = filteredBusIds[index];
                final currentRoute =
                    _startSchedule[busId]; // green, red, blue, null

                return Card(
                  elevation: 2,
                  shadowColor: Colors.black12,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: Colors.grey.shade100),
                  ),
                  color: Colors.white,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    leading: CircleAvatar(
                      backgroundColor: Colors.purple.shade50,
                      foregroundColor: Colors.purple,
                      child: Text(
                        busId.split('_').last,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    title: Text(
                      "รถเบอร์ ${busId.split('_').last}",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      currentRoute == null || currentRoute == 'unassigned'
                          ? "ยังไม่ระบุเส้นทาง"
                          : "สาย: ${_currentRouteLabel(currentRoute)}",
                      style: TextStyle(
                        color:
                            currentRoute == null || currentRoute == 'unassigned'
                            ? Colors.grey
                            : _getRouteColor(currentRoute),
                        fontWeight:
                            currentRoute == null || currentRoute == 'unassigned'
                            ? FontWeight.normal
                            : FontWeight.w600,
                      ),
                    ),
                    trailing: Builder(
                      builder: (context) {
                        final routes = context
                            .watch<RouteManagerService>()
                            .allRoutes;

                        // Group routes by shortName to treat S1-AM/PM as one "S1"
                        final Map<String, BusRouteData> groupedRoutes = {};
                        for (var r in routes) {
                          if (!groupedRoutes.containsKey(r.shortName)) {
                            groupedRoutes[r.shortName] = r;
                          }
                        }

                        // Sanitize currentRoute to match value in Dropdown items
                        // This prevents "Unexpected null value" or assertion errors
                        String? sanitizedValue = currentRoute;
                        if (sanitizedValue == 'green' ||
                            sanitizedValue == 'S1-AM' ||
                            sanitizedValue == 'S1-PM') {
                          sanitizedValue = 'S1';
                        } else if (sanitizedValue == 'red') {
                          sanitizedValue = 'S2';
                        } else if (sanitizedValue == 'blue') {
                          sanitizedValue = 'S3';
                        }

                        // Final safety check: if sanitizedValue is not in items, set to null
                        final bool valueExists =
                            groupedRoutes.containsKey(sanitizedValue) ||
                            sanitizedValue == 'unassigned';
                        if (!valueExists) sanitizedValue = null;

                        return DropdownButton<String>(
                          value: sanitizedValue,
                          hint: const Text(
                            "เลือกสาย",
                            style: TextStyle(fontSize: 13),
                          ),
                          underline: Container(),
                          icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                          elevation: 8,
                          borderRadius: BorderRadius.circular(12),
                          dropdownColor: Colors.white,
                          items: [
                            ...groupedRoutes.values.map((r) {
                              // ถ้ามีหลาย variant (เช่น S1-AM, S1-PM) → แสดงชื่อสั้นไม่มี suffix
                              final hasMultiple =
                                  routes
                                      .where((x) => x.shortName == r.shortName)
                                      .length >
                                  1;
                              String label = hasMultiple
                                  ? r.name
                                        .replaceAll(RegExp(r'\s*\(.*\)'), '')
                                        .split('-')
                                        .first
                                        .trim()
                                  : r.name;
                              return DropdownMenuItem(
                                value: r.shortName,
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.circle,
                                      color: Color(r.colorValue),
                                      size: 12,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(label),
                                  ],
                                ),
                              );
                            }),
                            const DropdownMenuItem(
                              value: "unassigned",
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.cancel,
                                    color: Colors.grey,
                                    size: 12,
                                  ),
                                  SizedBox(width: 8),
                                  Text("ยกเลิก / ไม่ระบุ"),
                                ],
                              ),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              _saveSchedule(busId, value);
                            }
                          },
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  String _currentRouteLabel(String? routeId) {
    if (routeId == null || routeId == 'unassigned') return '-';
    // Special case for S1 grouped route
    if (routeId == 'S1' || routeId == 'S1-AM' || routeId == 'S1-PM') {
      return 'หน้ามอ';
    }

    try {
      final routeManager = context.read<RouteManagerService>();
      final route = routeManager.allRoutes.firstWhere(
        (r) => r.routeId == routeId || r.shortName == routeId,
      );
      // ถ้ามีหลาย variant → แสดงชื่อสั้น
      final hasMultiple =
          routeManager.allRoutes
              .where((x) => x.shortName == route.shortName)
              .length >
          1;
      if (hasMultiple) {
        return route.name
            .replaceAll(RegExp(r'\s*\(.*\)'), '')
            .split('-')
            .first
            .trim();
      }
      return route.name;
    } catch (_) {
      switch (routeId) {
        case 'green':
          return 'หน้ามอ';
        case 'red':
          return 'หอพัก (แดง)';
        case 'blue':
          return 'ICT (น้ำเงิน)';
        default:
          return routeId;
      }
    }
  }

  Color _getRouteColor(String? routeId) {
    if (routeId == null || routeId == 'unassigned') return Colors.black;
    // Special case for S1 grouped route
    if (routeId == 'S1' || routeId == 'S1-AM' || routeId == 'S1-PM') {
      return const Color(0xFF44B678); // Green
    }

    try {
      final routeManager = context.read<RouteManagerService>();
      final route = routeManager.allRoutes.firstWhere(
        (r) => r.routeId == routeId || r.shortName == routeId,
      );
      return Color(route.colorValue);
    } catch (_) {
      switch (routeId) {
        case 'green':
          return Colors.green;
        case 'red':
          return Colors.red;
        case 'blue':
          return Colors.blue;
        default:
          return Colors.black;
      }
    }
  }

  Widget _buildScheduleFilterChip(
    String label,
    String value,
    List<String> allBuses,
  ) {
    int count = 0;
    if (value == 'all') {
      count = allBuses.length;
    } else if (value == 'assigned') {
      count = allBuses.where((b) => _startSchedule[b] != null).length;
    } else if (value == 'unassigned') {
      count = allBuses.where((b) => _startSchedule[b] == null).length;
    }

    final isSelected = _scheduleFilter == value;
    return ChoiceChip(
      label: Text("$label ($count)"),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) setState(() => _scheduleFilter = value);
      },
      selectedColor: Colors.purple.shade100,
      labelStyle: TextStyle(
        color: isSelected ? Colors.purple.shade900 : Colors.black87,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
    );
  }

  /// Tab 1: รายงาน Feedback (จาก Firestore collection 'feedback')
  Future<void> _resetFeedback() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ยืนยันการลบ Feedback?'),
        content: const Text(
          'คุณต้องการลบข้อมูลความคิดเห็นทั้งหมดใช่หรือไม่?\n\n(การดำเนินการนี้ไม่สามารถย้อนกลับได้)',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ยกเลิก'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'ยืนยันการลบ',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await RouteManagerService().deleteAllFeedbacks();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ลบข้อมูล Feedback ทั้งหมดแล้ว')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('เกิดข้อผิดพลาด: $e')));
      }
    }
  }

  Widget _buildFeedbackTab() {
    // ... (Keep existing code same)
    return Column(
      children: [
        // Search & Filter Bar
        Container(
          padding: const EdgeInsets.all(12),
          color: Colors.grey.shade100,
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: 'ค้นหาข้อความ...',
                        prefixIcon: const Icon(Icons.search),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      ),
                      onChanged: (value) =>
                          setState(() => _feedbackSearch = value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _resetFeedback,
                    icon: const Icon(Icons.delete_sweep, color: Colors.red),
                    tooltip: 'ลบ Feedback ทั้งหมด',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Filter chips
              Row(
                children: [
                  const Text(
                    'ประเภท: ',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  _filterChip(
                    'ทั้งหมด',
                    'all',
                    _feedbackTypeFilter,
                    (v) => setState(() => _feedbackTypeFilter = v),
                  ),
                  const SizedBox(width: 8),
                  _filterChip(
                    'ร้องเรียน',
                    'complain',
                    _feedbackTypeFilter,
                    (v) => setState(() => _feedbackTypeFilter = v),
                  ),
                  const SizedBox(width: 8),
                  _filterChip(
                    'ให้คะแนน',
                    'rating',
                    _feedbackTypeFilter,
                    (v) => setState(() => _feedbackTypeFilter = v),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Feedback List
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('feedback')
                .orderBy('timestamp', descending: true)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError) {
                return Center(child: Text('เกิดข้อผิดพลาด: ${snapshot.error}'));
              }

              var feedbacks = snapshot.data?.docs ?? [];

              // Apply filters
              feedbacks = feedbacks.where((doc) {
                final data = doc.data() as Map<String, dynamic>;
                final message = (data['message'] ?? '')
                    .toString()
                    .toLowerCase();
                final type = data['type'] ?? 'complain';

                // Search filter
                if (_feedbackSearch.isNotEmpty &&
                    !message.contains(_feedbackSearch.toLowerCase())) {
                  return false;
                }

                // Type filter
                if (_feedbackTypeFilter != 'all' &&
                    type != _feedbackTypeFilter) {
                  return false;
                }

                return true;
              }).toList();

              if (feedbacks.isEmpty) {
                return const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inbox, size: 80, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        'ไม่พบ Feedback',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: feedbacks.length,
                itemBuilder: (context, index) {
                  final doc = feedbacks[index];
                  final data = doc.data() as Map<String, dynamic>;
                  final message = data['message'] ?? '';
                  final rating = data['rating'] ?? 0;
                  final type = data['type'] ?? 'complain';
                  final timestamp = data['timestamp'] as Timestamp?;
                  final dateStr = timestamp != null
                      ? '${timestamp.toDate().day}/${timestamp.toDate().month}/${timestamp.toDate().year} ${timestamp.toDate().hour}:${timestamp.toDate().minute.toString().padLeft(2, '0')}'
                      : '-';

                  return GestureDetector(
                    onTap: () => _showFeedbackDetail(
                      context,
                      message: message,
                      type: type,
                      rating: rating,
                      dateStr: dateStr,
                    ),
                    child: Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: type == 'complain'
                                        ? Colors.red.shade100
                                        : Colors.green.shade100,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    type == 'complain'
                                        ? 'ร้องเรียน'
                                        : 'ให้คะแนน',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: type == 'complain'
                                          ? Colors.red.shade700
                                          : Colors.green.shade700,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (type == 'rating')
                                  Row(
                                    children: List.generate(5, (i) {
                                      return Icon(
                                        i < rating
                                            ? Icons.star
                                            : Icons.star_border,
                                        color: Colors.amber,
                                        size: 18,
                                      );
                                    }),
                                  ),
                                const Spacer(),
                                Text(
                                  dateStr,
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.chevron_right,
                                  color: Colors.grey,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              message,
                              style: const TextStyle(fontSize: 14),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  /// Tab 2: รายชื่อคนขับรถ (จาก Realtime Database path 'GPS')
  Widget _buildDriverTab() {
    return Column(
      children: [
        // Search & Filter Bar
        Container(
          padding: const EdgeInsets.all(12),
          color: Colors.grey.shade100,
          child: Column(
            children: [
              // Search
              TextField(
                decoration: InputDecoration(
                  hintText: 'ค้นหาชื่อคนขับ...',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                ),
                onChanged: (value) => setState(() => _driverSearch = value),
              ),
              const SizedBox(height: 8),
              // Filter chips
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    const Text(
                      'สาย: ',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 8),
                    _filterChip(
                      'ทั้งหมด',
                      'all',
                      _driverRouteFilter,
                      (v) => setState(() => _driverRouteFilter = v),
                    ),
                    // สร้าง filter chips แบบ dynamic จาก RouteManagerService
                    ...(() {
                      final routeManager = context.read<RouteManagerService>();
                      final seenNames = <String>{};
                      final chips = <Widget>[];
                      for (var route in routeManager.allRoutes) {
                        if (!seenNames.contains(route.shortName)) {
                          seenNames.add(route.shortName);
                          chips.add(const SizedBox(width: 8));
                          chips.add(
                            _routeFilterChip(
                              route.shortName,
                              route.shortName.toLowerCase(),
                              Color(route.colorValue),
                            ),
                          );
                        }
                      }
                      return chips;
                    })(),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Driver List
        Expanded(
          child: StreamBuilder<DatabaseEvent>(
            stream: FirebaseDatabase.instance.ref('GPS').onValue,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError) {
                return Center(child: Text('เกิดข้อผิดพลาด: ${snapshot.error}'));
              }

              final data = snapshot.data?.snapshot.value;
              if (data == null) {
                return const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.person_off, size: 80, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        'ยังไม่มีข้อมูลคนขับ',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                );
              }

              // Get real-time off-route IDs from GlobalLocationService for consistency
              final offRouteBuses = context
                  .watch<GlobalLocationService>()
                  .currentOffRouteBuses;
              final offRouteIds = offRouteBuses
                  .map((e) => (e['bus'] as Bus).id)
                  .toSet();

              // Parse GPS data to get drivers
              List<Map<String, dynamic>> drivers = [];
              if (data is Map) {
                data.forEach((busId, busData) {
                  if (busData is Map) {
                    Map<dynamic, dynamic> driverData = busData;
                    if (busData.containsKey(busId) && busData[busId] is Map) {
                      driverData = busData[busId];
                    }

                    final driverName =
                        driverData['driverName']?.toString() ?? '';
                    final routeColor =
                        driverData['routeColor']?.toString() ?? '';
                    final lat = busData['lat'];
                    final lng = busData['lng'];

                    // Use real-time ID matching
                    final isOffRoute = offRouteIds.contains(busId.toString());

                    if (driverName.isNotEmpty) {
                      drivers.add({
                        'busId': busId,
                        'driverName': driverName,
                        'routeColor': routeColor,
                        'isActive': lat != null && lng != null,
                        'isOffRoute': isOffRoute,
                      });
                    }
                  }
                });
              }

              // Apply filters
              drivers = drivers.where((driver) {
                final name = (driver['driverName'] ?? '')
                    .toString()
                    .toLowerCase();
                final route = (driver['routeColor'] ?? '')
                    .toString()
                    .toLowerCase();

                // Search filter
                if (_driverSearch.isNotEmpty &&
                    !name.contains(_driverSearch.toLowerCase())) {
                  return false;
                }

                // Route filter — ใช้ flexible matching
                if (_driverRouteFilter != 'all') {
                  final filter = _driverRouteFilter.toLowerCase();
                  // match ทั้ง routeId, shortName, และชื่อสีเดิม
                  final matchesFilter =
                      route.contains(filter) ||
                      filter.contains(route) ||
                      _isLegacyColorMatch(route, filter);
                  if (!matchesFilter) return false;
                }

                return true;
              }).toList();

              if (drivers.isEmpty) {
                return const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.person_off, size: 80, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('ไม่พบคนขับ', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: drivers.length,
                itemBuilder: (context, index) {
                  final driver = drivers[index];
                  final busId = driver['busId'] ?? '';
                  final driverName = driver['driverName'] ?? 'ไม่ระบุชื่อ';
                  final routeColor = driver['routeColor'] ?? '';
                  final isActive = driver['isActive'] ?? false;
                  final isOffRoute = driver['isOffRoute'] ?? false;

                  Color routeColorValue = Colors.purple;
                  String routeName = 'ไม่ระบุ';

                  try {
                    final routeManager = Provider.of<RouteManagerService>(
                      context,
                      listen: false,
                    );
                    final rc = routeColor.toLowerCase();
                    final route = routeManager.allRoutes.firstWhere(
                      (r) =>
                          r.routeId.toLowerCase() == rc ||
                          r.shortName.toLowerCase() == rc ||
                          // Legacy: 'green' → S1, 'red' → S2, 'blue' → S3
                          (rc == 'green' &&
                              (r.routeId == 'S1-AM' || r.routeId == 'S1-PM')) ||
                          (rc == 'red' && r.routeId == 'S2') ||
                          (rc == 'blue' && r.routeId == 'S3'),
                    );
                    routeColorValue = Color(route.colorValue);
                    // ★ ถ้ามีหลาย variant → แสดงชื่อสั้นๆ (ไม่มีเวลา)
                    final hasMultiple =
                        routeManager.allRoutes
                            .where((r) => r.shortName == route.shortName)
                            .length >
                        1;
                    if (hasMultiple) {
                      routeName = route.name
                          .replaceAll(RegExp(r'\s*\(.*\)'), '')
                          .split('-')
                          .first
                          .trim();
                    } else {
                      routeName = route.name;
                    }
                  } catch (_) {
                    if (routeColor.toLowerCase() == 'green') {
                      routeColorValue = Colors.green;
                      routeName = 'สายหน้ามอ';
                    } else if (routeColor.toLowerCase() == 'red') {
                      routeColorValue = Colors.red;
                      routeName = 'สายหอพัก';
                    } else if (routeColor.toLowerCase() == 'blue') {
                      routeColorValue = Colors.blue;
                      routeName = 'สาย ICT';
                    }
                  }

                  return GestureDetector(
                    onTap: () => _showDriverDetail(
                      context,
                      driverName: driverName,
                      busId: busId,
                      routeName: routeName,
                      routeColor: routeColorValue,
                      isActive: isActive,
                    ),
                    child: Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      elevation: 3,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: isActive
                              ? routeColorValue
                              : Colors.grey.shade300,
                          width: 2,
                        ),
                      ),
                      child: Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Container(
                                  width: 60,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    color: routeColorValue.withValues(
                                      alpha: 0.15,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: routeColorValue,
                                      width: 2,
                                    ),
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.person,
                                        color: routeColorValue,
                                        size: 28,
                                      ),
                                      Text(
                                        busId.replaceAll('bus_', '#'),
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: routeColorValue,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            driverName,
                                            style: const TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          if (isOffRoute) ...[
                                            const SizedBox(width: 8),
                                            const Icon(
                                              Icons.error_outline_rounded,
                                              color: Colors.red,
                                              size: 20,
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: routeColorValue,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.route,
                                                  color: Colors.white,
                                                  size: 14,
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  'กำลังขับ $routeName',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                Column(
                                  children: [
                                    Container(
                                      width: 16,
                                      height: 16,
                                      decoration: BoxDecoration(
                                        color: isActive
                                            ? Colors.green
                                            : Colors.grey,
                                        shape: BoxShape.circle,
                                        boxShadow: isActive
                                            ? [
                                                BoxShadow(
                                                  color: Colors.green
                                                      .withValues(alpha: 0.5),
                                                  blurRadius: 8,
                                                  spreadRadius: 2,
                                                ),
                                              ]
                                            : null,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      isActive ? 'LIVE' : 'OFF',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: isActive
                                            ? Colors.green
                                            : Colors.grey,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    const Icon(
                                      Icons.chevron_right,
                                      color: Colors.grey,
                                      size: 20,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (isOffRoute)
                            Positioned(
                              top: 0,
                              right: 24,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: const BoxDecoration(
                                  color: Colors.red,
                                  borderRadius: BorderRadius.only(
                                    bottomLeft: Radius.circular(8),
                                    bottomRight: Radius.circular(8),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black26,
                                      blurRadius: 4,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: const Text(
                                  "OFF-ROUTE",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _filterChip(
    String label,
    String value,
    String currentValue,
    Function(String) onSelect,
  ) {
    final isSelected = currentValue == value;
    return GestureDetector(
      onTap: () => onSelect(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF9C27B0) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? const Color(0xFF9C27B0) : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.black87,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  /// เช็คว่าชื่อสีเดิม (green/red/blue) match กับ shortName (s1/s2/s3)
  bool _isLegacyColorMatch(String routeColor, String filter) {
    if (filter.contains('s1') && routeColor.contains('green')) return true;
    if (filter.contains('s2') && routeColor.contains('red')) return true;
    if (filter.contains('s3') && routeColor.contains('blue')) return true;
    return false;
  }

  Widget _routeFilterChip(String label, String value, Color color) {
    final isSelected = _driverRouteFilter == value;
    return GestureDetector(
      onTap: () => setState(() => _driverRouteFilter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? color : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color, width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : color,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// PKY Config Card — compact collapsible banner ใน Schedule Tab
  Widget _buildPkyConfigCard() {
    final s = _selectedDateRange.start;
    final e = _selectedDateRange.end;
    final sameDay = s.year == e.year && s.month == e.month && s.day == e.day;
    final dateLabel = sameDay
        ? '${s.day}/${s.month}/${s.year}'
        : '${s.day}/${s.month}/${s.year} – ${e.day}/${e.month}/${e.year}';

    // Label สรุปแบบสั้น
    String modeSummary;
    switch (_greenPkyMode) {
      case 'none':
        modeSummary = '🚫 ไม่เข้า PKY ทั้งวัน';
        break;
      case 'always':
        modeSummary = '✅ เข้า PKY ทั้งวัน';
        break;
      default:
        modeSummary =
            '⏰ PKY ตั้งแต่ ${_greenPkyStartHour.toString().padLeft(2, '0')}:${_greenPkyStartMinute.toString().padLeft(2, '0')} น.';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF44B678).withOpacity(0.3),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.green.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: const Icon(Icons.route, color: Color(0xFF44B678), size: 18),
          title: Text(
            'สายหน้ามอ: $modeSummary',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1B5E20),
            ),
          ),
          subtitle: Text(
            'วันที่ $dateLabel · แตะเพื่อแก้ไข',
            style: TextStyle(fontSize: 11, color: Colors.green.shade600),
          ),
          children: [
            // ─── 3 chip ───
            Row(
              children: [
                _pkyChip(
                  value: 'none',
                  label: '🚫 ไม่เข้า PKY',
                  activeColor: Colors.red.shade600,
                ),
                const SizedBox(width: 6),
                _pkyChip(
                  value: 'custom',
                  label: '⏰ กำหนดเวลา',
                  activeColor: Colors.orange.shade700,
                ),
                const SizedBox(width: 6),
                _pkyChip(
                  value: 'always',
                  label: '✅ ทั้งวัน',
                  activeColor: Colors.green.shade700,
                ),
              ],
            ),

            // ─── Time picker (custom only) ───
            if (_greenPkyMode == 'custom')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: InkWell(
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(
                        hour: _greenPkyStartHour,
                        minute: _greenPkyStartMinute,
                      ),
                      helpText: 'เริ่มวิ่งเข้า PKY เวลาใด?',
                    );
                    if (picked != null) {
                      setState(() {
                        _greenPkyStartHour = picked.hour;
                        _greenPkyStartMinute = picked.minute;
                      });
                    }
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.orange.shade300),
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.orange.shade50,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.access_time,
                          size: 14,
                          color: Colors.orange.shade700,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'เริ่มเข้า PKY: ${_greenPkyStartHour.toString().padLeft(2, '0')}:${_greenPkyStartMinute.toString().padLeft(2, '0')} น.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange.shade800,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.edit_outlined,
                          size: 12,
                          color: Colors.orange.shade600,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // ─── Save + Reset row ───
            const SizedBox(height: 10),
            Row(
              children: [
                // ปุ่มรีเซ็ตกลับ default
                OutlinedButton.icon(
                  onPressed: _pkyConfigLoading ? null : _resetGreenRouteConfig,
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text(
                    'คืนค่าเริ่มต้น',
                    style: TextStyle(fontSize: 12),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.grey.shade600,
                    side: BorderSide(color: Colors.grey.shade400),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // ปุ่มบันทึก
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _pkyConfigLoading ? null : _saveGreenRouteConfig,
                    icon: _pkyConfigLoading
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_outlined, size: 14),
                    label: Text(
                      _pkyConfigLoading ? 'กำลังบันทึก...' : 'บันทึก',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF44B678),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Chip สำหรับ PKY mode selector
  Widget _pkyChip({
    required String value,
    required String label,
    required Color activeColor,
  }) {
    final isSelected = _greenPkyMode == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _greenPkyMode = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? activeColor.withValues(alpha: 0.15)
                : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? activeColor : Colors.grey.shade300,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? activeColor : Colors.grey.shade600,
            ),
          ),
        ),
      ),
    );
  }

  /// รีเซ็ตกลับค่าเริ่มต้น (custom @ 14:00) — ลบ doc ของแต่ละวันออกจาก Firestore
  Future<void> _resetGreenRouteConfig() async {
    setState(() {
      _greenPkyMode = 'custom';
      _greenPkyStartHour = 14;
      _greenPkyStartMinute = 0;
      _pkyConfigLoading = true;
    });
    try {
      int days = _selectedDateRange.end
          .difference(_selectedDateRange.start)
          .inDays;
      if (days < 0) days = 0;
      for (int i = 0; i <= days; i++) {
        final date = _selectedDateRange.start.add(Duration(days: i));
        final dateStr = '${date.year}-${date.month}-${date.day}';
        await FirebaseFirestore.instance
            .collection('route_config')
            .doc(dateStr)
            .delete();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('คืนค่าเริ่มต้นแล้ว (เข้า PKY 14:00 น.)'),
            backgroundColor: Colors.grey,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('เกิดข้อผิดพลาด: $e')));
      }
    } finally {
      if (mounted) setState(() => _pkyConfigLoading = false);
    }
  }

  /// แสดง Dialog รายละเอียด Feedback
  void _showFeedbackDetail(
    BuildContext context, {
    required String message,
    required String type,
    required int rating,
    required String dateStr,
  }) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: 400,
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: type == 'complain'
                          ? Colors.red.shade100
                          : Colors.green.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          type == 'complain' ? Icons.warning : Icons.star,
                          size: 16,
                          color: type == 'complain'
                              ? Colors.red.shade700
                              : Colors.amber,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          type == 'complain' ? 'ร้องเรียน' : 'ให้คะแนน',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: type == 'complain'
                                ? Colors.red.shade700
                                : Colors.green.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    iconSize: 24,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Rating (if applicable)
              if (type == 'rating') ...[
                Row(
                  children: [
                    const Text(
                      'ความพึงพอใจ: ',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Row(
                      children: List.generate(5, (i) {
                        return Icon(
                          i < rating ? Icons.star : Icons.star_border,
                          color: Colors.amber,
                          size: 24,
                        );
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              // Message
              const Text(
                'ข้อความ:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  message,
                  style: const TextStyle(fontSize: 15, height: 1.5),
                ),
              ),
              const SizedBox(height: 16),
              // Date
              Row(
                children: [
                  const Icon(Icons.access_time, size: 16, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    dateStr,
                    style: TextStyle(color: Colors.grey[600], fontSize: 13),
                  ),
                ],
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }

  /// แสดง Dialog รายละเอียดคนขับ
  void _showDriverDetail(
    BuildContext context, {
    required String driverName,
    required String busId,
    required String routeName,
    required Color routeColor,
    required bool isActive,
  }) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Driver Avatar
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: routeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: routeColor, width: 3),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.person, color: routeColor, size: 50),
                    Text(
                      busId.replaceAll('bus_', 'รถ #'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: routeColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Driver Name
              Text(
                driverName,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              // Route Badge
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: routeColor,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.route, color: Colors.white, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      'กำลังขับ $routeName',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Status
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isActive ? Colors.green.shade50 : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isActive ? Colors.green : Colors.grey,
                    width: 2,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: isActive ? Colors.green : Colors.grey,
                        shape: BoxShape.circle,
                        boxShadow: isActive
                            ? [
                                BoxShadow(
                                  color: Colors.green.withValues(alpha: 0.5),
                                  blurRadius: 10,
                                  spreadRadius: 3,
                                ),
                              ]
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      isActive ? 'กำลังให้บริการ' : 'ไม่ได้ให้บริการ',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: isActive ? Colors.green.shade700 : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Bus Info
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    _infoRow(Icons.directions_bus, 'รหัสรถ', busId),
                    const SizedBox(height: 8),
                    _infoRow(Icons.person, 'ชื่อคนขับ', driverName),
                    const SizedBox(height: 8),
                    _infoRow(Icons.route, 'เส้นทาง', routeName),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Close Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF9C27B0),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'ปิด',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.grey),
        const SizedBox(width: 8),
        Text('$label: ', style: const TextStyle(color: Colors.grey)),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }

  /// Tab 4: รายงาน (Reports)
  Widget _buildReportTab() {
    return _ReportTabView();
  }
}

class _ReportTabView extends StatefulWidget {
  @override
  State<_ReportTabView> createState() => _ReportTabViewState();
}

class _ReportTabViewState extends State<_ReportTabView> {
  DateTime _selectedMonth = DateTime.now();
  Map<String, int> _busUsage = {};
  Map<String, int> _routeUsage = {};
  Map<String, Map<String, int>> _busRouteStats =
      {}; // busId -> { shortName -> dayCount }
  bool _isLoading = false;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _fetchReportData();
  }

  Future<void> _fetchReportData() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    try {
      final routeManager = Provider.of<RouteManagerService>(
        context,
        listen: false,
      );
      final allRoutes = routeManager.allRoutes;

      final snapshot = await FirebaseFirestore.instance
          .collection('bus_operation_logs')
          .where('year', isEqualTo: _selectedMonth.year)
          .where('month', isEqualTo: _selectedMonth.month)
          .get();

      // busId -> Set of days
      Map<String, Set<String>> globalBusDays = {};
      // routeId (shortName) -> trip count
      Map<String, int> routeCounts = {};
      // busId -> { shortName -> Set of days }
      Map<String, Map<String, Set<String>>> busRouteDays = {};

      // Initialize routeCounts with 0 for all existing routes
      final uniqueShortNames = allRoutes.map((r) => r.shortName).toSet();
      for (var sn in uniqueShortNames) {
        routeCounts[sn] = 0;
      }

      for (var doc in snapshot.docs) {
        final data = doc.data();
        final busId = data['bus_id']?.toString() ?? '';
        final routeId = data['route_id']?.toString() ?? '';
        final routeColor = data['route_color']?.toString() ?? '';
        final day = data['day']?.toString() ?? '';

        String category = '';
        if (routeId.isNotEmpty) {
          final r = allRoutes
              .where((element) => element.routeId == routeId)
              .firstOrNull;
          category = r?.shortName ?? routeId.split('-').first;
        } else if (routeColor.isNotEmpty) {
          if (routeColor == 'green')
            category = 'S1';
          else if (routeColor == 'red')
            category = 'S2';
          else if (routeColor == 'blue')
            category = 'S3';
        }

        if (category.isNotEmpty) {
          routeCounts[category] = (routeCounts[category] ?? 0) + 1;

          if (busId.isNotEmpty && day.isNotEmpty) {
            busRouteDays.putIfAbsent(busId, () => {});
            busRouteDays[busId]!.putIfAbsent(category, () => {});
            busRouteDays[busId]![category]!.add(day);
          }
        }

        if (busId.isNotEmpty && day.isNotEmpty) {
          globalBusDays.putIfAbsent(busId, () => {});
          globalBusDays[busId]!.add(day);
        }
      }

      Map<String, int> busUsageFinal = {};
      globalBusDays.forEach((k, v) => busUsageFinal[k] = v.length);

      Map<String, Map<String, int>> busRouteStatsFinal = {};
      busRouteDays.forEach((bus, routeMap) {
        busRouteStatsFinal[bus] = {};
        routeMap.forEach((route, days) {
          busRouteStatsFinal[bus]![route] = days.length;
        });
      });

      setState(() {
        _busUsage = busUsageFinal;
        _routeUsage = routeCounts;
        _busRouteStats = busRouteStatsFinal;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint("Error fetching report: $e");
      // สำคัญ: ต้องแยกสถานะ error ออกจาก "เดือนนี้ไม่มีข้อมูล" ไม่งั้นผู้จัดการจะเห็น
      // ข้อความ "ไม่มีข้อมูล" เหมือนเดือนนั้นไม่มีกิจกรรมจริง ทั้งที่จริงคือดึงข้อมูลล้มเหลว
      setState(() {
        _isLoading = false;
        _hasError = true;
        _busUsage = {};
        _routeUsage = {};
        _busRouteStats = {};
      });
    }
  }

  Future<void> _resetMonthlyLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("ยืนยันการล้างข้อมูล?"),
        content: Text(
          "คุณต้องการลบสถิติการเดินรถทั้งหมดของเดือน ${_monthName(_selectedMonth.month)} ${_selectedMonth.year + 543} ใช่หรือไม่?\n\n(การดำเนินการนี้ไม่สามารถย้อนกลับได้)",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("ยกเลิก"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              "ยืนยันการลบ",
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('bus_operation_logs')
          .where('year', isEqualTo: _selectedMonth.year)
          .where('month', isEqualTo: _selectedMonth.month)
          .get();

      final batch = FirebaseFirestore.instance.batch();
      for (var doc in snapshot.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("ล้างข้อมูลสำเร็จแล้ว")));
      _fetchReportData();
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("เกิดข้อผิดพลาดในการลบ: $e")));
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Month Selector
        Container(
          padding: const EdgeInsets.all(16),
          color: const Color.fromARGB(255, 255, 255, 255),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "เดือน: ${_monthName(_selectedMonth.month)} ${_selectedMonth.year + 543}",
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      // Simple Date Picker but only pick year/month?
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _selectedMonth,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                        initialDatePickerMode: DatePickerMode.year,
                      );
                      if (picked != null) {
                        setState(() {
                          _selectedMonth = picked;
                        });
                        _fetchReportData();
                      }
                    },
                    icon: const Icon(Icons.calendar_month),
                    label: const Text("เลือกเดือน"),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _resetMonthlyLogs,
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    tooltip: "ล้างข้อมูลเดือนนี้",
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_isLoading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_hasError)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 40),
                  const SizedBox(height: 12),
                  const Text(
                    'ดึงข้อมูลรายงานไม่สำเร็จ\nกรุณาตรวจสอบการเชื่อมต่อแล้วลองใหม่',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _fetchReportData,
                    icon: const Icon(Icons.refresh),
                    label: const Text('ลองใหม่'),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader("📊 สถิติสายรถ (จำนวนเที่ยว)"),
                  const SizedBox(height: 10),
                  (() {
                    final routeManager = Provider.of<RouteManagerService>(
                      context,
                      listen: false,
                    );
                    final uniqueRoutes = <BusRouteData>[];
                    final seenNames = <String>{};
                    for (var r in routeManager.allRoutes) {
                      if (!seenNames.contains(r.shortName)) {
                        seenNames.add(r.shortName);
                        uniqueRoutes.add(r);
                      }
                    }

                    if (uniqueRoutes.isEmpty) {
                      return const Center(child: Text("ยังไม่มีข้อมูลเส้นทาง"));
                    }

                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      alignment: WrapAlignment.center,
                      children: uniqueRoutes.map((route) {
                        final count = _routeUsage[route.shortName] ?? 0;

                        return _buildSimpleStatCard(
                          route.name,
                          route.shortName,
                          Color(route.colorValue),
                          count,
                        );
                      }).toList(),
                    );
                  })(),
                  const SizedBox(height: 30),
                  _buildSectionHeader("🚌 การใช้งานรถ (จำนวนวันวิ่ง)"),
                  const Text(
                    "คลิกที่เลขรถเพื่อดูรายละเอียดแยกตามสาย",
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 10),
                  if (_busUsage.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(
                        child: Text(
                          "ไม่มีข้อมูลการใช้งานในเดือนนี้",
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  else
                    ..._busUsage.entries.map((e) {
                      final busId = e.key;
                      final totalDays = e.value;
                      final routeStats = _busRouteStats[busId] ?? {};

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () => _showBusUsageDetail(
                            context,
                            busId,
                            totalDays,
                            routeStats,
                          ),
                          borderRadius: BorderRadius.circular(10),
                          child: ListTile(
                            leading: const Icon(
                              Icons.directions_bus,
                              color: Colors.purple,
                            ),
                            title: Text(
                              "รถเบอร์ ${busId.replaceAll('bus_', '')}",
                            ),
                            subtitle: const Text(
                              "ดูรายละเอียดวันวิ่งแยกตามสาย",
                            ),
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.purple.shade100,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                "$totalDays วัน",
                                style: TextStyle(
                                  color: Colors.purple.shade900,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: Colors.black87,
      ),
    );
  }

  Widget _buildSimpleStatCard(
    String title,
    String shortName,
    Color color,
    int count,
  ) {
    return Container(
      width: 110,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: color.withOpacity(0.3), width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            "$count",
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color.lerp(color, Colors.black, 0.2),
            ),
          ),
          Text(
            "สาย$shortName",
            style: TextStyle(
              fontSize: 12,
              color: Color.lerp(color, Colors.black, 0.4),
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  void _showBusUsageDetail(
    BuildContext context,
    String busId,
    int totalDays,
    Map<String, int> routeStats,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Row(
          children: [
            const Icon(Icons.analytics, color: Colors.purple),
            const SizedBox(width: 10),
            Text("รายละเอียด: รถเบอร์ ${busId.replaceAll('bus_', '')}"),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "เดือน: ${_monthName(_selectedMonth.month)} ${_selectedMonth.year + 543}",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const Divider(),
            if (routeStats.isEmpty)
              const Text("ยังไม่มีข้อมูลการวิ่งแยกตามสาย")
            else ...[
              const Text(
                "จำนวนวันวิ่งแยกตามสาย:",
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 8),
              ...routeStats.entries.map((e) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "สาย ${e.key}",
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      Text("${e.value} วัน"),
                    ],
                  ),
                );
              }),
            ],
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "รวมทั้งหมด:",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                Text(
                  "$totalDays วัน",
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.purple,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("ปิด"),
          ),
        ],
      ),
    );
  }

  String _monthName(int month) {
    const months = [
      "มกราคม",
      "กุมภาพันธ์",
      "มีนาคม",
      "เมษายน",
      "พฤษภาคม",
      "มิถุนายน",
      "กรกฎาคม",
      "สิงหาคม",
      "กันยายน",
      "ตุลาคม",
      "พฤศจิกายน",
      "ธันวาคม",
    ];
    return months[month - 1];
  }
}

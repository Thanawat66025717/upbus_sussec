import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart'; // Add this import
import 'dart:convert'; // For jsonDecode
import 'package:flutter/services.dart' show rootBundle; // For loading assets
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bus_model.dart';
import 'notification_service.dart';
import 'route_service.dart';
import 'route_manager_service.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../models/bus_route_data.dart';

/// Global service สำหรับ location tracking และแจ้งเตือนรถใกล้ถึง
/// ทำงานตลอดเวลาไม่ว่าจะอยู่หน้าไหนก็ตาม
class GlobalLocationService extends ChangeNotifier {
  static final GlobalLocationService _instance =
      GlobalLocationService._internal();
  factory GlobalLocationService() => _instance;

  // พิกัดจุดพักรถ (Rest Stops) — ดึงจาก RouteManagerService (ไม่ hardcode แล้ว)
  List<RestStopData> _restStopZones = [];

  List<LatLng> get restStops => _restStopZones
      .map((z) => LatLng(z.location.latitude, z.location.longitude))
      .toList();

  /// คืน rest stop zones พร้อม radius (สำหรับ UI)
  List<RestStopData> get restStopZones => _restStopZones;

  GlobalLocationService._internal();

  // State
  LatLng? _userPosition;
  List<Bus> _buses = [];
  Bus? _closestBus;
  Bus? _targetBus; // เพิ่ม: สำหรับเก็บรถเป้าหมายที่กำลังแจ้งเตือน/ติดตาม
  List<Map<String, dynamic>> _allBusStops = [];
  bool _notifyEnabled = false;
  String? _selectedNotifyRouteId;
  bool _isInitialized = false;
  Set<String> _allKnownBusIds = {}; // เก็บไอดีรถทั้งหมดที่รู้จักจาก RTDB

  // New State for Destination
  String? _destinationName;
  String? _destinationRouteId;
  final Map<String, double> _prevDistToDest =
      {}; // เก็บระยะห่างจากปลายทางครั้งก่อน
  final Map<String, int> _lastAlertStage =
      {}; // เก็บระดับการแจ้งเตือนล่าสุดของแต่ละคัน (0=ยังไม่แจ้ง, 1=5นาที, 2=3นาที, 3=1นาที, 4=ถึงแล้ว)

  // Off-Route Detection
  final Map<String, List<LatLng>> _routePaths = {}; // Cached route paths
  static const double _offRouteThresholdMeters = 50.0;

  // Snap-to-Route Interpolation
  final Map<String, LatLng> _displayedPositions =
      {}; // ตำแหน่งที่แสดงบน UI (smooth)
  final Map<String, Timer> _interpTimers = {}; // timer ต่อคัน
  final Map<String, bool> _recentOffRoutes = {}; // Track off-route status
  Set<String> _lastOffRouteBusIds = {};
  List<Map<String, dynamic>> _currentOffRouteBuses =
      []; // real-time off-route data
  static const int _aggregatedManagerAlertId = 9999;

  // ─── Green Route PKY Config ───────────────────────────────────────────────
  /// โหมดการวิ่งเข้า PKY ของสายหน้ามอ
  /// 'none' = ไม่เข้าตลอดวัน, 'always' = เข้าตลอดวัน, 'custom' = กำหนดเวลาเอง
  String _greenPkyMode = 'custom'; // default = เดิม (14:00)
  int _greenPkyStartHour = 14;
  int _greenPkyStartMinute = 0;
  StreamSubscription? _routeConfigSubscription;
  // ──────────────────────────────────────────────────────────────────────────

  // Subscriptions
  StreamSubscription? _busSubscription;
  StreamSubscription<Position>? _positionSubscription;

  // Constants
  static const double _alertDistanceMeters = 250.0; // ระยะ "มาถึงแล้ว"
  static const double _stopProximityMeters = 50.0;

  // Getters
  LatLng? get userPosition => _userPosition;
  bool isOffRoute(String busId) => _recentOffRoutes.containsKey(busId);

  /// Getter สำหรับ config PKY (ให้ UI อ่านค่าได้)
  String get greenPkyMode => _greenPkyMode;
  int get greenPkyStartHour => _greenPkyStartHour;
  int get greenPkyStartMinute => _greenPkyStartMinute;

  /// คืน true ถ้า ณ ตอนนี้สายหน้ามอควรวิ่งเข้า PKY
  bool isGreenPKYActive() {
    switch (_greenPkyMode) {
      case 'always':
        return true;
      case 'none':
        return false;
      case 'custom':
      default:
        final now = DateTime.now();
        final nowMins = now.hour * 60 + now.minute;
        final startMins = _greenPkyStartHour * 60 + _greenPkyStartMinute;
        return nowMins >= startMins;
    }
  }

  /// คืน buses พร้อมตำแหน่งที่ smooth แล้ว (snap-to-route)
  List<Bus> get buses {
    if (_displayedPositions.isEmpty) return _buses;
    return _buses.map((bus) {
      final displayed = _displayedPositions[bus.id];
      if (displayed != null) return bus.copyWithPosition(displayed);
      return bus;
    }).toList();
  }

  Bus? get closestBus => _closestBus;
  Bus? get targetBus => _targetBus; // เพิ่ม getter
  List<Map<String, dynamic>> get allBusStops => _allBusStops;
  bool get notifyEnabled => _notifyEnabled;
  String? get selectedNotifyRouteId => _selectedNotifyRouteId;
  bool get isInitialized => _isInitialized;
  Set<String> get allKnownBusIds => _allKnownBusIds;
  String? get destinationName => _destinationName;
  String? get destinationRouteId => _destinationRouteId;
  List<Map<String, dynamic>> get currentOffRouteBuses => _currentOffRouteBuses;

  String? _cachedDriverName;

  Future<bool> _startLocationTracking() async {
    debugPrint("📡 [GlobalLocationService] Starting location tracking...");

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint("❌ [GlobalLocationService] Location service is DISABLED!");
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint("❌ [GlobalLocationService] Permission DENIED!");
        return false;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      debugPrint("❌ [GlobalLocationService] Permission DENIED FOREVER!");
      return false;
    }

    // --- ดึงพิกัดเริ่มต้นทันทีเพื่อให้ระบบมีข้อมูล User Position ทันที ---
    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      _userPosition = LatLng(position.latitude, position.longitude);
      _updateClosestBus();
      notifyListeners();
      debugPrint(
        "📍 [GlobalLocationService] Initial position: ${_userPosition!.latitude}, ${_userPosition!.longitude}",
      );
    } catch (e) {
      debugPrint("❌ [GlobalLocationService] Initial position error: $e");
    }
    // -----------------------------------------------------------

    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationText:
                  "UP BUS กำลังติดตามตำแหน่งของท่านเพื่อสวัสดิภาพ",
              notificationTitle: "ระบบติดตามตำแหน่งทำงานอยู่",
              enableWakeLock: true,
            ),
          ),
        ).listen(
          (Position position) {
            _userPosition = LatLng(position.latitude, position.longitude);
            _updateClosestBus();
            notifyListeners();
          },
          onError: (e) {
            debugPrint("❌ [GlobalLocationService] Location Stream Error: $e");
          },
        );
    return true;
  }

  /// เริ่มต้น service (เรียกครั้งเดียวตอน app start หรือใน background isolate)
  Future<void> initialize({bool isBackground = false}) async {
    if (_isInitialized) return;

    debugPrint(
      "🚀 [GlobalLocationService] Initializing (isBackground: $isBackground)...",
    );

    await NotificationService.initialize();

    // ดึงข้อมูลจาก RouteManagerService เป็นหลัก
    final routeManager = RouteManagerService();
    await routeManager.initializeData();

    // ฟังการเปลี่ยนจาก Editor เผื่อมีการแก้ไขระหว่างใช้งาน
    routeManager.addListener(_syncDataWithRouteManager);

    _syncDataWithRouteManager(); // Sync ครั้งแรก

    _listenToGreenRouteConfig(); // Listen to PKY config from Firestore
    _listenToBusLocation();

    // Pre-fetch driver name for immediate caching
    final prefs = await SharedPreferences.getInstance();
    _cachedDriverName = prefs.getString('saved_driver_name');

    // ถ้าไม่ใช่โหมด background ให้เริ่มติดตามตำแหน่งผู้ใช้ และเริ่ม service เบื้องหลัง
    if (!isBackground) {
      bool hasPermission = await _startLocationTracking();
      // เริ่ม Background Service เพื่อเฝ้าระวังตอนพับจอ เมื่อได้รับสิทธิ GPS และไม่ใช่บนเว็บ หรือ Windows
      if (hasPermission &&
          !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        try {
          final service = FlutterBackgroundService();
          if (!(await service.isRunning())) {
            service.startService();
          }
        } catch (e) {
          debugPrint("Warning: Background service check failed: $e");
        }
      }
    }

    _isInitialized = true;
    debugPrint("✅ [GlobalLocationService] Initialized successfully");
  }

  void _syncDataWithRouteManager() {
    final routeManager = RouteManagerService();

    // Sync ป้ายรถ
    _allBusStops = routeManager.allStops.map((stop) {
      return {
        'id': stop.id,
        'name': stop.name,
        'lat': stop.location?.latitude ?? 0.0,
        'long': stop.location?.longitude ?? 0.0,
        'route_id': null, // ป้ายกลางใช้ร่วมกันหลายสาย
      };
    }).toList();

    // Sync พิกัดเส้นทาง
    _routePaths.clear();
    for (var route in routeManager.allRoutes) {
      if (route.pathPoints != null && route.pathPoints!.isNotEmpty) {
        _routePaths[route.routeId] = route.pathPoints!
            .map((p) => LatLng(p.latitude, p.longitude))
            .toList();
      } else {
        // Fallback to GeoJSON assets if no cloud path exists
        _loadSingleFallbackPath(route.routeId);
      }
    }

    debugPrint(
      "🔄 [GlobalLocationService] Synced with RouteManager: ${_allBusStops.length} stops, ${_routePaths.length} paths",
    );

    // Sync จุดพักรถ
    _restStopZones = routeManager.allRestStops;
    debugPrint(
      "🔄 [GlobalLocationService] Synced ${_restStopZones.length} rest stop zones",
    );

    notifyListeners();
  }

  Future<void> _loadSingleFallbackPath(String routeId) async {
    String assetPath = '';
    if (routeId == 'S1-PM')
      assetPath = 'assets/data/bus_route1_pm.geojson';
    else if (routeId == 'S1-AM' || routeId == 'S1')
      assetPath = 'assets/data/bus_route1_am.geojson';
    else if (routeId.contains('S2'))
      assetPath = 'assets/data/bus_route2.geojson';
    else if (routeId.contains('S3'))
      assetPath = 'assets/data/bus_route3.geojson';

    if (assetPath.isNotEmpty) {
      try {
        final points = await _parseGeoJsonToPoints(assetPath);
        if (points.isNotEmpty) {
          _routePaths[routeId] = points;
        }
      } catch (e) {
        debugPrint("Error loading fallback for $routeId: $e");
      }
    }
  }

  /// ฟังค่า config PKY สายหน้ามอจาก Firestore แบบ real-time
  void _listenToGreenRouteConfig() {
    final now = DateTime.now();
    final dateStr = "${now.year}-${now.month}-${now.day}";
    _routeConfigSubscription?.cancel();
    _routeConfigSubscription = FirebaseFirestore.instance
        .collection('route_config')
        .doc(dateStr)
        .snapshots()
        .listen((snapshot) {
          if (!snapshot.exists || snapshot.data() == null) {
            // ไม่มี config วันนี้ → ใช้ default
            _greenPkyMode = 'custom';
            _greenPkyStartHour = 14;
            _greenPkyStartMinute = 0;
          } else {
            final data = snapshot.data()!;
            _greenPkyMode = data['green_pky_mode']?.toString() ?? 'custom';
            _greenPkyStartHour =
                (data['green_pky_start_hour'] as num?)?.toInt() ?? 14;
            _greenPkyStartMinute =
                (data['green_pky_start_minute'] as num?)?.toInt() ?? 0;
          }
          debugPrint(
            "📋 [GreenRoute] PKY config: mode=$_greenPkyMode "
            "start=$_greenPkyStartHour:${_greenPkyStartMinute.toString().padLeft(2, '0')}",
          );
          // เมื่อ config เปลี่ยน ให้ recheck off-route ทันที
          _checkOffRouteStatus();
          notifyListeners();
        });
  }

  /// เปิด/ปิดการแจ้งเตือน
  void setNotifyEnabled(bool enabled, {String? routeId}) {
    _notifyEnabled = enabled;
    _selectedNotifyRouteId = routeId;
    _lastAlertStage.clear(); // Reset history

    // เรียกคำนวณใหม่ทันทีเพื่อไม่ให้ค้างสถานะ "ไม่พบรถ"
    _updateClosestBus();

    notifyListeners();
    debugPrint(
      "🔔 [GlobalLocationService] Notify enabled: $enabled, routeId: $routeId",
    );
  }

  /// ตั้งค่าจุดหมายปลายทาง (ถ้า name เป็น null คือยกเลิก)
  void setDestination(String? name, String? routeId) {
    _destinationName = name;
    _destinationRouteId = routeId;
    _prevDistToDest.clear(); // Reset history
    _lastAlertStage.clear(); // Reset alert history

    // ถ้ามีการเลือกปลายทาง ให้เปิดแจ้งเตือนอัตโนมัติสำหรับสายนั้น
    if (name != null && routeId != null) {
      _notifyEnabled = true;
      _selectedNotifyRouteId = routeId;
      debugPrint(
        "🎯 [GlobalLocationService] Source set to $name (Route: $routeId)",
      );
    } else {
      // ถ้ายกเลิก ก็ปิด notify ด้วยเพื่อป้องกัน fallback ไป "แจ้งเตือนทุกสาย"
      _notifyEnabled = false;
      _selectedNotifyRouteId = null;
      debugPrint(
        "❌ [GlobalLocationService] Destination cleared and notifications disabled",
      );
    }

    _updateClosestBus(); // Recalculate immediately
    notifyListeners();
  }

  /// คืนค่าพิกัดของจุดหมายปลายทาง (ถ้ามี)
  LatLng? get destinationPosition {
    if (_destinationName == null || _allBusStops.isEmpty) return null;
    try {
      final stop = _allBusStops.firstWhere(
        (s) => s['name'] == _destinationName,
      );
      return LatLng(stop['lat'], stop['long']);
    } catch (e) {
      return null;
    }
  }

  // _fetchBusStops is removed as it's now handled by _syncDataWithRouteManager

  /// ฟังตำแหน่งรถจาก Firebase Realtime Database
  void _listenToBusLocation() {
    final gpsRef = FirebaseDatabase.instance.ref("GPS");
    _busSubscription = gpsRef.onValue.listen((event) {
      final data = event.snapshot.value;
      if (data == null) return;

      // เก็บ bus เดิมไว้เพื่อ reuse object และเช็ค movement
      final prevMap = {for (var b in _buses) b.id: b};

      List<Bus> newBuses = [];
      bool anyChanged = false;

      if (data is Map) {
        // อัปเดตรายชื่อรถทั้งหมดที่มีใน RTDB (ดึงจาก keys)
        final keys = data.keys.map((k) => k.toString()).toSet();
        if (keys.any((k) => k == 'lat' || k == 'lng')) {
          // กรณีโครงสร้างข้อมูลแบบเก่า (ตัวอย่างเดียว)
          _allKnownBusIds.add('bus_1');
        } else {
          _allKnownBusIds.addAll(keys);
        }

        data.forEach((key, value) {
          if (value is Map &&
              value.containsKey('lat') &&
              value.containsKey('lng')) {
            try {
              final fresh = Bus.fromFirebase(key.toString(), value);
              final prev = prevMap[fresh.id];

              if (prev == null) {
                // รถใหม่
                newBuses.add(fresh);
                anyChanged = true;
              } else {
                // ตรวจว่าขยับเกิน 2 เมตรไหม
                const dist = Distance();
                final moved = dist.as(
                  LengthUnit.Meter,
                  prev.position,
                  fresh.position,
                );
                if (moved >= 2.0) {
                  newBuses.add(fresh); // ใช้ตำแหน่งใหม่
                  anyChanged = true;
                } else {
                  newBuses.add(
                    prev,
                  ); // ใช้ object เดิม — AnimatedMarker ไม่ warp
                }
              }
            } catch (e) {
              debugPrint('Error parsing bus $key: $e');
            }
          }
        });

        if (newBuses.isEmpty &&
            data.containsKey('lat') &&
            data.containsKey('lng')) {
          newBuses.add(Bus.fromFirebase('bus_1', data));
          anyChanged = true;
        }
      }

      // เรียง list ให้ stable ตาม bus id — ป้องกัน key mismatch
      newBuses.sort((a, b) => a.id.compareTo(b.id));

      if (anyChanged || newBuses.length != prevMap.length) {
        _buses = newBuses; // อัปเดต list หลักก่อน
        _checkOffRouteStatus();

        // เรียก smooth interpolation สำหรับรถที่ตำแหน่งเปลี่ยน
        for (final bus in newBuses) {
          final prev = prevMap[bus.id];
          // interpolate เฉพาะรถที่ตำแหน่งเปลี่ยน (หรือรถใหม่)
          if (prev == null || prev.position != bus.position) {
            _interpolateAlongRoute(bus);
          }
        }
        _updateClosestBus(); // ไม่ต้อง notify ตรงนี้ เพราะ _updateClosestBus จะเรียกให้ตอนเสร็จ
      }
    });
  }

  List<LatLng>? _getRoutePathForColor(String routeColor) {
    // 0. ลองหาจาก routeId โดยตรง (สำหรับ custom routes เช่น S4, PKY)
    if (_routePaths.containsKey(routeColor)) return _routePaths[routeColor];

    final c = routeColor.toLowerCase();

    // 1. ★ Dynamic: หาจาก RouteManagerService (รองรับ shortName ภาษาไทย)
    final routeManager = RouteManagerService();
    BusRouteData? matchedRoute;
    for (var route in routeManager.allRoutes) {
      if (route.routeId.toLowerCase() == c ||
          route.shortName.toLowerCase() == c) {
        matchedRoute = route;
        break;
      }
    }

    if (matchedRoute != null) {
      // เช็คว่ามีหลาย variant มั้ย
      final variants = routeManager.allRoutes
          .where((r) => r.shortName == matchedRoute!.shortName)
          .toList();

      if (variants.length > 1) {
        // ★ S1 → ใช้ manager PKY config
        final targetId = isGreenPKYActive() ? 'S1-PM' : 'S1-AM';
        if (_routePaths.containsKey(targetId)) {
          return _routePaths[targetId];
        }
        for (var v in variants) {
          if (v.isActiveAt(DateTime.now()) &&
              _routePaths.containsKey(v.routeId)) {
            return _routePaths[v.routeId];
          }
        }
      }
      if (_routePaths.containsKey(matchedRoute.routeId)) {
        return _routePaths[matchedRoute.routeId];
      }
    }

    // 2. Legacy: จัดการชื่อสีเก่า
    if (c.contains('green') || c.contains('เขียว') || c.contains('s1')) {
      return isGreenPKYActive() ? _routePaths['S1-PM'] : _routePaths['S1-AM'];
    }

    // 3. Fallback: พยายามหาจาก ID ที่ตรงกันใน Cache
    for (var key in _routePaths.keys) {
      if (c.contains(key.toLowerCase()) || key.toLowerCase().contains(c)) {
        return _routePaths[key];
      }
    }

    return null;
  }

  /// แมป route_id ของป้าย → key ของ _routePaths
  List<LatLng>? _getRoutePathForStopRouteId(String? routeId) {
    if (routeId == null) return null;
    final r = routeId.toLowerCase();

    if (r.contains('green') || r.contains('s1') || r.contains('เขียว')) {
      return isGreenPKYActive() ? _routePaths['S1-PM'] : _routePaths['S1-AM'];
    }

    // ค้นหาแบบ Dynamic
    if (_routePaths.containsKey(routeId)) return _routePaths[routeId];

    for (var key in _routePaths.keys) {
      if (r.contains(key.toLowerCase()) || key.toLowerCase().contains(r)) {
        return _routePaths[key];
      }
    }
    return null;
  }

  /// คำนวณรถที่ใกล้ที่สุดและแจ้งเตือน
  Future<void> _updateClosestBus() async {
    if (_buses.isEmpty || _userPosition == null) {
      if (_buses.isEmpty)
        debugPrint("DEBUG: _updateClosestBus - _buses is EMPTY");
      if (_userPosition == null)
        debugPrint("DEBUG: _updateClosestBus - _userPosition is NULL");
      return;
    }

    final Distance distance = const Distance();

    // 1. หาป้ายที่ใกล้ตัวเราที่สุด (เพื่อดู Context ว่าเราอยู่ที่ป้ายหรือเปล่า)
    Map<String, dynamic>? closestStopToUser;
    double userDistToClosestStop = double.infinity;
    String closestStopName = "ไม่ทราบชื่อ";

    if (_allBusStops.isNotEmpty) {
      for (var stop in _allBusStops) {
        final stopPos = LatLng(stop['lat'], stop['long']);
        // ใช้ระยะทางจริง (Route Distance) ถ้าทำได้
        final d = _calculateDistanceToStop(
          stopPos,
          stop['route_id']?.toString(),
        );
        if (d < userDistToClosestStop) {
          userDistToClosestStop = d;
          closestStopToUser = stop;
        }
      }
      if (closestStopToUser != null) {
        closestStopName = closestStopToUser['name'].toString();
      }
    }

    // 2. เช็คว่า "เราอยู่ที่ป้ายไหม?" (ระยะห่างตามถนน <= 50 เมตร)
    // แต่ตอนนี้เราจะใช้ closestStopToUser เป็น target หลักในการแจ้งเตือนเสมอ
    // ถ้าเราอยู่ใกล้ป้าย (< 50m) ก็ถือว่ารอที่ป้าย
    final bool isUserAtStop =
        closestStopToUser != null &&
        userDistToClosestStop <= _stopProximityMeters;

    List<Bus> busesWithDistance = [];

    for (final bus in _buses) {
      // คำนวณระยะทางสำหรับรถคันนี้
      double distToTarget;

      // เราต้องใช้ Route Path ของรถคันนั้นๆ ในการวัดระยะเสมอ
      final routePath = _getRoutePathForColor(bus.routeColor);

      if (closestStopToUser != null) {
        // กรณีใหม่: ยึด "ป้ายที่ใกล้ที่สุด" เป็นหลักเสมอ
        // วัดระยะ "รถ -> ป้ายที่ใกล้ที่สุด"
        final stopPos = LatLng(
          closestStopToUser['lat'],
          closestStopToUser['long'],
        );

        double? polyDist;
        if (routePath != null && routePath.length >= 2) {
          polyDist = RouteService.getPolylineDistance(
            bus.position,
            stopPos,
            routePath,
          );
        }
        distToTarget =
            polyDist ?? distance.as(LengthUnit.Meter, bus.position, stopPos);
      } else {
        // กรณีสำรอง: หาป้ายไม่เจอจริงๆ ค่อยวัด "รถ -> เรา"
        double? polyDist;
        if (routePath != null && routePath.length >= 2) {
          polyDist = RouteService.getPolylineDistance(
            _userPosition!,
            bus.position,
            routePath,
          );
        }
        distToTarget =
            polyDist ??
            distance.as(LengthUnit.Meter, _userPosition!, bus.position);
      }

      busesWithDistance.add(bus.copyWithDistance(distToTarget));
    }

    // 3. เรียงลำดับรถตามระยะทางเพื่อให้คันที่ใกล้ที่สุดอยู่ลำดับแรก
    busesWithDistance.sort(
      (a, b) => (a.distanceToUser ?? double.infinity).compareTo(
        b.distanceToUser ?? double.infinity,
      ),
    );

    // กำหนด _closestBus (แบบ Global)
    _closestBus = busesWithDistance.isNotEmpty ? busesWithDistance.first : null;

    // 4. กำหนด _targetBus ตามเงื่อนไขการแจ้งเตือน
    _targetBus = null;

    if (_notifyEnabled) {
      if (_destinationName != null &&
          _destinationRouteId != null &&
          destinationPosition != null) {
        // กรณีเลือกปลายทาง
        final targetId = _destinationRouteId!.trim().toLowerCase();
        final destPos = destinationPosition!;

        var candidateBuses = busesWithDistance.where((b) {
          return isBusMatchRoute(b, targetId);
        }).toList();

        // Sort candidates too
        candidateBuses.sort(
          (a, b) => (a.distanceToUser ?? double.infinity).compareTo(
            b.distanceToUser ?? double.infinity,
          ),
        );

        Bus? approachingBus;
        double minDistance = double.infinity;

        for (var bus in candidateBuses) {
          double distToDest = distance.as(
            LengthUnit.Meter,
            bus.position,
            destPos,
          );
          if (_prevDistToDest.containsKey(bus.id)) {
            if (distToDest <= _prevDistToDest[bus.id]!) {
              if ((bus.distanceToUser ?? double.infinity) < minDistance) {
                minDistance = bus.distanceToUser ?? double.infinity;
                approachingBus = bus;
              }
            }
          } else {
            if ((bus.distanceToUser ?? double.infinity) < minDistance) {
              minDistance = bus.distanceToUser ?? double.infinity;
              approachingBus = bus;
            }
          }
          _prevDistToDest[bus.id] = distToDest;
        }
        _targetBus = approachingBus;
      } else if (_selectedNotifyRouteId != null) {
        // กรณีเลือกเฉพาะสาย
        final targetFilter = _selectedNotifyRouteId!.trim().toLowerCase();
        final filteredBuses = busesWithDistance.where((b) {
          return isBusMatchRoute(b, targetFilter);
        }).toList();

        // Sort filtered buses
        filteredBuses.sort(
          (a, b) => (a.distanceToUser ?? double.infinity).compareTo(
            b.distanceToUser ?? double.infinity,
          ),
        );

        _targetBus = filteredBuses.isNotEmpty ? filteredBuses.first : null;
      } else {
        // กรณีทุกสาย
        _targetBus = _closestBus;
      }

      // --- Debug Info ---
      if (_targetBus != null) {
        final dist = _targetBus!.distanceToUser ?? 0;
        final eta = NotificationService.calculateEtaSeconds(dist);
        debugPrint(
          "🎯 [GlobalLocationService] Tracking Target: ${_targetBus!.id} (${_targetBus!.routeId}) - Dist: ${dist.toStringAsFixed(0)}m, ETA: $eta s",
        );
      } else {
        debugPrint(
          "🔍 [GlobalLocationService] No target bus found. (Total buses: ${busesWithDistance.length})",
        );
      }

      // --- แจ้งเตือน (Notification / Push) ---
      if (_targetBus != null) {
        final targetBus = _targetBus!;
        final targetDist = targetBus.distanceToUser ?? double.infinity;
        final etaSeconds = NotificationService.calculateEtaSeconds(targetDist);
        final busId = targetBus.id;
        final lastStage = _lastAlertStage[busId] ?? 0;

        // เตรียม Context ข้อความ
        String contextMsg = closestStopToUser != null
            ? "ป้าย$closestStopName"
            : "คุณ";
        if (closestStopToUser != null && !isUserAtStop)
          contextMsg += " (ป้ายใกล้คุณ)";

        // เช็ค Stage การแจ้งเตือน (Push Alert)
        if (targetDist <= _alertDistanceMeters && lastStage < 4) {
          _sendArrivalAlert(
            targetBus,
            targetDist,
            etaSeconds,
            contextMsg,
            isUserAtStop,
          );
          _lastAlertStage[busId] = 4;
        } else if (etaSeconds <= 60 && lastStage < 3) {
          _sendArrivalAlert(
            targetBus,
            targetDist,
            etaSeconds,
            contextMsg,
            isUserAtStop,
          );
          _lastAlertStage[busId] = 3;
        } else if (etaSeconds <= 180 && lastStage < 2) {
          _sendArrivalAlert(
            targetBus,
            targetDist,
            etaSeconds,
            contextMsg,
            isUserAtStop,
          );
          _lastAlertStage[busId] = 2;
        } else if (etaSeconds <= 300 && lastStage < 1) {
          _sendArrivalAlert(
            targetBus,
            targetDist,
            etaSeconds,
            contextMsg,
            isUserAtStop,
          );
          _lastAlertStage[busId] = 1;
        }
      }
    }

    _buses = busesWithDistance; // อัปเดตลิสต์ที่มีระยะทางแล้ว
    notifyListeners();
  }

  Future<void> _sendArrivalAlert(
    Bus bus,
    double dist,
    int eta,
    String locationContext,
    bool isAtStop,
  ) async {
    // ดึงชื่อสายจาก RouteManagerService (รองรับทุกเส้นทาง)
    String routeLabel = "";
    final rId = bus.routeId.toLowerCase();
    final routeManager = RouteManagerService();
    for (var route in routeManager.allRoutes) {
      if (route.routeId.toLowerCase() == rId ||
          route.shortName.toLowerCase() == rId) {
        routeLabel = "สาย ${route.shortName}";
        break;
      }
    }
    // Fallback: ใช้ชื่อสีเดิม (backward compat)
    if (routeLabel.isEmpty) {
      if (rId.contains("green")) {
        routeLabel = "สีเขียว";
      } else if (rId.contains("red")) {
        routeLabel = "สีแดง";
      } else if (rId.contains("blue")) {
        routeLabel = "สีน้ำเงิน";
      } else if (rId.contains("purple")) {
        routeLabel = "สีม่วง";
      } else {
        routeLabel = "รถ";
      }
    }

    // Format Title
    String title = "🚌 $routeLabel กำลังมา!";

    // Format Body
    String timeText = (eta <= 0 || dist < 50)
        ? "ถึงแล้ว"
        : "อีก ${NotificationService.formatEta(eta)}";

    String body;
    if (dist < 50) {
      body = isAtStop ? "รถแวะจอดที่$locationContext แล้ว" : "รถถึงตัวคุณแล้ว";
    } else {
      body = "$timeText จะถึง$locationContext";
    }

    if (_destinationName != null) {
      body += " (ไป: $_destinationName)";
    }

    // เรียกใช้ showNotification โดยตรงเพื่อให้ Custom Body ได้เต็มที่
    await NotificationService.showNotification(
      id: bus.id.hashCode,
      title: title,
      body: "$body (ห่าง ${dist.toStringAsFixed(0)} ม.)",
      payload: "bus_${bus.id}",
    );
    await NotificationService.vibrate();

    debugPrint("🔔 Alert: $title - $body");
  }

  /// คำนวณระยะทางไปยังป้ายรถตาม polyline (ถ้ามี route path)
  double _calculateDistanceToStop(LatLng stopPos, String? routeId) {
    if (_userPosition == null) return double.infinity;
    final Distance distance = const Distance();
    final routePath = _getRoutePathForStopRouteId(routeId);
    if (routePath != null && routePath.length >= 2) {
      final polyDist = RouteService.getPolylineDistance(
        _userPosition!,
        stopPos,
        routePath,
      );
      if (polyDist != null) return polyDist;
    }
    // Fallback เป็น Haversine
    return distance.as(LengthUnit.Meter, _userPosition!, stopPos);
  }

  /// คำนวณหาป้ายที่ใกล้ที่สุด
  String getClosestStopInfo() {
    if (_userPosition == null) return "รอ GPS...";
    if (_allBusStops.isEmpty) return "ไม่มีข้อมูลป้าย";

    double closestDist = double.infinity;
    String? closestName;

    for (var stop in _allBusStops) {
      final stopPos = LatLng(stop['lat'], stop['long']);
      final dist = _calculateDistanceToStop(
        stopPos,
        stop['route_id']?.toString(),
      );
      if (dist < closestDist) {
        closestDist = dist;
        closestName = stop['name'];
      }
    }

    if (closestName == null) return "ไม่พบ";
    return "$closestName (${closestDist.toStringAsFixed(0)}m)";
  }

  /// คืนค่า Map ของป้ายที่ใกล้ที่สุด
  Map<String, dynamic>? findClosestStop() {
    if (_userPosition == null || _allBusStops.isEmpty) return null;

    double closestDist = double.infinity;
    Map<String, dynamic>? closestStop;

    for (var stop in _allBusStops) {
      final stopPos = LatLng(stop['lat'], stop['long']);
      final dist = _calculateDistanceToStop(
        stopPos,
        stop['route_id']?.toString(),
      );
      if (dist < closestDist) {
        closestDist = dist;
        closestStop = stop;
      }
    }

    return closestStop;
  }

  // --- Off-Route Detection Logic ---

  // _loadRoutePaths is replaced by _syncDataWithRouteManager

  // --- Snap-to-Route Interpolation Helpers ---

  /// เลือก route path ตามสีรถและ PKY config (config-aware)
  List<LatLng>? _getRoutePathForBus(Bus bus) {
    final rId = bus.routeId.toLowerCase();
    final rColor = bus.routeColor.toLowerCase();

    // 1. ★ Dynamic: หาจาก RouteManagerService ก่อน (รองรับ shortName ภาษาไทย)
    final routeManager = RouteManagerService();
    BusRouteData? matchedRoute;
    for (var route in routeManager.allRoutes) {
      if (route.routeId.toLowerCase() == rId ||
          route.routeId.toLowerCase() == rColor ||
          route.shortName.toLowerCase() == rId ||
          route.shortName.toLowerCase() == rColor) {
        matchedRoute = route;
        break;
      }
    }

    if (matchedRoute != null) {
      // เช็คว่ามีหลาย variant มั้ย (เช่น หน้ามอ AM/PM)
      final variants = routeManager.allRoutes
          .where((r) => r.shortName == matchedRoute!.shortName)
          .toList();

      if (variants.length > 1) {
        // ★ S1 → ใช้ manager PKY config
        final targetId = isGreenPKYActive() ? 'S1-PM' : 'S1-AM';
        if (_routePaths.containsKey(targetId)) {
          return _routePaths[targetId];
        }
        // Fallback สำหรับสายอื่นที่มีหลาย variant
        for (var v in variants) {
          if (v.isActiveAt(DateTime.now()) &&
              _routePaths.containsKey(v.routeId)) {
            return _routePaths[v.routeId];
          }
        }
      }
      // สายเดียว → ใช้ routeId ตรงๆ
      if (_routePaths.containsKey(matchedRoute.routeId)) {
        return _routePaths[matchedRoute.routeId];
      }
    }

    // 2. Legacy: เช็คชื่อสีเก่า (backward compat)
    if (rId.contains('s1') ||
        rColor.contains('green') ||
        rColor.contains('เขียว')) {
      return isGreenPKYActive() ? _routePaths['S1-PM'] : _routePaths['S1-AM'];
    }

    // 3. ลองหาจาก routeId ตรงๆ (Firestore ID)
    if (_routePaths.containsKey(bus.routeId)) {
      return _routePaths[bus.routeId];
    }

    // 4. ลองหาจากชื่อที่ใกล้เคียง
    for (var key in _routePaths.keys) {
      if (rId.contains(key.toLowerCase()) || key.toLowerCase().contains(rId)) {
        return _routePaths[key];
      }
    }

    return null;
  }

  /// ฉายจุดพิกัด P ลงบนเส้นตรง A→B แล้วคืนจุดที่ใกล้ที่สุดบนเส้นนั้น
  LatLng _projectOntoSegment(LatLng p, LatLng a, LatLng b) {
    final dx = b.longitude - a.longitude;
    final dy = b.latitude - a.latitude;
    if (dx == 0 && dy == 0)
      return a; // เส้นตรงมีจุดเดียว (จุดเริ่ม = จุดสิ้นสุด)

    // คำนวณสัดส่วน t บนเส้น A→B แล้วจำกัดค่าให้อยู่ในช่วง [0, 1]
    final t =
        (((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) /
                (dx * dx + dy * dy))
            .clamp(0.0, 1.0);

    return LatLng(a.latitude + t * dy, a.longitude + t * dx);
  }

  /// ดึงตำแหน่งรถให้ตกลงบนเส้นทาง — คืน (จุดที่ snap, ระยะห่างเมตร, ลำดับเส้นตรง)
  /// ใช้การฉายตั้งฉากลงบนทุกเส้นตรงของเส้นทาง (polyline)
  ({LatLng snapped, double dist, int segIdx}) _snapToRoute(
    LatLng pos,
    List<LatLng> path,
  ) {
    const distance = Distance();
    LatLng closest = path.first;
    double minDist = double.infinity;
    int bestSeg = 0;

    // วนเช็คทุกเส้นตรง A→B ในเส้นทาง
    for (int i = 0; i < path.length - 1; i++) {
      final projected = _projectOntoSegment(pos, path[i], path[i + 1]);
      final d = distance.as(LengthUnit.Meter, pos, projected);
      if (d < minDist) {
        minDist = d;
        closest = projected;
        bestSeg = i;
      }
    }

    // กรณีเส้นทางมีจุดเดียว
    if (path.length == 1) {
      final d = distance.as(LengthUnit.Meter, pos, path.first);
      return (snapped: path.first, dist: d, segIdx: 0);
    }

    return (snapped: closest, dist: minDist, segIdx: bestSeg);
  }

  /// หาลำดับเส้นตรงที่จุดนี้อยู่ใกล้ที่สุดในเส้นทาง
  int _closestIndex(LatLng point, List<LatLng> path) {
    const distance = Distance();
    // ใช้การฉายลงเส้นตรงเพื่อหาลำดับที่แม่นยำ
    double minDist = double.infinity;
    int best = 0;
    for (int i = 0; i < path.length - 1; i++) {
      final projected = _projectOntoSegment(point, path[i], path[i + 1]);
      final d = distance.as(LengthUnit.Meter, point, projected);
      if (d < minDist) {
        minDist = d;
        best = i;
      }
    }
    return best;
  }

  /// สร้างจุดกลาง (intermediate points) ตาม polyline ให้มีระยะห่างสม่ำเสมอ
  /// เพื่อให้รถเคลื่อนที่ลื่นไหลเหมือนวิ่งจริง
  List<LatLng> _generateEvenPoints(
    List<LatLng> waypoints, {
    double spacingMeters = 5.0,
  }) {
    if (waypoints.length <= 1) return waypoints;

    const distance = Distance();
    final result = <LatLng>[waypoints.first];

    for (int i = 0; i < waypoints.length - 1; i++) {
      final a = waypoints[i];
      final b = waypoints[i + 1];
      final segDist = distance.as(LengthUnit.Meter, a, b);

      if (segDist <= spacingMeters) {
        // เส้นตรงสั้นกว่าระยะห่าง → เพิ่มจุดปลายเลย
        result.add(b);
        continue;
      }

      // แบ่งเส้นตรงเป็นจุดย่อยตามระยะห่างที่กำหนด
      final steps = (segDist / spacingMeters).ceil();
      for (int s = 1; s <= steps; s++) {
        final t = s / steps;
        result.add(
          LatLng(
            a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t,
          ),
        );
      }
    }

    return result;
  }

  /// เริ่ม smooth interpolation สำหรับรถ 1 คัน
  /// - ถ้าอยู่ในเส้นทาง: สร้างจุดกลางบน polyline แล้ว animate ตลอด ~2.8 วินาที
  /// - ถ้าออกนอกเส้นทาง: แสดง GPS จริงให้ผู้จัดการเห็นว่ารถหลุดไปตรงไหน
  void _interpolateAlongRoute(Bus bus) {
    // 1. ถ้าอยู่ในจุดพักรถ → ถือว่าปกติ (ไม่ Off-route)
    if (_isBusInRestStop(bus)) {
      if (_recentOffRoutes.containsKey(bus.id)) {
        _recentOffRoutes.remove(bus.id);
        notifyListeners();
      }
      // ยังคง update position ให้เห็นรถขยับในจุดพัก
      _displayedPositions[bus.id] = bus.position;
      notifyListeners();
      return;
    }

    final path = _getRoutePathForBus(bus);
    if (path == null || path.isEmpty) {
      // ไม่รู้เส้นทาง → แสดง GPS จริง
      _displayedPositions[bus.id] = bus.position;
      notifyListeners();
      return;
    }

    // Snap ตำแหน่ง GPS ลงบนเส้นทาง
    final snap = _snapToRoute(bus.position, path);

    // ตรวจสอบ Off-route (ห่างจากเส้นทางเกิน 50 เมตร)
    if (snap.dist > _offRouteThresholdMeters) {
      if (!_recentOffRoutes.containsKey(bus.id)) {
        _recentOffRoutes[bus.id] = true;
      }
      _interpTimers[bus.id]?.cancel();
      _displayedPositions[bus.id] = bus.position;
      notifyListeners();
      return;
    }

    // อยู่ในเส้นทาง → ล้างสถานะ Off-route
    if (_recentOffRoutes.containsKey(bus.id)) {
      _recentOffRoutes.remove(bus.id);
      _lastOffRouteAlert.remove(bus.id);
      _lastManagerPushAlert.remove(bus.id);
      notifyListeners();
    }

    // --- สร้างเส้นทางย่อยสำหรับ animate ---
    final prevDisplayed = _displayedPositions[bus.id] ?? snap.snapped;
    final fromIdx = _closestIndex(prevDisplayed, path);
    final toIdx = _closestIndex(snap.snapped, path);

    List<LatLng> rawWaypoints;
    if (fromIdx <= toIdx) {
      // เคลื่อนไปข้างหน้า → เอาจุดตั้งแต่ fromIdx ถึง toIdx
      rawWaypoints = [
        prevDisplayed,
        ...path.sublist(fromIdx + 1, toIdx + 1),
        snap.snapped,
      ];
    } else {
      // กรณีถอยหลังหรือข้ามรอบ → ไปตรงเลย
      rawWaypoints = [prevDisplayed, snap.snapped];
    }

    // ลบจุดซ้ำติดกัน
    final deduped = <LatLng>[rawWaypoints.first];
    for (int i = 1; i < rawWaypoints.length; i++) {
      if (rawWaypoints[i].latitude != rawWaypoints[i - 1].latitude ||
          rawWaypoints[i].longitude != rawWaypoints[i - 1].longitude) {
        deduped.add(rawWaypoints[i]);
      }
    }

    if (deduped.length <= 1) {
      _displayedPositions[bus.id] = snap.snapped;
      notifyListeners();
      return;
    }

    // สร้างจุดกลางให้สม่ำเสมอทุก ~5 เมตร เพื่อให้เคลื่อนที่ลื่นไหล
    final smoothPoints = _generateEvenPoints(deduped, spacingMeters: 5.0);

    // --- Animate ตลอด ~2.8 วินาที (รอ GPS รอบถัดไปที่มาทุก 3 วินาที) ---
    _interpTimers[bus.id]?.cancel();
    int step = 0;
    final totalDurationMs = 2800; // มิลลิวินาที
    final interval = (totalDurationMs / smoothPoints.length).round().clamp(
      16,
      200,
    );

    _interpTimers[bus.id] = Timer.periodic(Duration(milliseconds: interval), (
      timer,
    ) {
      if (step >= smoothPoints.length) {
        timer.cancel();
        return;
      }
      _displayedPositions[bus.id] = smoothPoints[step];
      step++;
      notifyListeners();
    });
  }

  bool _isBusInRestStop(Bus bus) {
    const distance = Distance();
    for (final zone in _restStopZones) {
      final center = LatLng(zone.location.latitude, zone.location.longitude);
      if (distance.as(LengthUnit.Meter, bus.position, center) <= zone.radius) {
        return true;
      }
    }
    return false;
  }

  Future<List<LatLng>> _parseGeoJsonToPoints(String assetPath) async {
    String data = await rootBundle.loadString(assetPath);
    var jsonResult = jsonDecode(data);
    List<LatLng> points = [];

    var features = jsonResult['features'] as List;
    for (var feature in features) {
      var geometry = feature['geometry'];
      if (geometry['type'] == 'LineString') {
        var coordinates = geometry['coordinates'] as List;
        for (var coord in coordinates) {
          points.add(LatLng(coord[1], coord[0]));
        }
      }
    }
    return points;
  }

  // To prevent spamming notifications, we track the last alert time per bus
  final Map<String, DateTime> _lastOffRouteAlert = {}; // For Driver
  final Map<String, DateTime> _lastManagerPushAlert = {}; // For Manager

  void _checkOffRouteStatus() {
    List<Map<String, dynamic>> offRouteBuses = [];

    for (var bus in _buses) {
      // 1. ถ้าอยู่ในจุดพักรถ -> ข้ามการเช็ค Off-route
      if (_isBusInRestStop(bus)) {
        // Clear alert history & off-route flag when in rest stop
        _recentOffRoutes.remove(bus.id);
        _lastOffRouteAlert.remove(bus.id);
        _lastManagerPushAlert.remove(bus.id);
        continue;
      }

      // 2. หา Route Path ของรถคันนี้ (Dynamic & Config-aware)
      final path = _getRoutePathForBus(bus);

      if (path != null && path.isNotEmpty) {
        // 3. หาจุดที่ใกล้ที่สุดบนเส้นทาง
        final snap = _snapToRoute(bus.position, path);

        // 4. ตรวจสอบระยะเบี่ยงเบน
        if (snap.dist > _offRouteThresholdMeters) {
          offRouteBuses.add({'bus': bus, 'dist': snap.dist});

          // ALSO Show Local Notification (Alert) - FOR DRIVER (own bus only)
          // Driver alerts: every 15 seconds for stimulus
          if (_isCurrentUserDriver(bus.driverName)) {
            final lastAlert = _lastOffRouteAlert[bus.id];
            if (lastAlert == null ||
                DateTime.now().difference(lastAlert).inSeconds >= 15) {
              _lastOffRouteAlert[bus.id] = DateTime.now();
              NotificationService.showNotification(
                id: bus.id.hashCode + 1000,
                title: "⚠️ คุณออกนอกเส้นทาง!",
                body:
                    "รถ ${bus.name} เบี่ยงออกจากเส้นทาง ${snap.dist.toStringAsFixed(0)} เมตร กรุณากลับเข้าเส้นทาง",
                payload: "off_route_driver_${bus.id}",
              );
              NotificationService.vibrateUrgent();
              debugPrint("📢 Off-route Alert sent to Driver: ${bus.name}");
            }
          } else {
            debugPrint(
              "💡 Bus ${bus.name} is Off-route but current user is NOT the assigned driver: ${bus.driverName}",
            );
          }
        } else {
          // On-route: Clear alert history
          _lastOffRouteAlert.remove(bus.id);
          _lastManagerPushAlert.remove(bus.id);
        }
      } else {
        // No path: Treat as on-route for alert purposes (or unknown)
        _lastOffRouteAlert.remove(bus.id);
        _lastManagerPushAlert.remove(bus.id);
      }
    }

    // Handle aggregated Manager Notification
    if (_isCurrentUserManager()) {
      _handleManagerOffRouteNotification(offRouteBuses);
    } else if (offRouteBuses.isNotEmpty) {
      debugPrint(
        "💡 Detected ${offRouteBuses.length} off-route buses, but current user is NOT a manager.",
      );
    }

    // Update local state for UI dropdown
    _currentOffRouteBuses = offRouteBuses;
    notifyListeners();
  }

  void _handleManagerOffRouteNotification(
    List<Map<String, dynamic>> offRouteBuses,
  ) {
    if (offRouteBuses.isEmpty) {
      _lastOffRouteBusIds.clear();
      return;
    }

    final now = DateTime.now();
    List<Map<String, dynamic>> busesToNotify = [];

    for (var item in offRouteBuses) {
      final bus = item['bus'] as Bus;
      final lastAlert = _lastManagerPushAlert[bus.id];

      // Notify if:
      // 1. First time seeing this bus off-route (lastAlert == null)
      // 2. Already off-route and 3 minutes have passed
      if (lastAlert == null || now.difference(lastAlert).inMinutes >= 3) {
        busesToNotify.add(item);
        _lastManagerPushAlert[bus.id] = now;
      }
    }

    if (busesToNotify.isEmpty) return;

    // Send push notification for the updated set of buses that need alerting
    String title;
    String body;

    if (offRouteBuses.length == 1) {
      final bus = offRouteBuses.first['bus'] as Bus;
      final dist = offRouteBuses.first['dist'] as double;
      title = "⚠️ แจ้งเตือนรถออกนอกเส้นทาง!";
      String driverInfo = bus.driverName.isNotEmpty
          ? " (คนขับ: ${bus.driverName})"
          : "";
      body =
          "รถ ${bus.name}$driverInfo (สาย ${bus.routeId}) เบี่ยงออกไป ${dist.toStringAsFixed(0)} เมตร";
    } else {
      title = "⚠️ แจ้งเตือนรถออกนอกเส้นทาง (${offRouteBuses.length} คัน)";
      final busNames = offRouteBuses
          .map((e) => (e['bus'] as Bus).name)
          .join(', ');
      body = "พบรถ ${offRouteBuses.length} คันมีปัญหา: $busNames";
    }

    NotificationService.showNotification(
      id: _aggregatedManagerAlertId,
      title: title,
      body: body,
      payload: "off_route_aggregation",
    );
    NotificationService.vibrate();

    // Log to Firestore (Throttle logs to once every minute per bus)
    for (var item in busesToNotify) {
      final bus = item['bus'] as Bus;
      final dist = item['dist'] as double;
      try {
        FirebaseFirestore.instance.collection('off_route_logs').add({
          'bus_id': bus.id,
          'bus_name': bus.name,
          'driver_name': bus.driverName,
          'route_id': bus.routeId,
          'deviation_meters': dist,
          'timestamp': FieldValue.serverTimestamp(),
          'status': 'off-route',
          'location': {
            'lat': bus.position.latitude,
            'lng': bus.position.longitude,
          },
        });
      } catch (e) {
        debugPrint("❌ Failed to log off-route event: $e");
      }
    }
  }

  bool _isCurrentUserManager() {
    final user = FirebaseAuth.instance.currentUser;
    // Sync with LoginPage emails
    const managerEmails = [
      'admin@upbus.com',
      'manager@upbus.com',
      'm@upbus.com',
    ];
    final isManager =
        user != null &&
        user.email != null &&
        managerEmails.contains(user.email.toString().toLowerCase().trim());

    if (user != null) {
      debugPrint("👤 Current user: ${user.email}, isManager: $isManager");
    }
    return isManager;
  }

  /// อัปเดต cached driver name (เรียกหลัง driver บันทึกชื่อใน change_route_page)
  void refreshDriverName(String name) {
    _cachedDriverName = name;
    debugPrint("🔄 [GlobalLocationService] Driver name refreshed: $name");
  }

  /// เช็คว่า driverName ตรงกับชื่อคนขับที่ล็อกอินอยู่ (เก็บใน SharedPreferences)
  bool _isCurrentUserDriver(String busDriverName) {
    if (busDriverName.isEmpty) return false;
    // ถ้ามี cache และตรงกัน → ใช่แน่นอน
    if (_cachedDriverName != null && _cachedDriverName == busDriverName) {
      return true;
    }
    // ถ้า cache ไม่ตรง → ลองโหลดใหม่ (เผื่อ driver เปลี่ยนชื่อ)
    SharedPreferences.getInstance().then((prefs) {
      _cachedDriverName = prefs.getString('saved_driver_name');
    });
    return false;
  }

  /// ปิด service (เรียกตอน dispose app)
  @override
  void dispose() {
    _busSubscription?.cancel();
    _positionSubscription?.cancel();
    _routeConfigSubscription?.cancel();
    super.dispose();
  }

  /// ตรวจสอบว่ารถบัสคันนี้ "ใช่" สายที่ต้องการหรือไม่ (Robust Matching)
  bool isBusMatchRoute(Bus bus, String target) {
    final t = target.trim().toLowerCase();
    final bId = bus.routeId.trim().toLowerCase();
    final bColor = bus.routeColor.trim().toLowerCase();

    // 1. Direct Matching
    if (bId.contains(t) || t.contains(bId)) return true;
    if (bColor.contains(t) || t.contains(bColor)) return true;

    // 2. Dynamic Matching via RouteManagerService
    //    เช็คว่า target shortName ตรงกับ routeId ของ route ที่ bus ใช้อยู่
    final routeManager = RouteManagerService();
    for (var route in routeManager.allRoutes) {
      final sn = route.shortName.toLowerCase();
      final rId = route.routeId.toLowerCase();
      // ถ้า target match กับ shortName หรือ routeId ของ route
      if (t == sn || t == rId || t.contains(sn) || sn.contains(t)) {
        // และ bus ก็ match กับ route เดียวกัน
        if (bId == rId || bColor == rId || bId == sn || bColor == sn) {
          return true;
        }
      }
    }

    // 3. Legacy Mapping S1 (Green)
    if (t.contains("s1") || t.contains("หน้ามอ")) {
      if (bId.contains("green") || bColor.contains("green")) return true;
      if (bColor.contains("เขียว")) return true;
    }

    // 4. Legacy Mapping S2 (Red)
    if (t.contains("s2") || t.contains("หอใน")) {
      if (bId.contains("red") || bColor.contains("red")) return true;
      if (bColor.contains("แดง")) return true;
    }

    // 5. Legacy Mapping S3 (Blue)
    if (t.contains("s3") || t.contains("ict")) {
      if (bId.contains("blue") || bColor.contains("blue")) return true;
      if (bColor.contains("น้ำเงิน")) return true;
    }

    return false;
  }
}

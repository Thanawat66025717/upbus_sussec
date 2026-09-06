import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Widget ที่แสดงไอคอนรถบัส 3D โดยเปลี่ยนสีตามเส้นทาง
///
/// ใช้ CustomPainter + saveLayer เพื่อ:
/// 1. วาดรูปรถเดิม (กำหนด alpha / shape ของรถ)
/// 2. วาดทับด้วย BlendMode.hue + srcATop → เปลี่ยนเฉพาะสี คง 3D
/// 3. ผลลัพธ์: สีสวยแบบ hue-shift + ไม่มีกรอบสี่เหลี่ยม
class ColoredBusIcon extends StatefulWidget {
  final Color color;
  final double size;

  const ColoredBusIcon({super.key, required this.color, this.size = 50});

  @override
  State<ColoredBusIcon> createState() => _ColoredBusIconState();
}

class _ColoredBusIconState extends State<ColoredBusIcon> {
  /// cache image แบบ static เพื่อไม่ต้องโหลดซ้ำทุกตัว
  static ui.Image? _cachedImage;
  static bool _loading = false;
  static final List<VoidCallback> _waiters = [];

  @override
  void initState() {
    super.initState();
    _ensureImageLoaded();
  }

  Future<void> _ensureImageLoaded() async {
    if (_cachedImage != null) return;
    if (_loading) {
      // รอตัวอื่นโหลดเสร็จแล้ว rebuild
      _waiters.add(() {
        if (mounted) setState(() {});
      });
      return;
    }
    _loading = true;
    try {
      final data = await rootBundle.load('assets/images/busiconall.png');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      _cachedImage = frame.image;
      // แจ้ง widget ทุกตัวที่รออยู่
      for (final cb in _waiters) {
        cb();
      }
      _waiters.clear();
    } finally {
      _loading = false;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_cachedImage == null) {
      // ระหว่างโหลด → แสดง placeholder เล็กๆ
      return SizedBox(width: widget.size, height: widget.size);
    }
    return CustomPaint(
      size: Size(widget.size, widget.size),
      painter: _BusIconPainter(_cachedImage!, widget.color),
    );
  }
}

/// CustomPainter ที่วาดรูปรถ 3D แล้วเปลี่ยนสีด้วย BlendMode.hue
/// โดยไม่มีกรอบสี่เหลี่ยม (ใช้ saveLayer + srcATop clipping)
class _BusIconPainter extends CustomPainter {
  final ui.Image image;
  final Color color;

  _BusIconPainter(this.image, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );

    // saveLayer เพื่อ composite ภายในกรอบนี้
    canvas.saveLayer(dst, Paint());

    // Step 1: วาดรูปเดิม → กำหนด alpha shape ของรถ
    canvas.drawImageRect(image, src, dst, Paint());

    // Step 2: วาดทับด้วย hue-shifted + srcATop
    //   srcATop = วาดเฉพาะตรงที่ destination มี alpha (ตัวรถ)
    //   colorFilter = เปลี่ยน hue คง saturation+luminance (3D detail)
    final paint = Paint()
      ..blendMode = BlendMode.srcATop
      ..colorFilter = ColorFilter.mode(color, BlendMode.hue);
    canvas.drawImageRect(image, src, dst, paint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_BusIconPainter old) =>
      old.color != color || old.image != image;
}

/// ตั้งค่า tile ของแผนที่ที่ใช้ร่วมกันทั้งแอป (ทุกหน้าที่มี flutter_map)
///
/// เดิมทุกหน้าใช้ URL ของ CARTO (basemaps.cartocdn.com) ตรงๆ แยกกันคนละไฟล์
/// แต่ CARTO เปลี่ยนนโยบายให้ endpoint นี้ต้องมี API key แล้ว ทำให้แผนที่ขึ้นข้อความ
/// "API KEY REQUIRED" ทับเต็มหน้าจอแทนที่จะเป็นแผนที่จริง จึงเปลี่ยนมาใช้
/// OpenStreetMap มาตรฐานซึ่งยังไม่ต้องใช้ API key และรวมค่านี้ไว้ที่เดียว
/// เพื่อไม่ให้ต้องแก้ 8 ไฟล์แยกกันถ้าต้องเปลี่ยนผู้ให้บริการแผนที่อีกในอนาคต
class MapConfig {
  static const String tileUrlTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String userAgentPackageName = 'com.upbus.app';
}

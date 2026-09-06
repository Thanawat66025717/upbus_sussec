/// รายชื่ออีเมลของแต่ละบทบาทในระบบ (manager/editor/driver)
///
/// เดิมแต่ละหน้า (login_page.dart, sidemenu.dart) ประกาศรายชื่อเหล่านี้แยกกัน
/// ทำให้รายชื่อเพี้ยนไม่ตรงกันได้ (เช่น ผู้ใช้ถูกพาไปหน้าผู้โดยสารตอน login
/// แต่กลับเห็นเมนูคนขับใน side menu) จึงรวมไว้ที่เดียวเพื่อให้ทุกจุดใช้ค่าเดียวกันเสมอ
class AppRoles {
  static const List<String> managerEmails = ['admin@upbus.com', 'manager@upbus.com'];
  static const List<String> editorEmails = ['editor@upbus.com'];
  static const List<String> driverEmails = ['driver@upbus.com', 'thanawatj3@gmail.com'];
}

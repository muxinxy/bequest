/// 输入校验工具:邮箱/手机号格式校验。
/// 与后端校验一致(邮箱含 @ 且有点,手机号 5-20 位数字)。
library;

final RegExp _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
final RegExp _phoneRe = RegExp(r'^\d{5,20}$');

/// 邮箱格式是否合法。
bool isValidEmail(String value) => _emailRe.hasMatch(value.trim());

/// 手机号格式是否合法(5-20 位数字)。
bool isValidPhone(String value) => _phoneRe.hasMatch(value.trim());
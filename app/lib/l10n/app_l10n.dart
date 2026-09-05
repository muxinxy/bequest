import 'dart:ui';

import 'en_pages_account.dart';
import 'en_pages_asset.dart';
import 'en_pages_inherit.dart';
import 'en_pages_misc.dart';
import 'en_pages_sync.dart';

/// Lightweight localization for bequest.
///
/// The app's UI strings were historically written inline in Simplified
/// Chinese. To add English support without a full gen-l10n migration of every
/// page at once, [L10n.tr] resolves a Chinese source string through the
/// active locale's dictionary: when the locale is English the string is
/// translated via [en]; otherwise (Chinese, unknown) it passes through
/// unchanged. This keeps Chinese as the guaranteed-complete source of truth:
/// an untranslated string degrades gracefully to Chinese rather than to a
/// missing key error.
///
/// Pages that need parameter interpolation use [L10n.trp] with {name} style
/// placeholders (matching the server template style).
class L10n {
  L10n._();

  /// Current app locale (kept in sync with MaterialApp's locale).
  static Locale locale = const Locale('zh');

  static bool get isZh => locale.languageCode == 'zh';

  /// All dictionary fragments merged (module files add their own entries).
  static Map<String, String> get en =>
      {..._core, ...enPagesAccount, ...enPagesAsset, ...enPagesInherit, ...enPagesMisc, ...enPagesSync};

  /// Resolve a Chinese source string for the active locale.
  static String tr(String zh) {
    if (isZh) return zh;
    return en[zh] ?? zh;
  }

  /// Resolve a string that contains {name} placeholders and substitute args.
  static String trp(String zh, [Map<String, String>? args]) {
    var s = tr(zh);
    if (args != null) {
      for (final e in args.entries) {
        s = s.replaceAll('{${e.key}}', e.value);
      }
    }
    return s;
  }

  /// Core/common dictionary (always loaded). Page modules live in the
  /// en_pages_*.dart files imported above.
  static const Map<String, String> _core = {
    // ---- app / common ----
    '托孤': 'Bequest',
    '设置': 'Settings',
    '主题': 'Theme',
    '语言': 'Language',
    '简体中文': '简体中文',
    'English': 'English',
    '取消': 'Cancel',
    '确定': 'OK',
    '保存': 'Save',
    '删除': 'Delete',
    '关闭': 'Close',
    '返回': 'Back',
    '确认': 'Confirm',
    '下一步': 'Next',
    '完成': 'Done',
    '重试': 'Retry',
    '全部': 'All',
    '暂无数据': 'No data',
    '加载中': 'Loading',
    '加载失败': 'Load failed',
    '请求失败': 'Request failed',
    '请求失败({code})': 'Request failed ({code})',
    '操作成功': 'Success',
    '操作失败': 'Operation failed',
    '读取文件失败': 'Failed to read file',
    '错误': 'Error',
    '提示': 'Notice',
    '警告': 'Warning',
    '信息': 'Info',
    '关于': 'About',
    '关于本应用': 'About this app',
    '退出登录': 'Log out',
    '账号': 'Account',
    '用户名': 'Username',
    '邮箱': 'Email',
    '密码': 'Password',
    '验证码': 'Captcha',
    '登录': 'Log in',
    '注册': 'Sign up',
    '退出': 'Exit',
    '请输入用户名': 'Please enter username',
    '请输入密码': 'Please enter password',
    '请输入邮箱': 'Please enter email',
    '登录中': 'Logging in',
    '注册中': 'Signing up',
    // ---- sections used across pages ----
    '数据': 'Data',
    '提醒': 'Reminders',
    '账户与安全': 'Account & Security',
    '外观': 'Appearance',
    '存储与服务器': 'Storage & Server',
    '通知渠道': 'Notification channels',
    '跟随系统': 'Follow system',
    '浅色': 'Light',
    '深色': 'Dark',
    '锁定': 'Lock',
    '解锁': 'Unlock',
    // ---- settings page menu ----
    '导入资产': 'Import assets',
    '导出资产': 'Export assets',
    '提醒模板': 'Reminder templates',
    '触发阶梯': 'Trigger ladders',
    '继承': 'Inheritance',
    '继承人': 'Inheritors',
    '账号信息': 'Account info',
    '修改主密码': 'Change master password',
    '重置主密码(忘记)': 'Reset master password (forgot)',
    '邮箱发件设置': 'Email (SMTP) settings',
    '操作记录': 'Activity log',
    '服务器地址': 'Server address',
    '同步设置': 'Sync settings',
    '暂无资产可导出': 'No assets to export',
    'JSON(可加密)': 'JSON (encryptable)',
    '通用格式,可再导入': 'Universal format, importable later',
    'Excel 表格': 'Excel spreadsheet',
    '表格查看,适合打印分享': 'Tabular view, good for printing/sharing',
    '会员权益,升级后可用': 'Member benefit, upgrade to unlock',
    'Excel 导出为会员权益,请联系管理员开通会员':
        'Excel export is a member benefit; contact the administrator to enable membership',
    '不加密': 'No encryption',
    '加密': 'Encrypt',
    '追加': 'Append',
    '覆盖': 'Overwrite',
    'JSON / 加密导出文件': 'JSON / encrypted export files',
    '是否用主密码加密导出文件?\n加密后文件无法直接查看,导入时需验证主密码。':
        'Encrypt the exported file with your master password?\nAn encrypted file cannot be viewed directly; importing requires the master password.',
    '是否覆盖现有资产?\n覆盖会先删除当前全部资产再导入(不可恢复)。选择"否"则追加导入。':
        'Overwrite existing assets?\nOverwrite deletes all current assets first, then imports (not recoverable). Choose "No" to append instead.',
    // ---- login / register / recovery ----
    '数字资产安全传承': 'Secure digital asset succession',
    '用户名/邮箱': 'Username / Email',
    '请输入用户名或邮箱': 'Please enter username or email',
    '输入图形验证码': 'Enter the captcha',
    '请输入验证码': 'Please enter the captcha',
    '加载失败,点此重试': 'Failed to load, tap to retry',
    '还没有账号?去注册': 'No account yet? Sign up',
    '忘记密码': 'Forgot password',
    '进入本地模式': 'Enter local mode',
    '服务器设置': 'Server settings',
    '无法连接服务器,请检查网络或服务器地址': 'Cannot reach server, check your network or server address',
    '未恢复加密密钥,请重新登录重试': 'Encryption key not recovered, please log in again',
    '登录失败,请检查网络后重试': 'Login failed, please check your network and retry',
    '恢复加密密钥': 'Recover encryption key',
    '此设备首次登录,请输入主密码恢复本机加密密钥(资产凭据不受影响)。':
        'This device is logging in for the first time. Enter your master password to recover the local encryption key (asset credentials are not affected).',
    '主密码': 'Master password',
    '账户密码(用于更新继承交接密钥)': 'Account password (used to update inheritance handover keys)',
    '忘记主密码?去重置': 'Forgot master password? Reset it',
    '请输入主密码': 'Please enter your master password',
    '恢复': 'Recover',
    '主密码不能与登录密码相同': 'Master password cannot be the same as the login password',
    '注册失败,请检查网络后重试': 'Sign-up failed, please check your network and retry',
    '3-20 位,字母/数字/下划线': '3-20 characters: letters, digits, underscore',
    '用户名需 3-20 位字母/数字/下划线': 'Username must be 3-20 letters/digits/underscores',
    '用户名已被占用': 'Username already taken',
    '邮箱格式不正确': 'Invalid email format',
    '邮箱已被注册': 'Email already registered',
    '登录密码': 'Login password',
    '至少 8 位;用于登录账号': 'At least 8 characters; used to log in',
    '密码至少 8 位': 'Password must be at least 8 characters',
    '确认登录密码': 'Confirm login password',
    '两次输入的密码不一致': 'The two passwords do not match',
    '用于加密资产数据,务必牢记;不能与登录密码相同':
        'Encrypts your asset data. Keep it safe; it cannot be the same as the login password',
    '主密码至少 8 位': 'Master password must be at least 8 characters',
    '确认主密码': 'Confirm master password',
    '两次输入的主密码不一致': 'The two master passwords do not match',
    '主密码提示语(可选)': 'Master password hint (optional)',
    '忘记主密码时帮助回忆,不暴露密码本身': 'Helps you recall the master password without revealing it',
    // ---- home page ----
    '服务器连接失败,已加载本地缓存(仅可查看/导出)':
        'Server unreachable; loaded local cache (view/export only)',
    '加载失败,本地数据读取异常': 'Load failed: error reading local data',
    '加载失败,请检查网络后重试': 'Load failed, please check your network and retry',
    '服务器已恢复,数据已更新为最新': 'Server is back; data updated to the latest',
    '未登录,无法刷新': 'Not logged in, cannot refresh',
    '数据已刷新为最新': 'Data refreshed to the latest',
    '刷新失败,服务器仍不可达': 'Refresh failed, server still unreachable',
    '是否保留本机加密密钥?\n\n保留:下次登录免恢复,本机加密数据仍可离线读取。\n清除:适用于公共电脑,下次登录需重新恢复密钥。':
        'Keep the local encryption key?\n\nKeep: no recovery needed at next login; local encrypted data stays readable offline.\nClear: for shared/public computers; the key must be recovered again at next login.',
    '保留密钥': 'Keep key',
    '清除密钥': 'Clear key',
    '退出本地模式': 'Exit local mode',
    '未分组': 'Ungrouped',
    '新增': 'Add',
    '新增资产': 'Add asset',
    '默认未分组': 'Default: ungrouped',
    '新增分组': 'Add group',
    '分组名称': 'Group name',
    '分组已存在': 'Group already exists',
    '新增分组失败,请检查网络后重试': 'Failed to create group, please check your network and retry',
    '删除分组': 'Delete group',
    '确定删除所选 {n} 个分组?分组内资产将变为未分组。':
        'Delete the selected {n} groups? Assets in them will become ungrouped.',
    '删除失败,请检查网络后重试': 'Delete failed, please check your network and retry',
    '未登录,无法设置继承人': 'Not logged in, cannot set inheritors',
    '离线,显示缓存继承人(绑定需联网)': 'Offline, showing cached inheritors (binding requires network)',
    '加载继承人失败,请检查网络后重试': 'Failed to load inheritors, please check your network and retry',
    '暂无继承人,请先在设置中创建': 'No inheritors yet, create some in Settings first',
    '设置继承人': 'Set inheritors',
    '绑定': 'Bind',
    '请至少选择一名继承人': 'Select at least one inheritor',
    '绑定失败': 'Bind failed',
    '已为 {n} 个分组设置 {m} 名继承人': 'Set {m} inheritors for {n} groups',
    '会员': 'Member',
    '免费': 'Free',
    '已选 {n} 项': '{n} selected',
    '总览': 'Overview',
    '回收站': 'Recycle Bin',
    '清空': 'Clear',
    '排序': 'Sort',
    '添加': 'Add',
    '离线模式:服务器不可达,已加载本地缓存,仅可查看与导出':
        'Offline mode: server unreachable, loaded local cache; view and export only',
    '刷新': 'Refresh',
    '搜索分组或资产名称': 'Search groups or asset names',
    '欢迎使用托孤': 'Welcome to Bequest',
    '没有匹配的分组': 'No matching groups',
    '点击右下角 + 创建你的第一个分组,或直接添加资产':
        'Tap the + at the bottom right to create your first group, or add an asset',
    '点击右下角 + 新增分组': 'Tap the + at the bottom right to add a group',
    '分组排序': 'Sort groups',
    '按名称': 'By name',
    '名称': 'Name',
    '按数量': 'By count',
    '数量': 'Count',
    '按创建时间': 'By creation time',
    '创建时间': 'Created time',
    '{n} 个资产': '{n} assets',
    '{n} 个分组': '{n} groups',
    '继承人:{names}': 'Inheritors: {names}',
    // ---- app lock screen ----
    '设备未录入指纹或人脸,请先在系统设置中添加':
        'No fingerprint or face enrolled, add one in system settings first',
    '请验证生物识别以解锁': 'Verify your biometrics to unlock',
    '未录入指纹/人脸,请在系统设置中添加': 'No fingerprint/face enrolled, add one in system settings',
    '设备不支持生物识别': 'This device does not support biometrics',
    '尝试次数过多,系统已暂时锁定生物识别,请稍后再试或用其他方式解锁':
        'Too many attempts; the system has temporarily locked biometrics. Try again later or use another method',
    '生物识别已被系统永久锁定,请用其他方式解锁':
        'Biometrics have been permanently locked by the system, please use another method',
    '生物识别验证失败,请重试或用其他方式解锁':
        'Biometric verification failed, please retry or use another method',
    'PIN 码错误,请重试': 'Wrong PIN, please try again',
    '解锁失败,请重试': 'Unlock failed, please try again',
    '图案错误,请重试': 'Wrong pattern, please try again',
    '主密码错误,请重试': 'Wrong master password, please try again',
    '应用已锁定': 'App locked',
    '请绘制图案解锁': 'Draw your pattern to unlock',
    '请输入 PIN 码解锁': 'Enter your PIN to unlock',
    '请输入主密码解锁': 'Enter your master password to unlock',
    '主密码提示: {hint}': 'Master password hint: {hint}',
    '尝试次数过多,请等待 {n} 秒后重试': 'Too many attempts, please wait {n}s and retry',
    '生物识别解锁': 'Unlock with biometrics',
    '用主密码解锁': 'Unlock with master password',
    '主密码尝试次数过多,请等待 {n} 秒后重试':
        'Too many master password attempts, please wait {n}s and retry',
    '跳过(退出登录)': 'Skip (log out)',
    '跳过(退出本地模式)': 'Skip (exit local mode)',
    // ---- app lock setup page ----
    '应用锁': 'App lock',
    '启用应用锁': 'Enable app lock',
    '锁定后需解锁方式验证': 'Locks the app and requires verification to unlock',
    '关闭后进入应用不锁定': 'App will not lock when turned off',
    '开启后需设置至少一种解锁方式(PIN 或图案)。':
        'When enabled, set at least one unlock method (PIN or pattern).',
    '锁定时机': 'When to lock',
    '退出时锁定': 'Lock on exit',
    '应用进入后台立即锁定': 'Locks as soon as the app goes to background',
    '退出且超时锁定': 'Lock on exit after a timeout',
    '进入后台超过设定时间后锁定,期间回到前台不锁':
        'Locks after the app stays in background past the set time; returning earlier does not lock it',
    '超时时间(分钟)': 'Timeout (minutes)',
    '使用生物识别解锁': 'Use biometrics to unlock',
    '当前设备未检测到生物识别': 'No biometrics detected on this device',
    '系统弹窗由设备统一管理,会自动选择可用的人脸或指纹验证方式':
        'System dialogs are managed by the device and will automatically pick the available face or fingerprint verification',
    '指纹': 'Fingerprint',
    '人脸': 'Face',
    '指纹(强)': 'Fingerprint (strong)',
    '弱生物识别': 'Weak biometrics',
    '当前设备支持: {labels}': 'Supported on this device: {labels}',
    '当前设备不支持生物识别,保存后将自动关闭':
        'This device does not support biometrics; it will be turned off after saving',
    '修改 PIN 码(可选)': 'Change PIN (optional)',
    'PIN 码': 'PIN',
    '4-6 位数字,用于解锁应用;留空表示不改动':
        '4-6 digits, used to unlock the app; leave blank to keep the current one',
    '确认 PIN 码': 'Confirm PIN',
    'PIN 码需为 4-6 位数字': 'PIN must be 4-6 digits',
    '两次输入的 PIN 码不一致': 'The two PINs do not match',
    '设置图案解锁': 'Set up pattern unlock',
    '图案解锁已设置': 'Pattern unlock enabled',
    '重新设置': 'Reset',
    '清除图案': 'Clear pattern',
    '应用锁已关闭': 'App lock turned off',
    '应用锁已启用': 'App lock enabled',
    '保存失败,请重试': 'Save failed, please retry',
    '超时时间需为 1-60 分钟': 'Timeout must be 1-60 minutes',
    '请至少设置一种解锁方式(PIN 或图案)': 'Set at least one unlock method (PIN or pattern)',
    '至少连接 4 个点,请重试': 'Connect at least 4 dots, please retry',
    '两次图案不一致,请重新绘制': 'The two patterns do not match, please redraw',
    '绘制图案': 'Draw a pattern',
    '再次绘制确认': 'Draw again to confirm',
    // ---- about page ----
    '链接已复制到剪贴板': 'Link copied to clipboard',
    '已导出 {n} 条日志': 'Exported {n} log entries',
    '导出日志失败': 'Failed to export logs',
    '暂无日志': 'No logs',
    '清空日志': 'Clear logs',
    '确定要清空本地调试日志吗?此操作不可撤销。':
        'Clear all local debug logs? This cannot be undone.',
    '日志已清空': 'Logs cleared',
    '应用版本': 'App version',
    '构建版本': 'Build version',
    '包名': 'Package name',
    '简介': 'About',
    '数字资产保险箱 + 数字遗嘱。端到端加密,自托管同步,继承交接。您的资产信息只属于您自己。':
        'A digital asset vault plus a digital will. End-to-end encryption, self-hosted sync, and inheritance handover. Your asset information belongs only to you.',
    '复制链接': 'Copy link',
    '导出日志': 'Export logs',
    '托孤日志导出(CSV)': 'Bequest log export (CSV)',
    '托孤调试日志': 'Bequest debug logs',
    // ---- crypto / repository error messages (surfaced by UI) ----
    '密文数据格式错误': 'Invalid ciphertext format',
    '未找到当前主密钥,无法修改': 'Current master key not found, cannot modify',
    '主密码错误': 'Wrong master password',
    '分类不存在(id: {id})': 'Category does not exist (id: {id})',
    '资产不存在(id: {id})': 'Asset does not exist (id: {id})',
    '目标分类不存在': 'Target category does not exist',
    '本地模式不支持资产级继承人设置':
        'Local mode does not support asset-level inheritor settings',
    '本地模式不支持分组级继承人设置':
        'Local mode does not support group-level inheritor settings',
  };
}

// English dictionary fragment (module: account). Populated by the page-conversion agents.
const Map<String, String> enPagesAccount = {
  // ---- account_settings_page ----
  '账号信息': 'Account info',
  '用户名和邮箱不能为空': 'Username and email cannot be empty',
  '邮箱格式不正确': 'Invalid email format',
  '已保存': 'Saved',
  '用户名或邮箱已被占用': 'Username or email already taken',
  '保存失败,请检查网络后重试': 'Save failed, please check your network and retry',
  '密码已修改,请重新登录': 'Password changed, please log in again',
  '当前密码错误': 'Incorrect current password',
  '修改失败,请检查网络后重试': 'Change failed, please check your network and retry',
  '3-20 位字母/数字/下划线,登录时可用':
      '3-20 letters/digits/underscores, usable for login',
  '登录与找回密码使用': 'Used for login and password recovery',
  '保存中...': 'Saving...',
  '修改登录密码': 'Change login password',
  '修改后所有已登录设备将退出,需重新登录':
      'All signed-in devices will be logged out after the change; you will need to log in again',
  '当前密码': 'Current password',
  '请输入当前密码': 'Please enter your current password',
  '新密码': 'New password',
  '至少 8 位': 'At least 8 characters',
  '新密码至少 8 位': 'New password must be at least 8 characters',
  '确认新密码': 'Confirm new password',
  '两次输入的新密码不一致': 'The two new passwords do not match',
  '修改中...': 'Changing...',
  '确认修改密码': 'Confirm password change',
  // ---- change_master_password_page ----
  '修改主密码': 'Change master password',
  '主密码提示语已更新': 'Master password hint updated',
  '已更新本地主密码': 'Local master password updated',
  '云端同步失败,本地已更新': 'Cloud sync failed; local already updated',
  '云端已同步': 'Cloud synced',
  '账户密码错误,云端继承密钥未更新':
      'Incorrect account password; cloud inheritance keys not updated',
  '当前主密码': 'Current master password',
  '请输入当前主密码': 'Please enter your current master password',
  '新主密码(留空则不修改)': 'New master password (leave blank to keep current)',
  '留空仅更新提示语;填写则至少 8 位':
      'Leave blank to only update the hint; otherwise at least 8 characters',
  '新主密码至少 8 位': 'New master password must be at least 8 characters',
  '新主密码不能与当前相同':
      'New master password cannot be the same as the current one',
  '确认新主密码': 'Confirm new master password',
  '两次输入的新主密码不一致': 'The two new master passwords do not match',
  '主密码提示语(可选)': 'Master password hint (optional)',
  '帮助回忆的提示,仅保存在本机':
      'A hint to help you remember; stored only on this device',
  '账户密码': 'Account password',
  '用于同步云端继承密钥': 'Used to sync cloud inheritance keys',
  '请输入账户密码以同步云端':
      'Please enter your account password to sync to the cloud',
  '未登录,云端继承密钥不会更新':
      'Not logged in; cloud inheritance keys will not be updated',
  '确认修改': 'Confirm change',
  // ---- reset_master_password_page ----
  '重置主密码': 'Reset master password',
  '确认重置主密码?': 'Reset the master password?',
  '重置后将无法解密现有的资产凭据与备注(端到端加密),'
      '资产将保留名称/分组,凭据需重新填写。此操作不可撤销。':
      'After the reset, existing asset credentials and notes cannot be decrypted '
      '(end-to-end encryption). Assets keep their names/groups, but credentials '
      'must be re-entered. This cannot be undone.',
  '将影响 {count} 条资产:重置后无法解密其凭据与备注(端到端加密),'
      '资产将保留名称/分组,凭据需重新填写。此操作不可撤销。':
      'This affects {count} asset(s): after the reset their credentials and notes '
      'cannot be decrypted (end-to-end encryption). Assets keep their '
      'names/groups, but credentials must be re-entered. This cannot be undone.',
  '确认重置': 'Confirm reset',
  '取消': 'Cancel',
  '本地模式无账户密码,无法重置主密码(请重新设置本地库)':
      'Local mode has no account password, so the master password cannot be reset '
      '(please recreate the local vault)',
  '重置失败': 'Reset failed',
  '主密码已重置': 'Master password reset',
  '账户密码错误': 'Incorrect account password',
  '重置失败,请检查网络后重试': 'Reset failed, please check your network and retry',
  '如果还记得当前主密码,建议用「修改主密码」——数据不丢失。':
      'If you still remember your current master password, use "Change master '
      'password" instead — no data is lost.',
  '去修改': 'Change it',
  '忘记主密码时,用账户密码重置。'
      '端到端加密意味着旧数据不可恢复:重置后资产保留名称/分组,'
      '凭据与备注清空,需重新填写。':
      'If you forgot the master password, reset it with your account password. '
      'End-to-end encryption means old data cannot be recovered: assets keep '
      'their names/groups, but credentials and notes are cleared and must be '
      're-entered.',
  '请输入账户密码': 'Please enter your account password',
  '新主密码': 'New master password',
  '至少 8 位,用于加密本地数据': 'At least 8 characters; used to encrypt local data',
  '两次输入不一致': 'The two entries do not match',
  '重置中...': 'Resetting...',
  // ---- forgot_password_page ----
  '重置密码': 'Reset password',
  '请输入正确的邮箱': 'Please enter a valid email address',
  '验证码已发送到邮箱(10 分钟内有效)':
      'A code was sent to your email (valid for 10 minutes)',
  '发送失败,请检查网络后重试': 'Failed to send, please check your network and retry',
  '发送中...': 'Sending...',
  '重新发送({seconds} s)': 'Resend ({seconds}s)',
  '发送验证码': 'Send code',
  '两次输入的密码不一致': 'The two passwords do not match',
  '密码已重置,请用新密码登录': 'Password reset, please log in with the new password',
  '注册邮箱': 'Registration email',
  '验证码': 'Captcha',
  '新密码(至少 8 位)': 'New password (at least 8 characters)',
  // ---- notification_channels_page ----
  '通知渠道': 'Notification channels',
  '加载失败,请检查网络后重试': 'Load failed, please check your network and retry',
  '{label} webhook 地址需为 https:// 开头且含平台域名':
      '{label} webhook URL must start with https:// and contain the platform domain',
  '手机号格式不正确(5-20 位数字)': 'Invalid phone number (5-20 digits)',
  '手机号功能为会员专属': 'Phone notifications are a member benefit',
  '企业微信': 'WeCom',
  '钉钉': 'DingTalk',
  '飞书': 'Feishu',
  '邮箱': 'Email',
  '未设置邮箱时默认使用注册邮箱':
      'When no email is set, your registration email is used by default',
  '手机号': 'Phone number',
  '最多 3 个,用于短信提醒': 'Up to 3, used for SMS reminders',
  '会员专属,升级后可用': 'Member-only, available after upgrading',
  '企业微信群机器人': 'WeCom group bot',
  '在企业微信建群 → 群机器人 → 复制 webhook 地址':
      'In WeCom: create a group → add a group bot → copy the webhook URL',
  '钉钉机器人': 'DingTalk bot',
  '在钉钉群添加自定义机器人 → 复制 webhook 地址':
      'In DingTalk: add a custom bot to a group → copy the webhook URL',
  '飞书机器人': 'Feishu bot',
  '在飞书群添加自定义机器人 → 复制 webhook 地址':
      'In Feishu: add a custom bot to a group → copy the webhook URL',
  '会员专属': 'Member-only',
  '添加{title}': 'Add {title}',
  '删除': 'Delete',
  // ---- membership_page ----
  '会员': 'Member',
  '兑换': 'Redeem',
  '已到期': 'Expired',
  '{days} 天': '{days} days',
  '{hours} 小时': '{hours} hours',
  '{minutes} 分钟': '{minutes} minutes',
  '用户名': 'Username',
  '到期时间': 'Expires on',
  '永久': 'Permanent',
  '剩余时长': 'Time remaining',
  '永久有效': 'Permanent',
  '资产数量': 'Asset count',
  '{limit} 条': '{limit} items',
  '不限': 'Unlimited',
  '云端同步': 'Cloud sync',
  '继承交接': 'Inheritance handover',
  '邮件+IM': 'Email+IM',
  '邮件+IM+短信': 'Email+IM+SMS',
  '自定义提醒模板': 'Custom reminder templates',
  'Excel 导出': 'Excel export',
  '离线模式': 'Offline mode',
  '权益': 'Benefit',
  '免费': 'Free',
  '本月通知用量': 'Notification usage this month',
  '邮件': 'Email',
  '短信': 'SMS',
  '已用 {used} / {limit}': 'Used {used} / {limit}',
  '请先登录': 'Please log in first',
  '兑换码格式不正确': 'Invalid redeem code format',
  '兑换成功': 'Redeemed successfully',
  '兑换失败,请检查网络': 'Redeem failed, please check your network',
  '兑换会员': 'Redeem membership',
  '兑换码': 'Redeem code',
  // ---- smtp_settings_page ----
  '邮箱发件设置': 'Email sending settings',
  '登录状态已失效,请重新登录': 'Your session has expired, please log in again',
  '清除发件设置': 'Clear mail settings',
  '确定清除自定义 SMTP 设置吗?之后将恢复使用托孤服务端发送。':
      'Clear the custom SMTP settings? Email will be sent through the Bequest '
      'server again.',
  '清除': 'Clear',
  '已清除发件设置': 'Mail settings cleared',
  '清除失败,请检查网络后重试': 'Clear failed, please check your network and retry',
  '提醒邮件将优先使用您自己的邮箱发送,不经过托孤服务端'
      '(服务端仅加密保存凭据)。':
      'Reminder emails will preferably be sent from your own mailbox, not through '
      'the Bequest server (the server only stores the credentials encrypted).',
  '服务器': 'Server',
  '端口': 'Port',
  '密码': 'Password',
  '留空表示保持现有密码': 'Leave blank to keep the current password',
  '发件地址': 'From address',
  '启用': 'Enable',
  '启用自定义邮箱发送提醒邮件': 'Send reminder emails from your custom mailbox',
  '清除设置': 'Clear settings',
  // ---- server_settings_page ----
  '服务器设置': 'Server settings',
  '请输入服务器地址': 'Please enter a server address',
  '无法连接服务器,请检查地址': 'Cannot reach the server, please check the address',
  '服务器地址': 'Server address',
  '保存': 'Save',
  // ---- local_unlock_page ----
  '进入本地模式': 'Enter local mode',
  '创建本地账户失败,请重试': 'Failed to create the local account, please retry',
  '账户数据缺失,请删除后重建': 'Account data missing, please delete and recreate it',
  '主密码错误,请重试': 'Wrong master password, please try again',
  '验证失败,请重试': 'Verification failed, please retry',
  '删除本地账户「{name}」?': 'Delete local account "{name}"?',
  '该账户的本地数据将被移除(不可恢复)。':
      'This account\'s local data will be removed (cannot be recovered).',
  '重命名账户': 'Rename account',
  '账户名称': 'Account name',
  '名称已被其他账户使用': 'This name is already used by another account',
  '选择本地账户': 'Select a local account',
  '重命名': 'Rename',
  '删除账户': 'Delete account',
  '新建本地账户': 'Create local account',
  '从备份恢复(需主密码)': 'Restore from backup (master password required)',
  '验证「{name}」主密码': 'Verify master password for "{name}"',
  '本地数据由主密码加密,验证后进入':
      'Local data is encrypted with your master password; verify to enter',
  '主密码提示: {hint}': 'Master password hint: {hint}',
  '主密码': 'Master password',
  '进入': 'Enter',
  '返回账户列表': 'Back to account list',
  '本地模式无需登录,数据加密保存在本机;可创建多个账户':
      'Local mode needs no login; data is encrypted and stored on this device. '
      'You can create multiple accounts',
  '如:张三 / 家人共用的保险箱': 'e.g. Zhang San / a vault shared by family',
  '请输入账户名称': 'Please enter an account name',
  '主密码至少 8 位': 'Master password must be at least 8 characters',
  '确认主密码': 'Confirm master password',
  '两次输入的主密码不一致': 'The two master passwords do not match',
  '创建并进入': 'Create and enter',
};

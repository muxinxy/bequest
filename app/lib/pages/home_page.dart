import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../storage/secure_store.dart';
import 'login_page.dart';

/// 主页:展示当前登录用户,提供退出登录。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _api = ApiClient();
  final _store = SecureStore();

  String? _username;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) {
        await _logout();
        return;
      }
      final me = await _api.me(jwt);
      if (!mounted) return;
      setState(() {
        _username =
            (me['username'] ?? me['user']?['username'])?.toString() ?? '用户';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('获取用户信息失败,请重新登录')),
      );
      await _logout();
    }
  }

  Future<void> _logout() async {
    await _store.clearAll();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('托孤'),
        actions: [
          TextButton(
            onPressed: _logout,
            child: const Text('退出登录'),
          ),
        ],
      ),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.account_circle_outlined, size: 64),
                  const SizedBox(height: 8),
                  Text(
                    '欢迎,$_username',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text('您的数字资产已安全托管',
                      style: TextStyle(color: Colors.grey)),
                ],
              ),
      ),
    );
  }
}

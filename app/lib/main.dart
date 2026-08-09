import 'package:flutter/material.dart';

import 'pages/login_page.dart';

void main() {
  runApp(const BequestApp());
}

class BequestApp extends StatelessWidget {
  const BequestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '托孤',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const LoginPage(),
    );
  }
}

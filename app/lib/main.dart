import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'screens/home_shell.dart';

void main() => runApp(const SentinelApp());

class SentinelApp extends StatelessWidget {
  const SentinelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SENTINEL',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const HomeShell(),
    );
  }
}
// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'core/storage.dart';
import 'screens/chat_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await storage.init();
  await settings.load();
  await store.load();
  await presets.load();
  runApp(const GenTechChatApp());
}

class GenTechChatApp extends StatelessWidget {
  const GenTechChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        return MaterialApp(
          title: 'GenTech Chat',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(settings.palette),
          home: const SplashScreen(),
        );
      },
    );
  }
}

/// Экран-заставка в стиле системной заставки Android:
/// светло-серый фон, стандартный логотип Flutter и подпись sans-serif.
/// Через 2 секунды плавно переходит на ChatScreen.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const ChatScreen(),
          transitionsBuilder: (_, anim, __, child) {
            return FadeTransition(opacity: anim, child: child);
          },
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[300],
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FlutterLogo(size: 120),
            const SizedBox(height: 24),
            Text(
              'GenTech Chat',
              style: TextStyle(
                fontFamily: 'sans-serif',
                fontFamilyFallback: const ['Roboto', 'Arial'],
                fontSize: 26,
                fontWeight: FontWeight.w500,
                color: Colors.blueGrey[900],
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:math';

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

/// Экран-заставка: три искры + надпись "GenTech Chat" шрифтом Literata.
/// Через 2 секунды плавно переходит на ChatScreen.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );

    _controller.forward();
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
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = settings.palette;
    return Scaffold(
      backgroundColor: p.bg,
      body: Center(
        child: FadeTransition(
          opacity: _fade,
          child: ScaleTransition(
            scale: _scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Три искры (sparkles)
                CustomPaint(
                  size: const Size(72, 72),
                  painter: _SparklesPainter(color: p.accent),
                ),
                const SizedBox(height: 20),
                // Название приложения шрифтом Literata
                Text(
                  'GenTech Chat',
                  style: TextStyle(
                    fontFamily: 'Literata',
                    fontFamilyFallback: const ['serif'],
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Рисует три четырёхконечные звезды-искры (sparkles) в акцентном цвете.
class _SparklesPainter extends CustomPainter {
  final Color color;
  _SparklesPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final center = Offset(size.width / 2, size.height / 2);
    const sparkleSize = 24.0;
    const gap = 6.0;
    const totalWidth = sparkleSize * 3 + gap * 2;
    final startX = center.dx - totalWidth / 2 + sparkleSize / 2;

    for (int i = 0; i < 3; i++) {
      final cx = startX + i * (sparkleSize + gap);
      final cy = center.dy + (i == 1 ? -4 : 0); // средняя чуть выше
      _drawSparkle(canvas, paint, Offset(cx, cy), sparkleSize / 2);
    }
  }

  void _drawSparkle(Canvas canvas, Paint paint, Offset center, double radius) {
    final path = Path();
    const spikes = 4;
    final angleStep = 2 * 3.1415926535 / spikes;
    for (int i = 0; i < spikes; i++) {
      final angle = i * angleStep - 3.1415926535 / 4; // поворот 45°
      final outer = Offset(
        center.dx + radius * cos(angle),
        center.dy + radius * sin(angle),
      );
      final inner = Offset(
        center.dx + radius * 0.35 * cos(angle + angleStep / 2),
        center.dy + radius * 0.35 * sin(angle + angleStep / 2),
      );
      if (i == 0) {
        path.moveTo(outer.dx, outer.dy);
      } else {
        path.lineTo(outer.dx, outer.dy);
      }
      path.lineTo(inner.dx, inner.dy);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklesPainter oldDelegate) =>
      oldDelegate.color != color;
}

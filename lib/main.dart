// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'core/storage.dart';
import 'models/tool.dart';
import 'screens/chat_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await storage.init();
  await settings.load();
  await store.load();
  await presets.load();
  await _seedDefaultTools();
  runApp(const GenTechChatApp());
}

/// Базовые инструменты, которые появляются в списке по умолчанию:
/// «Погода», «Википедия» и «Калькулятор» (открытые GET-эндпоинты без ключей).
/// Инструмент добавляется, только если инструмента с таким именем ещё нет,
/// поэтому пользовательские инструменты никогда не перезаписываются.
Future<void> _seedDefaultTools() async {
  try {
    final tools = await storage.getTools();
    final names = <String>{for (final t in tools) t.name};
    final defaults = <Tool>[
      Tool(
        id: newId(),
        name: 'Погода',
        description: 'Текущая погода: температура и ветер по открытому API.',
        endpoint:
            'https://api.open-meteo.com/v1/forecast?latitude=55.75&longitude=37.61&current_weather=true',
        method: 'GET',
        parametersSchema:
            '{"type": "object", "properties": {}, "required": []}',
      ),
      Tool(
        id: newId(),
        name: 'Википедия',
        description: 'Поиск статей в энциклопедии по запросу.',
        endpoint:
            'https://ru.wikipedia.org/w/api.php?action=query&list=search&utf8=&format=json&srsearch={query}',
        method: 'GET',
        parametersSchema:
            '{"type": "object", "properties": {"query": {"type": "string", '
            '"description": "Поисковый запрос"}}, "required": ["query"]}',
      ),
      Tool(
        id: newId(),
        name: 'Калькулятор',
        description: 'Вычисление математических выражений.',
        endpoint: 'https://api.mathjs.org/v4/?expr={query}',
        method: 'GET',
        parametersSchema:
            '{"type": "object", "properties": {"query": {"type": "string", '
            '"description": "Математическое выражение, например 2*(3+4)"}}, '
            '"required": ["query"]}',
      ),
      Tool(
        id: newId(),
        name: 'Курсы валют',
        description: 'Актуальные курсы мировых валют относительно доллара США.',
        endpoint: 'https://open.er-api.com/v6/latest/USD',
        method: 'GET',
        parametersSchema:
            '{"type": "object", "properties": {}, "required": []}',
      ),
      Tool(
        id: newId(),
        name: 'IP Геолокация',
        description: 'Определяет страну, город и провайдера по IP-адресу.',
        endpoint: 'http://ip-api.com/json/{query}',
        method: 'GET',
        parametersSchema:
            '{"type": "object", "properties": {"query": {"type": "string", '
            '"description": "IP-адрес для проверки"}}, "required": ["query"]}',
      ),
      Tool(
        id: newId(),
        name: 'arXiv',
        description: 'Поиск научных статей и препринтов по запросу.',
        endpoint: 'http://export.arxiv.org/api/query?search_query=all:{query}',
        method: 'GET',
        parametersSchema:
            '{"type": "object", "properties": {"query": {"type": "string", '
            '"description": "Поисковый запрос"}}, "required": ["query"]}',
      ),
      Tool(
        id: newId(),
        name: 'Hacker News',
        description: 'Идентификаторы самых популярных новостей сообщества.',
        endpoint: 'https://hacker-news.firebaseio.com/v0/topstories.json',
        method: 'GET',
        parametersSchema:
            '{"type": "object", "properties": {}, "required": []}',
      ),
      Tool(
        id: newId(),
        name: 'Чтение страниц',
        description:
            'Загружает страницу по указанному URL и возвращает её текст (fetch).',
        endpoint: '{query}',
        method: 'GET',
        parametersSchema:
            '{"type": "object", "properties": {"query": {"type": "string", '
            '"description": "Полный URL страницы, начиная с http:// или '
            'https://"}}, "required": ["query"]}',
      ),
    ];
    var changed = false;
    for (final t in defaults) {
      if (names.contains(t.name)) continue;
      tools.add(t);
      changed = true;
    }
    if (changed) await storage.setTools(tools);
  } catch (_) {
    // Хранилище недоступно — не блокируем запуск приложения.
  }
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

/// Экран-заставка: серый фон, в центре белый скруглённый квадрат
/// с логотипом (три медные искры) и подписью «GenTech Chat».
/// Через 1.5 секунды плавно переходит на ChatScreen.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(milliseconds: 1500), () {
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
      backgroundColor: const Color(0xFFE0E0E0),
      body: Center(
        child: Container(
          padding: const EdgeInsets.fromLTRB(32, 28, 32, 24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SparklesLogo(size: 76),
              SizedBox(height: 14),
              Text(
                'GenTech Chat',
                style: TextStyle(
                  fontFamily: 'sans-serif',
                  fontFamilyFallback: ['Roboto', 'Arial'],
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2B2824),
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Логотип приложения: три четырёхконечные звезды-искры акцентного
/// (медного) цвета — крупная справа и две поменьше слева.
class _SparklesLogo extends StatelessWidget {
  final double size;

  const _SparklesLogo({required this.size});

  @override
  Widget build(BuildContext context) {
    const Color accent = Color(0xFFD99A6C);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: size * 0.06,
            child: Icon(
              Icons.auto_awesome,
              size: size * 0.30,
              color: accent.withValues(alpha: 0.75),
            ),
          ),
          Positioned(
            left: size * 0.06,
            bottom: 0,
            child: Icon(
              Icons.auto_awesome,
              size: size * 0.34,
              color: accent.withValues(alpha: 0.9),
            ),
          ),
          Positioned(
            right: 0,
            top: size * 0.18,
            child: Icon(Icons.auto_awesome, size: size * 0.58, color: accent),
          ),
        ],
      ),
    );
  }
}

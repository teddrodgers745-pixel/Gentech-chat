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

// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../app_state.dart' show settings;
import '../models/model_id_normalizer.dart';
import '../models/reasoning_capability.dart';
import '../storage.dart';

/// Резолвер точных уровней размышлений (Reasoning Effort) по каталогу
/// OpenRouter.
///
/// [syncCapabilities] запрашивает публичный GET
/// `https://openrouter.ai/api/v1/models` (эндпоинт не требует токена;
/// если ключ задан в настройках — отправляется заголовком Authorization)
/// и для каждой модели, у которой в ответе есть
/// `reasoning.supported_efforts`, сохраняет [ReasoningCapability]
/// в локальный кэш (SharedPreferences, строка JSON).
///
/// [getCapability] синхронно отдаёт данные из кэша; для моделей без записи
/// (в том числе моделей провайдеров, отличных от OpenRouter) возвращается
/// fallback: ['off', 'medium', 'high'] с mandatory: false.
///
/// Вызывается из main.dart в фоне: сбой сети не влияет на запуск и работу
/// приложения — интерфейс продолжает получать fallback.
abstract final class ReasoningCapabilityResolver {
  static const String _endpoint = 'https://openrouter.ai/api/v1/models';
  static const String _cacheKey = 'reasoning_capabilities_v1';
  static const Duration _timeout = Duration(seconds: 20);

  /// Fallback для моделей без данных.
  static const ReasoningCapability fallback = ReasoningCapability.standard;

  /// Кэш в памяти: нормализованный идентификатор -> capability.
  static Map<String, ReasoningCapability>? _cache;
  static bool _syncing = false;

  /// Сколько моделей сейчас в кэше (для диагностики).
  static int get cachedCount => _cache?.length ?? 0;

  /// Читает сохранённый кэш с диска (если ещё не загружен). Ошибки
  /// хранилища и битый JSON не роняют код: кэш останется пустым.
  static Future<void> loadCache() async {
    if (_cache != null) return;
    final raw = await storage.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final models = decoded['models'];
      if (models is! Map) return;
      final out = <String, ReasoningCapability>{};
      models.forEach((key, value) {
        if (value is! Map) return;
        try {
          final cap = ReasoningCapability.fromJson(
            Map<String, dynamic>.from(value),
          );
          if (cap.hasEfforts) out[key.toString()] = cap;
        } catch (_) {
          // Битая запись пропускается.
        }
      });
      _cache = out;
    } catch (_) {
      // Битый кэш игнорируется: будет перезаписан следующей синхронизацией.
    }
  }

  /// Синхронизация уровней reasoning с каталогом OpenRouter.
  /// Никогда не бросает исключений наружу: любой сбой оставляет прежний
  /// кэш (либо fallback) в силе.
  static Future<void> syncCapabilities() async {
    if (_syncing) return;
    _syncing = true;
    final client = http.Client();
    try {
      await loadCache();
      final headers = <String, String>{'Accept': 'application/json'};
      final key = settings.apiKey.trim();
      if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';
      final resp = await client
          .get(Uri.parse(_endpoint), headers: headers)
          .timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return;
      final caps = parseCatalogResponse(resp.body);
      if (caps.isEmpty) return;
      _cache = caps;
      await _persist(caps);
    } on TimeoutException {
      // Эндпоинт не ответил вовремя: работаем с прежним кэшем/фоллбэком.
    } catch (_) {
      // Сетевая ошибка либо недоступное хранилище: не критично.
    } finally {
      client.close();
      _syncing = false;
    }
  }

  /// Сохраняет кэш в SharedPreferences. Ошибка записи не роняет код:
  /// данные останутся в памяти до следующей синхронизации.
  static Future<void> _persist(Map<String, ReasoningCapability> caps) async {
    try {
      await storage.setString(
        _cacheKey,
        jsonEncode(<String, dynamic>{
          'syncedAt': DateTime.now().toIso8601String(),
          'models': <String, dynamic>{
            for (final e in caps.entries) e.key: e.value.toJson(),
          },
        }),
      );
    } catch (_) {}
  }

  /// Разбор полного ответа каталога: только модели, у которых есть
  /// reasoning.supported_efforts. Битые записи пропускаются.
  static Map<String, ReasoningCapability> parseCatalogResponse(String body) {
    final out = <String, ReasoningCapability>{};
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return out;
    }
    if (decoded is! Map) return out;
    final data = decoded['data'];
    if (data is! List) return out;
    for (final e in data) {
      if (e is! Map) continue;
      final id = ((e['id'] as String?) ?? '').trim();
      if (id.isEmpty) continue;
      final cap = capabilityFromEntry(e);
      if (cap != null) out[ModelIdNormalizer.normalize(id)] = cap;
    }
    return out;
  }

  /// [ReasoningCapability] из записи каталога; null — у модели нет
  /// reasoning.supported_efforts (либо список пуст).
  static ReasoningCapability? capabilityFromEntry(Map<dynamic, dynamic> entry) {
    final rawReasoning = entry['reasoning'];
    if (rawReasoning is! Map) return null;
    final reasoning = Map<String, dynamic>.from(rawReasoning);
    final efforts = _stringsOf(
      reasoning['supported_efforts'] ?? reasoning['supportedEfforts'],
    );
    if (efforts.isEmpty) return null;
    final defRaw =
        reasoning['default_effort'] ?? reasoning['defaultEffort'];
    var def = defRaw is String ? defRaw.trim() : '';
    if (def.isEmpty || !efforts.contains(def)) {
      def = efforts.contains('medium') ? 'medium' : efforts.first;
    }
    return ReasoningCapability(
      supportedEfforts: efforts,
      defaultEffort: def,
      mandatory: !efforts.contains('none'),
    );
  }

  static List<String> _stringsOf(Object? raw) {
    if (raw is! List) return const <String>[];
    return <String>[
      for (final e in raw)
        if (e != null && e.toString().trim().isNotEmpty)
          e.toString().trim(),
    ];
  }

  /// Данные из кэша для модели; для отсутствующих моделей (в кэше только
  /// OpenRouter, поэтому модели прочих провайдеров тоже получают fallback)
  /// возвращается [fallback] — никогда не null.
  static ReasoningCapability getCapability(String modelId) {
    final id = ModelIdNormalizer.normalize(modelId).trim();
    final c = _cache;
    if (id.isEmpty || c == null || c.isEmpty) return fallback;
    final direct = c[id];
    if (direct != null) return direct;
    final short = ModelIdNormalizer.withoutProviderPrefix(id);
    return c[short] ?? fallback;
  }
}

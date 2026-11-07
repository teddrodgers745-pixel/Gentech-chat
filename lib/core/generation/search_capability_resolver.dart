// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../app_state.dart' show settings;
import '../models/model_id_normalizer.dart';
import '../storage.dart';

/// Резолвер поддержки нативного веб-поиска по каталогу OpenRouter.
///
/// [syncCapabilities] проверяет TTL кэша (7 дней, ключ
/// `search_caps_last_sync` в SharedPreferences) и при необходимости
/// запрашивает публичный GET `https://openrouter.ai/api/v1/models`
/// (эндпоинт не требует токена; если ключ задан в настройках —
/// отправляется заголовком Authorization).
///
/// Для каждой модели проверяется поле `supported_parameters`: если там
/// есть `web_search` либо `web_search_options`, идентификатор модели
/// сохраняется в набор `_nativeSearchModels`. Набор персистится в
/// SharedPreferences (ключ `search_capabilities_v1`).
///
/// [supportsNativeSearch] синхронно отвечает, поддерживает ли модель
/// нативный поиск: точное совпадение в кэше, затем поиск без префикса
/// владельца, затем fallback по префиксу `perplexity/sonar`; для всех
/// остальных моделей без записи — false.
///
/// Вызывается из main.dart в фоне: сбой сети никогда не влияет на запуск,
/// TTL не обновляется при неудачной синхронизации (попытка повторится
/// при следующем старте).
abstract final class SearchCapabilityResolver {
  static const String _endpoint = 'https://openrouter.ai/api/v1/models';
  static const String _cacheKey = 'search_capabilities_v1';

  /// Метка последней успешной синхронизации (SharedPreferences):
  /// TTL-кэш 7 дней — повторный запрос не чаще раза в неделю.
  static const String _lastSyncKey = 'search_caps_last_sync';
  static const Duration _ttl = Duration(days: 7);
  static const Duration _timeout = Duration(seconds: 20);

  /// Префикс моделей, для которых нативный поиск предполагается
  /// даже без записи в кэше (fallback).
  static const String _fallbackPrefix = 'perplexity/sonar';

  /// Кэш в памяти: идентификаторы моделей с нативным поиском.
  static Set<String> _nativeSearchModels = <String>{};
  static bool _loaded = false;
  static bool _syncing = false;

  /// Сколько моделей сейчас в кэше (для диагностики).
  static int get cachedCount => _nativeSearchModels.length;

  /// Читает сохранённый кэш с диска (если ещё не загружен). Ошибки
  /// хранилища и битый JSON не роняют код: кэш останется пустым.
  static Future<void> loadCache() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await storage.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final models = decoded['models'];
      if (models is! List) return;
      _nativeSearchModels = <String>{
        for (final e in models)
          if (e != null && e.toString().trim().isNotEmpty)
            e.toString().trim(),
      };
    } catch (_) {
      // Битый кэш игнорируется: будет перезаписан следующей синхронизацией.
      _nativeSearchModels = <String>{};
    }
  }

  /// Синхронизация данных о нативном поиске с каталогом OpenRouter.
  /// Никогда не бросает исключений наружу: любой сбой оставляет прежний
  /// кэш в силе. Метка времени `search_caps_last_sync` обновляется только
  /// при успешном получении каталога.
  static Future<void> syncCapabilities() async {
    if (_syncing) return;
    // Проверка TTL: если последняя успешная синхронизация моложе 7 дней —
    // запрос не выполняется, работаем с сохранённым кэшем.
    try {
      final last = await storage.getString(_lastSyncKey);
      if (last != null && last.isNotEmpty) {
        final dt = DateTime.tryParse(last);
        if (dt != null && DateTime.now().difference(dt) < _ttl) {
          return;
        }
      }
    } catch (_) {
      // Хранилище недоступно — считаем, что синхронизация нужна.
    }
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
      final models = parseCatalogResponse(resp.body);
      if (models.isEmpty) {
        // Каталог не дал данных (битый JSON и т.п.): TTL не обновляем,
        // чтобы следующая попытка состоялась при новом старте.
        return;
      }
      _nativeSearchModels = models;
      await _persist(models);
      // Метка TTL обновляется только при успешном получении каталога:
      // при сбое сети попытка повторится при следующем старте.
      await storage.setString(
        _lastSyncKey,
        DateTime.now().toIso8601String(),
      );
    } on TimeoutException {
      // Эндпоинт не ответил вовремя: работаем с прежним кэшем.
    } catch (_) {
      // Сетевая ошибка либо недоступное хранилище: не критично.
    } finally {
      client.close();
      _syncing = false;
    }
  }

  /// Сохраняет кэш в SharedPreferences. Ошибка записи не роняет код:
  /// данные останутся в памяти до следующей синхронизации.
  static Future<void> _persist(Set<String> models) async {
    try {
      await storage.setString(
        _cacheKey,
        jsonEncode(<String, dynamic>{
          'syncedAt': DateTime.now().toIso8601String(),
          'models': <String>[...models],
        }),
      );
    } catch (_) {}
  }

  /// Разбор полного ответа каталога: идентификаторы моделей, у которых
  /// в `supported_parameters` есть `web_search` либо `web_search_options`.
  /// Битые записи пропускаются, идентификаторы нормализуются
  /// ([ModelIdNormalizer]).
  static Set<String> parseCatalogResponse(String body) {
    final out = <String>{};
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
      final params = e['supported_parameters'];
      if (params is! List) continue;
      final names = <String>{
        for (final p in params)
          if (p != null) p.toString().trim(),
      };
      if (names.contains('web_search') ||
          names.contains('web_search_options')) {
        out.add(ModelIdNormalizer.normalize(id));
      }
    }
    return out;
  }

  /// Поддерживает ли модель нативный веб-поиск.
  ///
  /// Порядок проверки:
  ///  1. точное совпадение нормализованного идентификатора в кэше;
  ///  2. совпадение идентификатора без префикса владельца
  ///     ('vendor/model' -> 'model');
  ///  3. fallback по префиксу: `perplexity/sonar` -> true;
  ///  4. остальное -> false.
  static bool supportsNativeSearch(String modelId) {
    final id = ModelIdNormalizer.normalize(modelId).trim();
    if (id.isEmpty) return false;
    final c = _nativeSearchModels;
    if (c.isNotEmpty) {
      if (c.contains(id)) return true;
      final short = ModelIdNormalizer.withoutProviderPrefix(id);
      if (short.isNotEmpty && c.contains(short)) return true;
    }
    // Fallback: у Perplexity Sonar нативный поиск есть всегда,
    // даже если модели нет в кэше.
    if (id.startsWith(_fallbackPrefix)) return true;
    final shortId = ModelIdNormalizer.withoutProviderPrefix(id);
    return shortId.startsWith(_fallbackPrefix.substring(
      _fallbackPrefix.indexOf('/') + 1,
    ));
  }
}

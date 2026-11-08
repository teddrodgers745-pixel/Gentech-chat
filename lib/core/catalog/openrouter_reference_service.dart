// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/model_id_normalizer.dart';
import '../storage.dart';

/// Справочный каталог OpenRouter (https://openrouter.ai/api/v1/models).
///
/// Используется ТОЛЬКО как справочник ВОЗМОЖНОСТЕЙ для моделей, у которых
/// подключение не дало нужных данных. Цены из справочника НЕ берутся
/// никогда. GET выполняется без ключа (эндпоинт публичный).
///
/// TTL кэша — 7 дней; кэш и метка времени записываются только после
/// успешного ответа с непустым списком. Любой сбой сети оставляет
/// прежний кэш в силе и не сдвигает TTL.
class OpenRouterReferenceService {
  static const String _endpoint = 'https://openrouter.ai/api/v1/models';
  static const String _cacheKey = 'openrouter_reference_cache_v1';
  static const String _lastSyncKey = 'openrouter_reference_sync_v1';
  static const Duration _ttl = Duration(days: 7);
  static const Duration _timeout = Duration(seconds: 20);

  /// Нормализованный идентификатор -> данные справочника.
  Map<String, Map<String, dynamic>> _byId = <String, Map<String, dynamic>>{};
  bool _loaded = false;
  bool _syncing = false;

  /// Сколько записей сейчас в кэше (для диагностики).
  int get cachedCount => _byId.length;

  /// Читает сохранённый кэш с диска (если ещё не загружен). Ошибки
  /// хранилища и битый JSON не роняют код: кэш останется пустым.
  Future<void> loadCache() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await storage.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final models = decoded['models'];
      if (models is! Map) return;
      final out = <String, Map<String, dynamic>>{};
      models.forEach((key, value) {
        if (value is! Map) return;
        final k = key.toString().trim();
        if (k.isEmpty) return;
        out[k] = Map<String, dynamic>.from(value);
      });
      _byId = out;
    } catch (_) {
      _byId = <String, Map<String, dynamic>>{};
    }
  }

  /// Синхронизация справочника с OpenRouter. Никогда не бросает
  /// исключений наружу; метка TTL обновляется только при успехе.
  Future<void> sync() async {
    if (_syncing) return;
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
      final resp = await client
          .get(
            Uri.parse(_endpoint),
            headers: const <String, String>{'Accept': 'application/json'},
          )
          .timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return;
      final parsed = parseCatalogResponse(resp.body);
      if (parsed.isEmpty) {
        // Список пуст (битый JSON и т.п.): TTL не сдвигаем.
        return;
      }
      _byId = parsed;
      await _persist(parsed);
      await storage.setString(_lastSyncKey, DateTime.now().toIso8601String());
    } on TimeoutException {
      // Эндпоинт не ответил вовремя: работаем с прежним кэшем.
    } catch (_) {
      // Сетевая ошибка либо недоступное хранилище: не критично.
    } finally {
      client.close();
      _syncing = false;
    }
  }

  Future<void> _persist(Map<String, Map<String, dynamic>> models) async {
    try {
      await storage.setString(
        _cacheKey,
        jsonEncode(<String, dynamic>{
          'syncedAt': DateTime.now().toIso8601String(),
          'models': models,
        }),
      );
    } catch (_) {
      // Хранилище недоступно: данные останутся в памяти.
    }
  }

  /// Разбор полного ответа каталога в компактные записи справочника:
  /// reasoning (если есть), supported_parameters, context_length
  /// и модальности. Битые записи пропускаются.
  static Map<String, Map<String, dynamic>> parseCatalogResponse(String body) {
    final out = <String, Map<String, dynamic>>{};
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
      try {
        final id = ((e['id'] as String?) ?? '').trim();
        if (id.isEmpty) continue;
        final entry = <String, dynamic>{
          'id': id,
          if (e['name'] is String) 'name': (e['name'] as String).trim(),
          if (e['context_length'] is num)
            'contextLength': (e['context_length'] as num).toInt(),
        };
        final reasoning = e['reasoning'];
        if (reasoning is Map) {
          entry['reasoning'] = Map<String, dynamic>.from(reasoning);
        }
        final params = e['supported_parameters'];
        if (params is List) {
          entry['supportedParameters'] = <String>[
            for (final p in params)
              if (p != null) p.toString(),
          ];
        }
        final arch = e['architecture'];
        if (arch is Map) {
          final a = Map<String, dynamic>.from(arch);
          if (a['modality'] is String) entry['modality'] = a['modality'];
          if (a['input_modalities'] is List) {
            entry['inputModalities'] =
                List<String>.from(a['input_modalities'] as List);
          }
          if (a['output_modalities'] is List) {
            entry['outputModalities'] =
                List<String>.from(a['output_modalities'] as List);
          }
        }
        out[ModelIdNormalizer.normalize(id)] = entry;
      } catch (_) {
        // Битая запись пропускается — остальные не страдают.
      }
    }
    return out;
  }

  /// Поиск записи по идентификатору модели: точное совпадение
  /// нормализованного идентификатора, затем без суффикса даты/снапшота
  /// ('model-20250101' -> 'model'). null — записи нет.
  Map<String, dynamic>? find(String modelId) {
    final norm = ModelIdNormalizer.normalize(modelId).trim();
    if (norm.isEmpty || _byId.isEmpty) return null;
    final direct = _byId[norm];
    if (direct != null) return direct;
    final trimmed = norm.replaceFirst(RegExp(r'-\d{8,14}$'), '');
    if (trimmed.isEmpty || trimmed == norm) return null;
    return _byId[trimmed];
  }
}

/// Глобальный экземпляр справочника OpenRouter.
final OpenRouterReferenceService openRouterReference =
    OpenRouterReferenceService();

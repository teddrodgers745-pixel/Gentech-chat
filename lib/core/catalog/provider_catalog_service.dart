// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../app_state.dart';
import '../auth/polza_auth_service.dart';
import '../generation/curated_parameter_catalog.dart';
import '../models/model_id_normalizer.dart';
import '../models/model_info.dart' show GenerationRoute;
import '../models/param_spec.dart';
import '../providers/heuristic_rules.dart';
import 'catalog_entry.dart';
import 'openrouter_reference_service.dart';

// ---------- терпимые помощники разбора (значения любых типов) ----------

Map<String, dynamic>? _asMap(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : null;

String? _asString(Object? v) => v is String ? v.trim() : null;

double? _asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim().replaceAll(',', '.'));
  return null;
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

List<String> _asStringList(Object? v) {
  if (v is! List) return const <String>[];
  return <String>[
    for (final e in v)
      if (e != null) e.toString().trim(),
  ]..removeWhere((s) => s.isEmpty);
}

List<int> _asIntList(Object? v) {
  if (v is! List) return const <int>[];
  final out = <int>[];
  for (final e in v) {
    final i = _asInt(e);
    if (i != null) out.add(i);
  }
  return out;
}

/// Первое ненулевое значение по списку ключей.
Object? _pick(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v != null) return v;
  }
  return null;
}

const Set<String> _knownTypes = <String>{
  'chat', 'image', 'video', 'tts', 'stt', 'embedding', 'music',
  'classification',
};

/// Каталог моделей по подключениям.
///
/// Для каждого подключения (адрес + ключ, включая OAuth-токен Polza)
/// читается GET {baseUrl}/models; записи разбираются терпимым парсером
/// [parseEntry] (известные форматы Polza/OpenRouter плюс формат В —
/// только id/owned_by). Кэш — json-файл на подключение в каталоге
/// приложения; TTL 24 часа. Кэш и метка времени записываются ТОЛЬКО
/// после успешного ответа с непустым списком; при ошибке сети
/// используется прежний кэш и TTL не сдвигается.
///
/// [lookup] собирает итоговую запись по приоритету: connection ->
/// openrouter (только возможности, не цены) -> curated -> fallback.
/// Цены приходят исключительно из ответа подключения.
class ProviderCatalogService extends ChangeNotifier {
  ProviderCatalogService();

  static const Duration _ttl = Duration(hours: 24);
  static const Duration _timeout = Duration(seconds: 30);

  final Map<String, Map<String, CatalogEntry>> _byConnection =
      <String, Map<String, CatalogEntry>>{};
  final Map<String, DateTime> _syncedAt = <String, DateTime>{};
  final Set<String> _syncing = <String>{};
  bool _loaded = false;

  int get connectionCount => _byConnection.length;

  int entryCountOf(String connectionId) =>
      _byConnection[connectionId.trim()]?.length ?? 0;

  // ---------- кэш на диске ----------

  Future<Directory> _cacheDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/GenTech/catalog');
    await dir.create(recursive: true);
    return dir;
  }

  static String _safeId(String raw) =>
      raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// Читает сохранённые кэши всех подключений (один раз). Битые файлы
  /// и сбои хранилища не роняют код.
  Future<void> loadCache() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await _cacheDir();
      if (!await dir.exists()) return;
      await for (final f in dir.list()) {
        if (f is! File || !f.path.endsWith('.json')) continue;
        try {
          final decoded = jsonDecode(await f.readAsString());
          if (decoded is! Map) continue;
          final cid = (decoded['connectionId'] ?? '').toString();
          final list = decoded['entries'];
          final synced =
              DateTime.tryParse((decoded['syncedAt'] ?? '').toString());
          if (cid.isEmpty || list is! List || synced == null) continue;
          final map = <String, CatalogEntry>{};
          for (final e in list) {
            if (e is! Map) continue;
            try {
              final entry =
                  CatalogEntry.fromJson(Map<String, dynamic>.from(e));
              if (entry.id.isNotEmpty) {
                map[ModelIdNormalizer.normalize(entry.id)] = entry;
              }
            } catch (_) {}
          }
          _byConnection[cid] = map;
          _syncedAt[cid] = synced;
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _persist(String cid, List<CatalogEntry> entries) async {
    try {
      final dir = await _cacheDir();
      final f = File('${dir.path}/catalog_${_safeId(cid)}.json');
      await f.writeAsString(
        jsonEncode(<String, dynamic>{
          'connectionId': cid,
          'syncedAt': DateTime.now().toIso8601String(),
          'entries': <Map<String, dynamic>>[
            for (final e in entries) e.toJson(),
          ],
        }),
        flush: true,
      );
    } catch (_) {}
  }

  // ---------- синхронизация ----------

  /// Синхронизация одного подключения. Никогда не бросает исключений:
  /// при любой ошибке прежний кэш остаётся в силе.
  Future<void> sync(CatalogConnection connection, {bool force = false}) async {
    await loadCache();
    final cid = connection.id.trim();
    if (_syncing.contains(cid)) return;
    if (!force) {
      final at = _syncedAt[cid];
      if (at != null && DateTime.now().difference(at) < _ttl) return;
    }
    _syncing.add(cid);
    final client = http.Client();
    try {
      final base = connection.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.tryParse('$base/models');
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return;
      }
      final headers = <String, String>{'Accept': 'application/json'};
      final key = connection.apiKey.trim();
      // Та же авторизация, что и у обычных запросов к подключению.
      if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';
      final resp = await client.get(uri, headers: headers).timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint(
            '[caps] $cid: HTTP ${resp.statusCode}, использую прежний кэш');
        return;
      }
      final entries = parseCatalogResponse(resp.body, connection);
      if (entries.isEmpty) {
        debugPrint('[caps] $cid: пустой список моделей, TTL не сдвигаю');
        return;
      }
      _byConnection[cid] = <String, CatalogEntry>{
        for (final e in entries) ModelIdNormalizer.normalize(e.id): e,
      };
      _syncedAt[cid] = DateTime.now();
      await _persist(cid, entries);
      final typeCounts = <String, int>{};
      var withPrice = 0;
      var withReasoning = 0;
      for (final e in entries) {
        if (e.type.isNotEmpty) {
          typeCounts[e.type] = (typeCounts[e.type] ?? 0) + 1;
        }
        if (e.priceSource != null) withPrice++;
        if (e.reasoning != null) withReasoning++;
      }
      debugPrint('[caps] $cid: моделей ${entries.length}, по типам '
          '$typeCounts, с ценой $withPrice, с reasoning $withReasoning');
      notifyListeners();
    } on TimeoutException {
      debugPrint('[caps] $cid: таймаут, прежний кэш сохранён');
    } catch (e) {
      debugPrint('[caps] $cid: ошибка сети ($e), прежний кэш сохранён');
    } finally {
      client.close();
      _syncing.remove(cid);
    }
  }

  /// Синхронизация всех известных подключений (пресеты, глобальные
  /// настройки, Polza-сессия) плюс справочник OpenRouter.
  Future<void> syncAll() async {
    unawaited(openRouterReference.sync());
    for (final c in _collectConnections()) {
      try {
        await sync(c);
      } catch (_) {}
    }
  }

  /// Подключения из пресетов, общих настроек и активной Polza-сессии.
  /// Дубликаты по паре (baseUrl, ключ) убираются.
  List<CatalogConnection> _collectConnections() {
    final out = <CatalogConnection>[];
    final seen = <String>{};
    void add(String id, String baseUrl, String apiKey) {
      final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final key = apiKey.trim();
      if (base.isEmpty || key.isEmpty) return;
      if (!seen.add('$base|$key')) return;
      out.add(CatalogConnection(id: id, baseUrl: base, apiKey: key));
    }

    try {
      for (final p in presets.items) {
        add('preset:${p.id}', p.baseUrl, p.apiKey);
      }
      add('global', settings.baseUrl, settings.apiKey);
      if (polzaAuth.isAuthenticated) {
        add('polza', PolzaAuthService.polzaBaseUrl, polzaAuth.accessToken);
      }
    } catch (_) {}
    return out;
  }

  // ---------- парсер ----------

  /// Разбор полного ответа каталога в записи. Битая запись не роняет
  /// разбор остальных.
  static List<CatalogEntry> parseCatalogResponse(
    String body,
    CatalogConnection connection,
  ) {
    final out = <CatalogEntry>[];
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return out;
    }
    if (decoded is! Map) return out;
    final data = decoded['data'] ?? decoded['models'];
    if (data is! List) return out;
    for (final e in data) {
      if (e is! Map) continue;
      try {
        final entry = parseEntry(e, connection);
        if (entry.id.isNotEmpty) out.add(entry);
      } catch (_) {}
    }
    return out;
  }

  /// Универсальный терпимый парсер одной записи /models.
  /// Известные формы: Polza (type, parameters, top_provider.reasoning/
  /// supported_parameters/pricing за 1M), OpenRouter (reasoning,
  /// supported_parameters, pricing за токен в USD) и формат В
  /// (только id/owned_by). Каждая группа данных — в try/catch.
  static CatalogEntry parseEntry(Map raw, CatalogConnection connection) {
    final m = Map<String, dynamic>.from(raw);
    final id = (_asString(m['id']) ??
            _asString(m['name']) ??
            _asString(m['model']) ??
            '')
        .trim();
    final name = (_asString(m['name']) ?? '').trim();
    final topProvider = _asMap(m['top_provider']);

    final typeRaw = (_asString(m['type']) ?? '').toLowerCase();
    final type = _knownTypes.contains(typeRaw) ? typeRaw : '';

    final contextLength = _asInt(_pick(m, const <String>[
      'context_length', 'contextLength', 'context_window',
    ]));
    final maxOut = _asInt(_pick(m, const <String>[
      'max_completion_tokens', 'maxCompletionTokens', 'max_output_tokens',
    ]));
    final supportedParams = _asStringList(
      m['supported_parameters'] ?? topProvider?['supported_parameters'],
    );

    CatalogReasoning? reasoning;
    var reasoningUnknown = false;
    try {
      final r = _parseReasoning(m, topProvider, supportedParams);
      reasoning = r.$1;
      reasoningUnknown = r.$2;
    } catch (_) {
      reasoningUnknown = true;
    }

    var aspectRatios = const <String>[];
    var resolutions = const <String>[];
    var durations = const <int>[];
    var qualities = const <String>[];
    int? maxRefImages;
    try {
      final params = _asMap(m['parameters']);
      if (params != null) {
        aspectRatios =
            _asStringList(_asMap(params['aspect_ratio'])?['values']);
        resolutions = _asStringList(_asMap(params['resolution'])?['values']);
        // duration у Polza — СТРОКИ ('4', '6'): приводим к int.
        durations = _asIntList(_asMap(params['duration'])?['values']);
        qualities = _asStringList(_asMap(params['quality'])?['values']);
        maxRefImages = _asInt(_asMap(params['images'])?['max']);
      }
    } catch (_) {}

    double? priceIn;
    double? priceOut;
    String? currency;
    try {
      final p = _parsePrice(m, topProvider);
      priceIn = p.$1;
      priceOut = p.$2;
      currency = p.$3;
    } catch (_) {}

    bool? supportsTools;
    if (supportedParams.isNotEmpty) {
      supportsTools = supportedParams.contains('tools') ||
          supportedParams.contains('function_calling');
    }

    return CatalogEntry(
      connectionId: connection.id,
      id: id,
      name: name,
      type: type,
      contextLength: contextLength,
      maxCompletionTokens: maxOut,
      reasoning: reasoning,
      reasoningUnknown: reasoningUnknown,
      supportsTools: supportsTools,
      aspectRatios: aspectRatios,
      resolutions: resolutions,
      durations: durations,
      qualities: qualities,
      maxReferenceImages: maxRefImages,
      priceIn: priceIn,
      priceOut: priceOut,
      currency: currency,
      capabilitiesSource: CatalogSources.connection,
      priceSource: (priceIn != null || priceOut != null)
          ? CatalogSources.connection
          : null,
    );
  }

  /// Уровни размышлений по умолчанию, когда провайдер заявил reasoning,
  /// но не перечислил уровни.
  static const List<String> _defaultReasoningLevels = <String>[
    'none', 'low', 'medium', 'high',
  ];

  /// Reasoning: m['reasoning'] и/или m['top_provider']['reasoning'].
  /// Возвращает (reasoning, unknown). unknown=true — провайдер не отдал
  /// ни reasoning, ни supported_parameters (формат В).
  static (CatalogReasoning?, bool) _parseReasoning(
    Map<String, dynamic> m,
    Map<String, dynamic>? topProvider,
    List<String> supportedParams,
  ) {
    var mapCandidate = _asMap(m['reasoning']);
    var sawMarker = identical(m['reasoning'], true);
    final tpRaw = topProvider?['reasoning'];
    if (mapCandidate == null && !sawMarker) {
      mapCandidate = _asMap(tpRaw);
      sawMarker = identical(tpRaw, true);
    }
    if (mapCandidate != null) {
      final efforts = _asStringList(
        mapCandidate['supported_efforts'] ?? mapCandidate['supportedEfforts'],
      );
      final def = _asString(
            mapCandidate['default_effort'] ?? mapCandidate['defaultEffort'],
          ) ??
          '';
      if (efforts.isNotEmpty) {
        return (
          CatalogReasoning(
            levels: efforts,
            defaultEffort: def,
            mandatory: mapCandidate['mandatory'] == true,
          ),
          false,
        );
      }
      // Словарь без списка усилий: базовые уровни.
      return (
        CatalogReasoning(
          levels: List<String>.of(_defaultReasoningLevels),
          defaultEffort: def,
          mandatory: mapCandidate['mandatory'] == true,
        ),
        false,
      );
    }
    if (sawMarker) {
      // reasoning: true — уровни не перечислены.
      return (
        CatalogReasoning(levels: List<String>.of(_defaultReasoningLevels)),
        false,
      );
    }
    if (supportedParams.contains('reasoning') ||
        supportedParams.contains('reasoning_effort')) {
      return (
        CatalogReasoning(levels: List<String>.of(_defaultReasoningLevels)),
        false,
      );
    }
    if (supportedParams.isNotEmpty) {
      // supported_parameters есть, reasoning не заявлен: провайдер явно
      // не заявил (не неизвестно).
      return (null, false);
    }
    // Формат В: ни reasoning, ни supported_parameters — неизвестно.
    return (null, true);
  }

  /// Цены ТОЛЬКО в известных формах. Возвращает (in, out, currency).
  static (double?, double?, String?) _parsePrice(
    Map<String, dynamic> m,
    Map<String, dynamic>? topProvider,
  ) {
    final spots = <Map<String, dynamic>>[
      m,
      if (topProvider != null) topProvider,
    ];
    // 1) Явные цены за миллион токенов (Polza: top_provider.pricing).
    for (final spot in spots) {
      final pricing = _asMap(spot['pricing']);
      final inM = _asDouble(_pick(spot, const <String>[
        'prompt_per_million', 'input_per_million',
        'prompt_per_1m', 'input_per_1m',
      ])) ??
          (pricing == null
              ? null
              : _asDouble(_pick(pricing, const <String>[
                  'prompt_per_million', 'input_per_million',
                  'prompt_per_1m', 'input_per_1m',
                ])));
      final outM = _asDouble(_pick(spot, const <String>[
        'completion_per_million', 'output_per_million',
        'completion_per_1m', 'output_per_1m',
      ])) ??
          (pricing == null
              ? null
              : _asDouble(_pick(pricing, const <String>[
                  'completion_per_million', 'output_per_million',
                  'completion_per_1m', 'output_per_1m',
                ])));
      if (inM != null || outM != null) {
        final cur = _asString(_pick(spot, const ['currency'])) ??
            (pricing == null ? null : _asString(pricing['currency']));
        return (inM, outM, cur);
      }
    }
    // 2) Цены за один токен (OpenRouter): pricing.prompt/completion в USD.
    for (final spot in spots) {
      final pricing = _asMap(spot['pricing']);
      if (pricing == null) continue;
      final inTok = _asDouble(pricing['prompt'] ?? pricing['input']);
      final outTok = _asDouble(pricing['completion'] ?? pricing['output']);
      if (inTok == null && outTok == null) continue;
      double? s(double? v) =>
          v == null ? null : (v < 1 ? v * 1000000 : v);
      return (s(inTok), s(outTok), _asString(pricing['currency']) ?? 'USD');
    }
    return (null, null, null);
  }

  // ---------- lookup ----------

  /// Итоговая запись по приоритету: connection -> openrouter ->
  /// curated -> fallback. Цены не добираются из справочников.
  Future<CatalogEntry> lookup(String connectionId, String modelId) async {
    await loadCache();
    final rawId = modelId.trim();
    final norm = ModelIdNormalizer.normalize(rawId);
    var entry = _byConnection[connectionId.trim()]?[norm];
    if (entry == null) {
      entry = CatalogEntry(
        connectionId: connectionId,
        id: rawId,
        reasoningUnknown: true,
        capabilitiesSource: CatalogSources.fallback,
      );
    }
    var source = entry.capabilitiesSource;

    if (_needsReference(entry)) {
      try {
        await openRouterReference.loadCache();
        unawaited(openRouterReference.sync());
        final ref = openRouterReference.find(rawId);
        if (ref != null) {
          final (filled, changed) = _fillFromReference(entry, ref);
          if (changed) {
            source = _upgradedSource(source, CatalogSources.openrouter);
            entry = filled;
          }
        }
      } catch (_) {}
    }
    if (_needsCurated(entry)) {
      try {
        if (!CuratedParameterCatalog.isLoaded) {
          await CuratedParameterCatalog.load();
        }
        final spec = CuratedParameterCatalog.byId(rawId) ??
            (norm.isNotEmpty ? CuratedParameterCatalog.byId(norm) : null);
        if (spec != null && spec.hasAny) {
          final (filled, changed) = _fillFromCurated(entry, spec);
          if (changed) {
            source = _upgradedSource(source, CatalogSources.curated);
            entry = filled;
          }
        }
      } catch (_) {}
    }
    if (entry.type.isEmpty || (entry.reasoning == null && entry.reasoningUnknown)) {
      entry = _applyFallback(entry, rawId);
    }
    final rState = entry.reasoning != null
        ? 'задан'
        : (entry.reasoningUnknown ? 'неизвестен' : 'не заявлен');
    debugPrint('[caps] lookup "$rawId" (norm: $norm, conn: $connectionId): '
        'caps=$source, price=${entry.priceSource ?? 'нет'}, reasoning=$rState, '
        'type=${entry.type.isEmpty ? '?' : entry.type}');
    return entry;
  }

  static String _upgradedSource(String current, String candidate) =>
      current == CatalogSources.fallback ? candidate : current;

  static bool _needsReference(CatalogEntry e) =>
      e.reasoningUnknown ||
      e.reasoning == null ||
      e.type.isEmpty ||
      e.supportsTools == null;

  static bool _needsCurated(CatalogEntry e) =>
      (e.aspectRatios.isEmpty &&
          e.resolutions.isEmpty &&
          e.durations.isEmpty) &&
      (e.type.isEmpty || e.type == 'image' || e.type == 'video');

  /// Дозаполнение возможностей из справочника OpenRouter (цены не трогаем).
  static (CatalogEntry, bool) _fillFromReference(
    CatalogEntry e,
    Map<String, dynamic> ref,
  ) {
    try {
      final params = _asStringList(ref['supportedParameters']);
      final r = _parseReasoning(
        <String, dynamic>{'reasoning': ref['reasoning']},
        null,
        params,
      );
      final refName = _asString(ref['name']);
      final changed = (e.name.isEmpty && refName != null) ||
          e.contextLength == null ||
          e.reasoning == null ||
          e.reasoningUnknown ||
          e.supportsTools == null;
      if (!changed) return (e, false);
      return (
        e.copyWith(
          name: e.name.isEmpty ? refName : null,
          contextLength: e.contextLength ?? _asInt(ref['contextLength']),
          reasoning: e.reasoning ?? r.$1,
          reasoningUnknown: r.$1 != null,
          supportsTools: e.supportsTools ??
              (params.isNotEmpty
                  ? params.contains('tools') ||
                      params.contains('function_calling')
                  : null),
        ),
        true,
      );
    } catch (_) {
      return (e, false);
    }
  }

  /// Дозаполнение медиа-параметров из курированного каталога проекта.
  static (CatalogEntry, bool) _fillFromCurated(
    CatalogEntry e,
    ModelParameters spec,
  ) {
    try {
      final durs = spec.durations;
      var durList = const <int>[];
      if (durs != null && !durs.isEmpty) {
        final disc = durs.discrete;
        if (disc != null && disc.isNotEmpty) {
          durList = List<int>.of(disc);
        } else if (durs.min != null && durs.max != null) {
          durList = <int>[durs.min!, durs.max!];
        } else {
          final only = durs.min ?? durs.max;
          if (only != null) durList = <int>[only];
        }
      }
      return (
        e.copyWith(
          type: (e.type.isEmpty && spec.type != null) ? spec.type : null,
          aspectRatios: e.aspectRatios.isEmpty ? spec.aspectRatios : null,
          resolutions: e.resolutions.isEmpty ? spec.resolutions : null,
          durations: e.durations.isEmpty ? durList : null,
          qualities: e.qualities.isEmpty ? spec.qualities : null,
        ),
        true,
      );
    } catch (_) {
      return (e, false);
    }
  }

  /// Запасные значения: тип по эвристике идентификатора, базовые уровни
  /// reasoning, если данные так и остались неизвестными.
  static CatalogEntry _applyFallback(CatalogEntry e, String rawModelId) {
    var type = e.type;
    if (type.isEmpty) {
      final route =
          HeuristicRules.inferRoute(HeuristicRules.normalize(rawModelId));
      type = switch (route) {
        GenerationRoute.imageGeneration => 'image',
        GenerationRoute.asyncJob => 'video',
        GenerationRoute.textToSpeech => 'tts',
        GenerationRoute.audioTranscription => 'stt',
        GenerationRoute.embeddings => 'embedding',
        _ => 'chat',
      };
    }
    var reasoning = e.reasoning;
    var unknown = e.reasoningUnknown;
    if (reasoning == null && unknown) {
      reasoning = const CatalogReasoning(
        levels: _defaultReasoningLevels,
      );
      unknown = false;
    }
    return CatalogEntry(
      connectionId: e.connectionId,
      id: e.id,
      name: e.name,
      type: type,
      contextLength: e.contextLength,
      maxCompletionTokens: e.maxCompletionTokens,
      reasoning: reasoning,
      reasoningUnknown: unknown,
      supportsTools: e.supportsTools,
      aspectRatios: e.aspectRatios,
      resolutions: e.resolutions,
      durations: e.durations,
      qualities: e.qualities,
      maxReferenceImages: e.maxReferenceImages,
      priceIn: e.priceIn,
      priceOut: e.priceOut,
      currency: e.currency,
      capabilitiesSource: e.capabilitiesSource,
      priceSource: e.priceSource,
    );
  }
}

/// Глобальный экземпляр каталога по подключениям.
final ProviderCatalogService providerCatalog = ProviderCatalogService();

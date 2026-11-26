// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../app_state.dart';
import '../auth/polza_auth_service.dart';
import '../auth/routerai_auth_service.dart';
import '../generation/curated_parameter_catalog.dart';
import '../models/model_id_normalizer.dart';
import '../models/param_spec.dart';
import 'catalog_entry.dart';
import 'catalog_parsing.dart';
import 'openrouter_reference_service.dart';
import 'parsing/reasoning_levels.dart';

export 'catalog_entry.dart'
    show CatalogConnection, CatalogEntry, CatalogReasoning, CatalogSources;

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

/// Результат обновления каталога. При ошибке [entries] содержит
/// доступный прежний кэш, а [error] описывает причину ошибки.
class CatalogSyncResult {
  final List<CatalogEntry> entries;
  final String? error;

  CatalogSyncResult({
    required List<CatalogEntry> entries,
    this.error,
  }) : entries = List<CatalogEntry>.unmodifiable(entries);
}

typedef _ConnectionIdentity = (String, String);

/// Каталог моделей по подключениям.
///
/// Данные общего подключения доступны под всеми его известными id.
/// Эквивалентность определяется парой адреса и ключа, а не именем
/// провайдера. Ключи используются только в памяти и не пишутся в кэш.
///
/// Кэш и метка времени записываются только после успешного ответа с
/// непустым списком; при ошибке используется прежний кэш.
class ProviderCatalogService extends ChangeNotifier {
  ProviderCatalogService();

  static const Duration _ttl = Duration(hours: 24);
  static const Duration _timeout = Duration(seconds: 30);

  // Ключ карты — исходный id модели. Это сохраняет разные исходные id,
  // которые нормализатор мог бы привести к одному значению.
  final Map<String, Map<String, CatalogEntry>> _byConnection =
      <String, Map<String, CatalogEntry>>{};
  final Map<String, DateTime> _syncedAt = <String, DateTime>{};

  // Идентичности и ключи авторизации не сериализуются.
  final Map<String, _ConnectionIdentity> _identityById =
      <String, _ConnectionIdentity>{};
  final Map<String, CatalogConnection> _lastConnectionById =
      <String, CatalogConnection>{};

  final Map<String, Future<CatalogSyncResult>> _syncingById =
      <String, Future<CatalogSyncResult>>{};
  final Map<String, _ConnectionIdentity> _syncingIdentityById =
      <String, _ConnectionIdentity>{};
  final Map<_ConnectionIdentity, Future<CatalogSyncResult>> _downloads =
      <_ConnectionIdentity, Future<CatalogSyncResult>>{};

  Future<void>? _loadFuture;

  int get connectionCount => _byConnection.length;

  int entryCountOf(String connectionId) =>
      _cachedForId(connectionId.trim())?.length ?? 0;

  static String _baseOf(String raw) =>
      raw.trim().replaceAll(RegExp(r'/+$'), '');

  static String _keyOf(String raw) => raw
      .trim()
      .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');

  static _ConnectionIdentity _identityOf(CatalogConnection connection) =>
      (_baseOf(connection.baseUrl), _keyOf(connection.apiKey));

  // ---------- кэш на диске ----------

  Future<Directory> _cacheDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/GenTech/catalog');
    await dir.create(recursive: true);
    return dir;
  }

  static String _safeId(String raw) =>
      raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// Все параллельные вызовы ожидают завершения одного чтения кэша.
  Future<void> loadCache() => _loadFuture ??= _readCache();

  Future<void> _readCache() async {
    try {
      final dir = await _cacheDir();
      if (!await dir.exists()) return;
      await for (final f in dir.list()) {
        if (f is! File || !f.path.endsWith('.json')) continue;
        try {
          final decoded = jsonDecode(await f.readAsString());
          if (decoded is! Map) continue;
          final cid = (decoded['connectionId'] ?? '').toString().trim();
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
              final id = entry.id.trim();
              if (id.isNotEmpty) map[id] = entry;
            } catch (_) {}
          }
          if (map.isEmpty) continue;
          _byConnection[cid] = map;
          _syncedAt[cid] = synced;
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _persist(
    String cid,
    List<CatalogEntry> entries,
    DateTime syncedAt,
  ) async {
    try {
      final dir = await _cacheDir();
      final f = File('${dir.path}/catalog_${_safeId(cid)}.json');
      await f.writeAsString(
        jsonEncode(<String, dynamic>{
          'connectionId': cid,
          'syncedAt': syncedAt.toIso8601String(),
          'entries': <Map<String, dynamic>>[
            for (final e in entries) e.toJson(),
          ],
        }),
        flush: true,
      );
    } catch (_) {}
  }

  // ---------- идентичность подключений ----------

  /// Все известные имена именно этого адреса и ключа.
  Set<String> _relatedIds(CatalogConnection connection) {
    final identity = _identityOf(connection);
    final ids = <String>{connection.id.trim()};
    for (final c in _collectConnections()) {
      if (_identityOf(c) == identity) ids.add(c.id.trim());
    }
    for (final item in _lastConnectionById.entries) {
      if (_identityOf(item.value) == identity) ids.add(item.key);
    }
    ids.remove('');
    return ids;
  }

  CatalogConnection? _connectionForId(String connectionId) {
    final id = connectionId.trim();
    if (id.isEmpty) return null;

    // Для пресета и общих настроек актуальная конфигурация важнее
    // ранее выполненного запроса: адрес или ключ могли измениться.
    if (id == 'global' || id.startsWith('preset:')) {
      for (final c in _collectConnections()) {
        if (c.id.trim() == id) return c;
      }
    }

    final last = _lastConnectionById[id];
    if (last != null) return last;
    for (final c in _collectConnections()) {
      if (c.id.trim() == id) return c;
    }
    return null;
  }

  Map<String, CatalogEntry>? _cachedFor(CatalogConnection connection) {
    final identity = _identityOf(connection);
    Map<String, CatalogEntry>? latest;
    DateTime? latestAt;

    for (final id in _relatedIds(connection)) {
      final knownIdentity = _identityById[id];
      if (knownIdentity != null && knownIdentity != identity) continue;
      final entries = _byConnection[id];
      if (entries == null || entries.isEmpty) continue;
      final at = _syncedAt[id];
      if (latest == null ||
          (at != null && (latestAt == null || at.isAfter(latestAt)))) {
        latest = entries;
        latestAt = at;
      }
    }
    return latest;
  }

  Map<String, CatalogEntry>? _cachedForId(String connectionId) {
    final connection = _connectionForId(connectionId);
    if (connection != null) return _cachedFor(connection);
    return _byConnection[connectionId.trim()];
  }

  DateTime? _latestSyncFor(CatalogConnection connection) {
    final identity = _identityOf(connection);
    DateTime? latest;
    for (final id in _relatedIds(connection)) {
      final knownIdentity = _identityById[id];
      if (knownIdentity != null && knownIdentity != identity) continue;
      if (_byConnection[id]?.isNotEmpty != true) continue;
      final at = _syncedAt[id];
      if (at != null && (latest == null || at.isAfter(latestAt ?? at))) {
        latest = at;
      }
    }
    return latest;
  }

  // ---------- синхронизация ----------

  /// Синхронизирует указанное подключение и возвращает тот же набор
  /// записей, который доступен через lookup.
  ///
  /// Параллельные запросы к одной паре адрес/ключ используют общий
  /// сетевой запрос. Если тот же id уже обновляется с другими
  /// реквизитами, новый запрос сначала ожидает предыдущий.
  Future<CatalogSyncResult> sync(
    CatalogConnection connection, {
    bool force = false,
  }) async {
    await loadCache();

    final cid = connection.id.trim();
    final identity = _identityOf(connection);
    if (cid.isEmpty) {
      return CatalogSyncResult(
        entries: const <CatalogEntry>[],
        error: 'Не указан идентификатор подключения.',
      );
    }

    while (true) {
      final running = _syncingById[cid];
      if (running == null) break;
      final runningIdentity = _syncingIdentityById[cid];
      final result = await running;
      if (runningIdentity == identity) return result;
      if (identical(_syncingById[cid], running)) {
        _syncingById.remove(cid);
        _syncingIdentityById.remove(cid);
      }
    }

    final task = _syncOne(connection, force: force);
    _syncingById[cid] = task;
    _syncingIdentityById[cid] = identity;
    try {
      return await task;
    } finally {
      if (identical(_syncingById[cid], task)) {
        _syncingById.remove(cid);
        _syncingIdentityById.remove(cid);
      }
    }
  }

  Future<CatalogSyncResult> _syncOne(
    CatalogConnection connection, {
    required bool force,
  }) async {
    final cid = connection.id.trim();
    final identity = _identityOf(connection);
    final cached = _cachedFor(connection);
    final at = _latestSyncFor(connection);

    if (!force &&
        cached != null &&
        at != null &&
        DateTime.now().difference(at) < _ttl) {
      return CatalogSyncResult(entries: cached.values.toList());
    }

    var download = _downloads[identity];
    if (download == null) {
      download = _download(connection);
      _downloads[identity] = download;
    }

    CatalogSyncResult result;
    try {
      result = await download;
    } finally {
      if (identical(_downloads[identity], download)) {
        _downloads.remove(identity);
      }
    }

    if (result.error != null || result.entries.isEmpty) {
      final previous = _cachedFor(connection);
      return CatalogSyncResult(
        entries: previous?.values.toList() ?? const <CatalogEntry>[],
        error: result.error ?? 'Сервер не вернул ни одной модели.',
      );
    }

    final map = <String, CatalogEntry>{
      for (final entry in result.entries)
        if (entry.id.trim().isNotEmpty) entry.id.trim(): entry,
    };
    if (map.isEmpty) {
      final previous = _cachedFor(connection);
      return CatalogSyncResult(
        entries: previous?.values.toList() ?? const <CatalogEntry>[],
        error: 'Сервер не вернул ни одной модели.',
      );
    }

    final syncedAt = DateTime.now();
    final ids = _relatedIds(connection);
    final appliedIds = <String>[];

    for (final id in ids) {
      // Не перезаписываем другой запрос, который уже обновляет тот же
      // логический id с другим адресом или ключом.
      final pendingIdentity = _syncingIdentityById[id];
      if (pendingIdentity != null && pendingIdentity != identity) continue;
      _byConnection[id] = map;
      _syncedAt[id] = syncedAt;
      _identityById[id] = identity;
      appliedIds.add(id);
    }
    _lastConnectionById[cid] = connection;

    final entries = map.values.toList();
    for (final id in appliedIds) {
      await _persist(id, entries, syncedAt);
    }

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

    return CatalogSyncResult(entries: entries);
  }

  Future<CatalogSyncResult> _download(CatalogConnection connection) async {
    final cid = connection.id.trim();
    final client = http.Client();
    try {
      final base = _baseOf(connection.baseUrl);
      final uri = Uri.tryParse('$base/models');
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        return CatalogSyncResult(
          entries: const <CatalogEntry>[],
          error: 'Некорректный адрес подключения.',
        );
      }

      final headers = <String, String>{'Accept': 'application/json'};
      final key = _keyOf(connection.apiKey);
      if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';

      final resp = await client.get(uri, headers: headers).timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint(
          '[caps] $cid: HTTP ${resp.statusCode}, использую прежний кэш',
        );
        return CatalogSyncResult(
          entries: const <CatalogEntry>[],
          error: 'Ошибка ${resp.statusCode}. Проверьте ключ и адрес.',
        );
      }

      final entries = parseCatalogResponse(resp.body, connection);
      if (entries.isEmpty) {
        debugPrint('[caps] $cid: пустой список моделей, TTL не сдвигаю');
        return CatalogSyncResult(
          entries: const <CatalogEntry>[],
          error: 'Сервер не вернул ни одной модели.',
        );
      }
      return CatalogSyncResult(entries: entries);
    } on TimeoutException {
      debugPrint('[caps] $cid: таймаут, прежний кэш сохранён');
      return CatalogSyncResult(
        entries: const <CatalogEntry>[],
        error: 'Сервер не ответил за 30 секунд.',
      );
    } catch (e) {
      debugPrint('[caps] $cid: ошибка сети ($e), прежний кэш сохранён');
      return CatalogSyncResult(
        entries: const <CatalogEntry>[],
        error: 'Не удалось загрузить модели: проверьте сеть.',
      );
    } finally {
      client.close();
    }
  }

  /// Синхронизация всех известных подключений плюс справочник OpenRouter.
  Future<void> syncAll() async {
    unawaited(openRouterReference.sync());
    for (final c in _collectConnections()) {
      try {
        await sync(c);
      } catch (_) {}
    }
  }

  /// Подключения из пресетов, общих настроек и активных OAuth-сессий.
  /// Имена не отбрасываются: несколько id могут обозначать одну пару
  /// адрес/ключ и должны видеть один каталог.
  List<CatalogConnection> _collectConnections() {
    final out = <CatalogConnection>[];
    void add(String id, String baseUrl, String apiKey) {
      final base = _baseOf(baseUrl);
      final key = _keyOf(apiKey);
      if (base.isEmpty || key.isEmpty) return;
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
      if (routerAiAuth.isAuthenticated) {
        add(
          'routerai',
          RouterAiAuthService.routeraiBaseUrl,
          routerAiAuth.accessToken,
        );
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
    final String normUrl = connection.baseUrl.toLowerCase();
    final bool knownProvider = normUrl.contains('polza.ai') ||
        normUrl.contains('routerai.ru') ||
        normUrl.contains('openrouter.ai');
    if (knownProvider) {
      try {
        final Map<String, dynamic> safeMap = decoded is Map<String, dynamic>
            ? decoded
            : Map<String, dynamic>.from(decoded);
        final parsed = parseModelsList(safeMap, connection.baseUrl);
        for (final entry in parsed) {
          if (entry.id.isNotEmpty) out.add(entry);
        }
      } catch (_) {
        for (final e in data) {
          if (e is! Map) continue;
          try {
            final entry = parseEntry(e, connection);
            if (entry.id.isNotEmpty) out.add(entry);
          } catch (_) {}
        }
      }
    } else {
      for (final e in data) {
        if (e is String && e.trim().isNotEmpty) {
          out.add(parseEntry(<String, dynamic>{'id': e.trim()}, connection));
          continue;
        }
        if (e is! Map) continue;
        try {
          final entry = parseEntry(e, connection);
          if (entry.id.isNotEmpty) out.add(entry);
        } catch (_) {}
      }
    }
    return out;
  }

  /// Универсальный терпимый парсер одной записи /models.
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

    final modalities = _asStringList(_pick(m, const <String>[
      'modalities',
      'input_modalities',
      'supported_modalities',
    ]));

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
        durations = _asIntList(_asMap(params['duration'])?['values']);
        qualities = _asStringList(_asMap(params['quality'])?['values']);
        maxRefImages = _asInt(_asMap(params['images'])?['max']);
      }
      if (aspectRatios.isEmpty) {
        aspectRatios = _asStringList(m['supported_aspect_ratios']);
      }
      if (resolutions.isEmpty) {
        resolutions = _asStringList(m['supported_resolutions']);
      }
      if (durations.isEmpty) {
        durations = _asIntList(m['supported_durations']);
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
      rawType: typeRaw,
      typeSource: type.isNotEmpty
          ? CatalogTypeSources.catalog
          : CatalogTypeSources.unknown,
      modalities: modalities,
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

  /// Разбор заявленных размышлений модели.
  ///
  /// Уровни размышлений перечисляет ТОЛЬКО каталог: список
  /// `supported_efforts` сохраняется как есть, в исходном порядке.
  /// Если каталог уровней не перечислил (в том числе `reasoning: true`
  /// без списка либо только имя параметра в supported_parameters) —
  /// уровни НЕ создаются: запись остаётся «размышления заявлены,
  /// уровней нет», капсула «Мышление» в UI показывается неактивной.
  /// Дефолтных списков уровней больше нет — ничего не выдумываем.
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
      final mandatory = mapCandidate['mandatory'] == true;
      return (
        CatalogReasoning(
          levels: normalizeReasoningLevels(efforts, mandatory: mandatory),
          defaultEffort: normalizeReasoningEffort(def),
          mandatory: mandatory,
        ),
        false,
      );
    }
    if (sawMarker) {
      // reasoning: true без списка уровней: размышления заявлены,
      // уровней нет — не подставляем дефолтный список.
      return (CatalogReasoning(levels: const <String>[]), false);
    }
    if (supportedParams.contains('reasoning') ||
        supportedParams.contains('reasoning_effort')) {
      // Имя параметра — не перечень уровней: уровни не создаются.
      return (CatalogReasoning(levels: const <String>[]), false);
    }
    if (supportedParams.isNotEmpty) return (null, false);
    return (null, true);
  }

  static (double?, double?, String?) _parsePrice(
    Map<String, dynamic> m,
    Map<String, dynamic>? topProvider,
  ) {
    final spots = <Map<String, dynamic>>[
      m,
      if (topProvider != null) topProvider,
    ];
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
    for (final spot in spots) {
      final pricing = _asMap(spot['pricing']);
      if (pricing == null) continue;
      final inTok = _asDouble(pricing['prompt'] ?? pricing['input']);
      final outTok = _asDouble(pricing['completion'] ?? pricing['output']);
      if (inTok == null && outTok == null) continue;
      double? s(double? v) =>
          v == null ? null : (v < 0.01 ? v * 1000000 : v);
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
    final entries = _cachedForId(connectionId);
    CatalogEntry? found = entries?[rawId];
    if (found == null && entries != null) {
      for (final candidate in entries.values) {
        if (ModelIdNormalizer.normalize(candidate.id) == norm) {
          found = candidate;
          break;
        }
      }
    }
    CatalogEntry entry = found ??
        CatalogEntry(
          connectionId: connectionId,
          id: rawId,
          reasoningUnknown: true,
          capabilitiesSource: CatalogSources.fallback,
        );
    var source = entry.capabilitiesSource;
    var refUsed = false;

    if (!_isKnownProviderConnection(connectionId, entry) &&
        _needsReference(entry)) {
      try {
        await openRouterReference.loadCache();
        unawaited(openRouterReference.sync());
        final ref = openRouterReference.find(rawId);
        if (ref != null) {
          final (filled, changed) = _fillFromReference(entry, ref);
          if (changed) {
            source = _upgradedSource(source, CatalogSources.openrouter);
            entry = filled;
            refUsed = true;
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
    final rState = entry.reasoning != null
        ? 'задан'
        : (entry.reasoningUnknown ? 'неизвестен' : 'не заявлен');
    debugPrint('[caps] lookup "$rawId" (norm: $norm, conn: $connectionId): '
        'caps=$source, price=${entry.priceSource ?? 'нет'}, reasoning=$rState, '
        'type=${entry.type.isEmpty ? '?' : entry.type}, '
        'openrouter=${refUsed ? 'добрали' : 'нет'}');
    return entry;
  }

  static String _upgradedSource(String current, String candidate) =>
      current == CatalogSources.fallback ? candidate : current;

  bool _isKnownProviderConnection(String connectionId, CatalogEntry e) {
    final ids = <String>{
      connectionId.trim(),
      if (e.connectionId.trim().isNotEmpty) e.connectionId.trim(),
    };
    for (final id in ids) {
      final c = _connectionForId(id);
      if (c == null) continue;
      final u = c.baseUrl.toLowerCase();
      if (u.contains('polza.ai') ||
          u.contains('routerai.ru') ||
          u.contains('openrouter.ai')) {
        return true;
      }
    }
    return false;
  }

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
          reasoningUnknown: false,
          clearReasoningUnknown: r.$1 != null,
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
}

/// Глобальный экземпляр каталога по подключениям.
final ProviderCatalogService providerCatalog = ProviderCatalogService();

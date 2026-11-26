// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/foundation.dart';

import '../../app_state.dart';
import '../../services/chat_service.dart';
import '../auth/polza_auth_service.dart';
// ignore: unused_import
import '../auth/routerai_auth_service.dart';
import '../catalog/catalog_entry.dart';
import '../catalog/provider_catalog_service.dart';
import '../models/active_model_capabilities.dart';
import '../models/model_id_normalizer.dart';
import '../models/model_info.dart';
import '../models/model_presets.dart';
import '../models/param_spec.dart';
import '../providers/heuristic_rules.dart';
import 'curated_parameter_catalog.dart';
import 'generation_capability_resolver.dart';
import 'model_type_override_store.dart';
import 'search_capability_resolver.dart';
import 'user_param_override_store.dart';

/// Реактивный контроллер «что умеет активная модель».
///
/// Модель принадлежит [PresetStore] — единственному источнику истины:
/// геттер [currentModelId] читает модель активного пресета, запись
/// ([setModel]) делегирует PresetStore.updateActivePresetModel.
///
/// Источник данных о возможностях — каталог подключения
/// ([ProviderCatalogService.lookup]); при отсутствии данных работают
/// прежние резолверы (кэш OpenRouter, курированный каталог, эвристика).
class ActiveModelController extends ChangeNotifier {
  /// [SearchCapabilityResolver] пробрасывается снаружи (main.dart /
  /// место создания контроллера); по умолчанию — статический резолвер.
  ActiveModelController({
    required PresetStore presetController,
    UserParamOverrideStore? overrides,
    bool Function(String modelId)? supportsNativeSearch,
  })  : _presetController = presetController,
        _overrides = overrides ?? userParamOverrideStore,
        _supportsNativeSearch =
            supportsNativeSearch ?? SearchCapabilityResolver.supportsNativeSearch {
    _presetController.addListener(_onPresetChanged);
    providerCatalog.addListener(_onCatalogChanged);
    // Задача 4: прокидываем признак mandatory в ChatService, чтобы
    // _buildReasoningPayload не отправлял none/off для моделей, где
    // каталог объявил reasoning обязательным.
    ChatService.reasoningMandatoryProbe = _probeReasoningMandatory;
  }

  static const List<String> _videoNameHints = <String>[
    'seedance',
    'kling',
    'sora',
    'veo',
    'runway',
    'wan',
    'hailuo',
  ];

  static const List<String> _imageNameHints = <String>[
    'flux',
    'dall-e',
    'dalle',
    'midjourney',
    'stable-diffusion',
    'stablediffusion',
  ];

  /// Базовые уровни размышлений, когда провайдер не сообщил данных:
  /// капсула «Мышление» остаётся видимой. Значение 'off' означает
  /// «размышления не запрашиваются» (в тело запроса параметр не идёт).
  static const List<String> _baseReasoningLevels = <String>[
    'off', 'low', 'medium', 'high',
  ];

  /// Нормализованный id активной модели, для которой в последний раз
  /// выполнился [_resolve]. Используется [_probeReasoningMandatory].
  static String? _activeReasoningNorm;

  /// Значение reasoningNoneAllowed для активной модели.
  /// false — mandatory: каталог запрещает отключать reasoning.
  static bool _activeReasoningNoneAllowed = true;

  /// Проверка «reasoning обязателен» для активной модели (задача 4).
  ///
  /// Вызывается из [ChatService] через
  /// [ChatService.reasoningMandatoryProbe] при построении payload
  /// reasoning. true — mandatory (блок reasoning не отправляется).
  /// Сравниваем по нормализованному id и по id без префикса провайдера,
  /// чтобы не зависеть от того, в каком виде идентификатор пришёл в
  /// запрос.
  static bool _probeReasoningMandatory(String model) {
    final active = _activeReasoningNorm;
    if (active == null || active.isEmpty) return false;
    final norm = ModelIdNormalizer.normalize(model);
    if (norm.isEmpty) return false;
    if (norm == active) return !_activeReasoningNoneAllowed;
    final short = ModelIdNormalizer.withoutProviderPrefix(norm);
    final shortActive = ModelIdNormalizer.withoutProviderPrefix(active);
    if (short.isNotEmpty && short == shortActive) {
      return !_activeReasoningNoneAllowed;
    }
    return false;
  }

  final PresetStore _presetController;
  final UserParamOverrideStore _overrides;

  /// Проверка поддержки нативного веб-поиска (по умолчанию —
  /// [SearchCapabilityResolver.supportsNativeSearch]).
  final bool Function(String modelId) _supportsNativeSearch;

  ActiveModelCapabilities _current = ActiveModelCapabilities.empty;

  bool _resolving = false;
  int _resolveToken = 0;

  /// Модель, для которой в последний раз выполнился [_resolve].
  /// Нужна, чтобы отличить «смену модели» (сброс пресетов на дефолты
  /// новой модели) от повторного резолва той же модели (сохранить выбор).
  String? _lastResolvedModelId;

  ActiveModelCapabilities get current => _current;

  /// Stage 2c-3: реестр итоговых merged-параметров (field-level:
  /// UserParamOverrideStore > CatalogEntry/кэш OpenRouter > curated),
  /// опубликованных [_resolve]. [ParameterTranslator.translateWithCatalog]
  /// читает их как базовый источник спецификации — GenerationRequest и
  /// исполнители при этом не меняются (минимальный канал передачи без
  /// правки UI).
  static final Map<String, ModelParameters> _publishedMerged =
      <String, ModelParameters>{};

  /// Выбранные пользователем в UI медиа-пресеты (aspect_ratio, duration,
  /// resolution, quality). Служат надёжным резервным источником для
  /// [ParameterTranslator], если вызывающий код не положил их в
  /// GenerationRequest.parameters.
  static String? _selectedAspectRatio;
  static int? _selectedDuration;
  static String? _selectedResolution;
  static String? _selectedQuality;

  static String? get selectedAspectRatio => _selectedAspectRatio;
  static int? get selectedDuration => _selectedDuration;
  static String? get selectedResolution => _selectedResolution;
  static String? get selectedQuality => _selectedQuality;

  /// Выбранные медиа-параметры единой картой (aspect_ratio — String
  /// "16:9", duration — int, resolution — String). Пустые значения не
  /// попадают в карту — исполнитель их просто не отправит.
  static Map<String, dynamic> get selectedMediaParams {
    final out = <String, dynamic>{};
    final ratio = _selectedAspectRatio;
    if (ratio != null && ratio.trim().isNotEmpty) {
      out['aspect_ratio'] = ratio.trim();
    }
    final dur = _selectedDuration;
    if (dur != null) out['duration'] = dur;
    final res = _selectedResolution;
    if (res != null && res.trim().isNotEmpty) {
      out['resolution'] = res.trim();
    }
    final q = _selectedQuality;
    if (q != null && q.trim().isNotEmpty) {
      out['quality'] = q.trim();
    }
    return out;
  }

  /// Обновляет выбранные медиа-пресеты из панели ввода.
  static void updateSelectedMediaParams({
    String? aspectRatio,
    int? duration,
    String? resolution,
    String? quality,
    bool clearNulls = false,
  }) {
    if (aspectRatio != null || clearNulls) {
      final clean = aspectRatio?.trim();
      _selectedAspectRatio =
          (clean != null && clean.isNotEmpty) ? clean : null;
    }
    if (duration != null || clearNulls) {
      _selectedDuration = duration;
    }
    if (resolution != null || clearNulls) {
      final clean = resolution?.trim();
      _selectedResolution =
          (clean != null && clean.isNotEmpty) ? clean : null;
    }
    if (quality != null || clearNulls) {
      final clean = quality?.trim();
      _selectedQuality = (clean != null && clean.isNotEmpty) ? clean : null;
    }
  }

  /// Итоговые merged-параметры для модели (результат Stage 2b (c));
  /// null — контроллер ещё не разрешал модель либо параметров нет.
  /// Поиск: сырой id, затем нормализованный, затем без префикса провайдера.
  static ModelParameters? mergedParamsFor(String modelId) {
    final raw = modelId.trim();
    if (raw.isEmpty || _publishedMerged.isEmpty) return null;
    final norm = ModelIdNormalizer.normalize(raw);
    final direct = _publishedMerged[raw] ?? _publishedMerged[norm];
    if (direct != null) return direct;
    final short = ModelIdNormalizer.withoutProviderPrefix(norm);
    if (short.isEmpty || short == norm) return null;
    return _publishedMerged[short];
  }

  /// Публикует КОПИЮ [params] под сырым, нормализованным и коротким
  /// идентификатором модели; прежние записи этой модели снимаются,
  /// пустые параметры регистрацию отменяют.
  static void _publishMergedParams(
    String rawModelId,
    ModelParameters? params,
  ) {
    final raw = rawModelId.trim();
    final norm = ModelIdNormalizer.normalize(rawModelId);
    final short = ModelIdNormalizer.withoutProviderPrefix(norm);
    _publishedMerged
      ..remove(raw)
      ..remove(norm)
      ..remove(short);
    final p = params;
    if (p == null || !p.hasAny) return;
    final d = p.durations;
    final copy = ModelParameters(
      aspectRatios: List<String>.of(p.aspectRatios),
      durations: d == null
          ? null
          : DurationRange(
              min: d.min,
              max: d.max,
              defaultValue: d.defaultValue,
              discrete:
                  d.discrete == null ? null : List<int>.of(d.discrete!),
            ),
      resolutions: List<String>.of(p.resolutions),
      sizes: List<String>.of(p.sizes),
      qualities: List<String>.of(p.qualities),
      constraints: List<String>.of(p.constraints),
      type: p.type,
      confidence: p.confidence,
      isUserDefined: p.isUserDefined,
    );
    if (raw.isNotEmpty) _publishedMerged[raw] = copy;
    if (norm.isNotEmpty) _publishedMerged[norm] = copy;
    if (short.isNotEmpty) _publishedMerged[short] = copy;
  }

  String get currentModelId => _presetController.activePreset?.model ?? '';

  Future<void> setModel(
    String modelId, {
    bool vision = false,
    bool reasoning = false,
  }) async {
    _resolving = true;
    try {
      final owned = currentModelId.trim();
      final incoming = modelId.trim();
      if (incoming.isNotEmpty && incoming != owned) {
        await _presetController.updateActivePresetModel(incoming);
        notifyListeners();
      }
      final target = currentModelId.isNotEmpty ? currentModelId : incoming;
      await _resolve(target);
    } finally {
      _resolving = false;
    }
  }

  Future<void> syncModel(String modelId) async {
    final id = modelId.trim();
    await _resolve(id);
  }

  Future<void> _onPresetChanged() async {
    if (_resolving) return;
    _resolving = true;
    try {
      final presetModel = _presetController.active?.model.trim() ?? '';
      final id = presetModel.isNotEmpty ? presetModel : settings.model.trim();
      await _resolve(id);
    } finally {
      _resolving = false;
    }
  }

  /// Каталог подключения обновился (sync завершился): пересчитываем
  /// возможности выбранной модели и уведомляем интерфейс.
  Future<void> _onCatalogChanged() async {
    if (_resolving) return;
    _resolving = true;
    try {
      final presetModel = _presetController.active?.model.trim() ?? '';
      final id = presetModel.isNotEmpty ? presetModel : settings.model.trim();
      if (id.isEmpty) return;
      await _resolve(id);
    } finally {
      _resolving = false;
    }
  }

  static bool isHeuristicVideo(String rawId) {
    final lower = HeuristicRules.normalize(rawId).toLowerCase();
    if (lower.isEmpty) return false;
    if (lower.contains('wanx')) return false;
    for (final h in _videoNameHints) {
      if (lower.contains(h)) return true;
    }
    return HeuristicRules.inferRoute(lower) == GenerationRoute.asyncJob;
  }

  static bool isHeuristicImage(String rawId) {
    final lower = HeuristicRules.normalize(rawId).toLowerCase();
    if (lower.isEmpty) return false;
    if (isHeuristicVideo(lower) && !lower.contains('wanx')) return false;
    for (final h in _imageNameHints) {
      if (lower.contains(h)) return true;
    }
    return HeuristicRules.inferRoute(lower) == GenerationRoute.imageGeneration;
  }

  static bool isHeuristicSearch(String rawId) {
    final lower = HeuristicRules.normalize(rawId).toLowerCase();
    return lower.contains('sonar');
  }

  /// Идентификатор подключения для [ProviderCatalogService.lookup] —
  /// собранный так же, как в _collectConnections каталога:
  /// 'preset:<id>' для активного пресета с заполненными адресом и ключом,
  /// 'polza' для активной Polza-сессии, 'global' для общих настроек.
  /// null — активное подключение не определено.
  String? _catalogConnectionId() {
    final pr = _presetController.active;
    if (pr != null &&
        pr.id != PresetStore.defaultPresetId &&
        pr.baseUrl.trim().isNotEmpty &&
        pr.apiKey.trim().isNotEmpty) {
      return 'preset:${pr.id}';
    }
    final polzaKey = polzaAuth.isAuthenticated
        ? polzaAuth.accessToken.trim()
        : '';
    final url = pr?.baseUrl.trim().isNotEmpty == true
        ? pr!.baseUrl.trim()
        : settings.baseUrl.trim();
    final key = pr?.apiKey.trim().isNotEmpty == true
        ? pr!.apiKey.trim()
        : settings.apiKey.trim();
    if (url.isEmpty || key.isEmpty) {
      if (polzaKey.isNotEmpty) return 'polza';
      return null;
    }
    // Определение подключения по адресу провайдера: polza.ai -> 'polza',
    // routerai -> 'routerai' — каталог того же провайдера, что и запрос.
    if (url.contains('polza.ai')) return 'polza';
    if (url.contains('routerai')) return 'routerai';
    if (polzaKey.isNotEmpty &&
        key == polzaKey &&
        url == PolzaAuthService.polzaBaseUrl) {
      return 'polza';
    }
    if (pr != null &&
        pr.baseUrl.trim().isNotEmpty &&
        pr.apiKey.trim().isNotEmpty) {
      return 'preset:${pr.id}';
    }
    return 'global';
  }

  /// Кандидаты идентификаторов для поиска параметров: нормализованный id,
  /// сырой id и id без префикса провайдера.
  static Set<String> _paramCandidates(String rawModelId, String norm) {
    final trimmed = rawModelId.trim();
    final shortId = ModelIdNormalizer.withoutProviderPrefix(
      norm.isNotEmpty ? norm : trimmed,
    );
    return <String>{
      if (norm.isNotEmpty) norm,
      if (trimmed.isNotEmpty) trimmed,
      if (shortId.isNotEmpty) shortId,
    };
  }

  /// Пользовательский override параметров — приоритет 1 (Stage 2b (c)):
  /// читается ВСЕГДА, поверх любых catalog/curated. null — override нет.
  Future<ModelParameters?> _loadUserOverride(
    String rawModelId,
    String norm,
  ) async {
    for (final c in _paramCandidates(rawModelId, norm)) {
      try {
        final ov = await _overrides.load(c);
        if (ov != null && ov.hasAny) return ov;
      } catch (_) {}
    }
    return null;
  }

  /// Параметры из курированного каталога и пресетов моделей — приоритет 3
  /// (Stage 2b (c)); используется только для полей, не заполненных
  /// override и каталогом подключения. Без пользовательского override:
  /// он учитывается отдельно с высшим приоритетом в _mergeFieldLevel.
  Future<ModelParameters?> _loadCuratedParams(
    String rawModelId,
    String norm,
  ) async {
    final candidates = _paramCandidates(rawModelId, norm);
    try {
      if (!CuratedParameterCatalog.isLoaded) {
        await CuratedParameterCatalog.load();
      }
      for (final c in candidates) {
        final found = CuratedParameterCatalog.byId(c);
        if (found != null && (found.hasAny || found.confidence == 'skip')) {
          return found;
        }
      }
    } catch (_) {}
    try {
      final ps = await ModelPresets.load();
      ModelPreset? preset;
      for (final c in candidates) {
        preset = ps.forModel(c);
        if (preset != null) break;
      }
      if (preset == null) {
        final shortId = ModelIdNormalizer.withoutProviderPrefix(
          norm.isNotEmpty ? norm : rawModelId.trim(),
        );
        if (shortId.isNotEmpty) {
          for (final item in ps.all) {
            final itemShort = ModelIdNormalizer.withoutProviderPrefix(item.id);
            if (itemShort == shortId ||
                shortId.contains(itemShort) ||
                itemShort.contains(shortId)) {
              if (item.isMedia) {
                preset = item;
                break;
              }
            }
          }
        }
      }
      if (preset != null && preset.isMedia) {
        return ModelParameters(
          type: preset.type,
          aspectRatios: List<String>.of(preset.aspectRatios),
          durations: preset.durations.isEmpty
              ? null
              : DurationRange(discrete: List<int>.of(preset.durations)),
          resolutions: List<String>.of(preset.resolutions),
          confidence: 'auto',
          isUserDefined: false,
        );
      }
    } catch (_) {}
    return null;
  }

  /// Слияние источников параметров ПО КАЖДОМУ ПОЛЮ отдельно (Stage 2b (c)).
  /// Приоритет: [user] (UserParamOverrideStore, SharedPreferences) ->
  /// [fromCatalog] (CatalogEntry подключения / кэш OpenRouter) ->
  /// [curated] (курированный каталог + пресеты). Непустое значение более
  /// приоритетного источника всегда побеждает; пустое поле источника
  /// просто пропускается. Ограничения (constraints) объединяются из всех
  /// источников. null — ни один источник не дал полей генерации
  /// (кроме SKIP-спецификации: модель не генератор).
  static ModelParameters? _mergeFieldLevel({
    ModelParameters? user,
    ModelParameters? fromCatalog,
    ModelParameters? curated,
  }) {
    final out = ModelParameters.unknown();
    String? type;
    var confidence = 'low';
    var userContributed = false;
    var anyField = false;

    void take(ModelParameters? src, bool isUserSrc, String srcConfidence) {
      final s = src;
      if (s == null) return;
      void claim() {
        anyField = true;
        if (isUserSrc) userContributed = true;
        confidence = srcConfidence;
      }

      if (out.aspectRatios.isEmpty && s.aspectRatios.isNotEmpty) {
        out.aspectRatios = List<String>.of(s.aspectRatios);
        claim();
      }
      final d = s.durations;
      if ((out.durations == null || out.durations!.isEmpty) &&
          d != null &&
          !d.isEmpty) {
        out.durations = DurationRange(
          min: d.min,
          max: d.max,
          defaultValue: d.defaultValue,
          discrete: d.discrete == null ? null : List<int>.of(d.discrete!),
        );
        claim();
      }
      if (out.resolutions.isEmpty && s.resolutions.isNotEmpty) {
        out.resolutions = List<String>.of(s.resolutions);
        claim();
      }
      if (out.sizes.isEmpty && s.sizes.isNotEmpty) {
        out.sizes = List<String>.of(s.sizes);
        claim();
      }
      if (out.qualities.isEmpty && s.qualities.isNotEmpty) {
        out.qualities = List<String>.of(s.qualities);
        claim();
      }
      final t = s.type?.trim() ?? '';
      if (t.isNotEmpty && (type == null || type!.isEmpty)) type = t;
      for (final c in s.constraints) {
        if (!out.constraints.contains(c)) out.constraints.add(c);
      }
    }

    take(user, true, 'user');
    take(fromCatalog, false, fromCatalog?.confidence ?? 'low');
    take(curated, false, curated?.confidence ?? 'low');

    if (!anyField) {
      if (curated != null && curated.confidence == 'skip') {
        return ModelParameters.unknown(confidence: 'skip');
      }
      return null;
    }
    out
      ..type = type
      ..confidence = userContributed ? 'user' : confidence
      ..isUserDefined = userContributed;
    return out;
  }

  /// Принудительный поиск параметров модели в пользовательских override,
  /// курированном каталоге и ModelPresets (включая поиск без префикса
  /// провайдера и по совпадению семейства).
  Future<ModelParameters?> _lookupCatalogParams(
    String rawModelId,
    String norm,
  ) async {
    if (norm.isEmpty && rawModelId.trim().isEmpty) return null;
    final trimmed = rawModelId.trim();
    final shortId = ModelIdNormalizer.withoutProviderPrefix(
      norm.isNotEmpty ? norm : trimmed,
    );
    final candidates = <String>{
      if (norm.isNotEmpty) norm,
      if (trimmed.isNotEmpty) trimmed,
      if (shortId.isNotEmpty) shortId,
    };

    for (final c in candidates) {
      try {
        final ov = await _overrides.load(c);
        if (ov != null && ov.hasAny) return ov;
      } catch (_) {}
    }

    try {
      if (!CuratedParameterCatalog.isLoaded) {
        await CuratedParameterCatalog.load();
      }
      for (final c in candidates) {
        final found = CuratedParameterCatalog.byId(c);
        if (found != null && (found.hasAny || found.confidence == 'skip')) {
          return found;
        }
      }
    } catch (_) {}

    try {
      final ps = await ModelPresets.load();
      ModelPreset? preset;
      for (final c in candidates) {
        preset = ps.forModel(c);
        if (preset != null) break;
      }
      if (preset == null && shortId.isNotEmpty) {
        for (final item in ps.all) {
          final itemShort = ModelIdNormalizer.withoutProviderPrefix(item.id);
          if (itemShort == shortId ||
              shortId.contains(itemShort) ||
              itemShort.contains(shortId)) {
            if (item.isMedia) {
              preset = item;
              break;
            }
          }
        }
      }
      if (preset != null && preset.isMedia) {
        return ModelParameters(
          type: preset.type,
          aspectRatios: List<String>.of(preset.aspectRatios),
          durations: preset.durations.isEmpty
              ? null
              : DurationRange(discrete: List<int>.of(preset.durations)),
          resolutions: List<String>.of(preset.resolutions),
          confidence: 'auto',
          isUserDefined: false,
        );
      }
    } catch (_) {}

    return null;
  }

  /// Гарантирует дефолтные параметры для медиа-моделей (видео/картинки),
  /// если в каталоге точной записи не нашлось или в ней нет пропорций/длительностей.
  static ModelParameters defaultMediaParams(
    ActiveModelKind kind,
    String normalizedId,
    ModelParameters? existing,
  ) {
    final lower = normalizedId.toLowerCase();
    if (kind == ActiveModelKind.video) {
      final ratios = (existing != null && existing.aspectRatios.isNotEmpty)
          ? existing.aspectRatios
          : (lower.contains('veo') || lower.contains('sora')
              ? const <String>['16:9', '9:16']
              : const <String>['16:9', '9:16', '1:1']);
      // Выдуманные секунды не подставляем: у Seedance в каталоге Polza
      // нет списка duration (только min/max и default), поэтому панель
      // показывает диапазон из каталога. Наборы прочих семейств прежние.
      final known = existing?.durations;
      final DurationRange? durations = (known != null && !known.isEmpty)
          ? known
          : (lower.contains('seedance')
              ? null
              : DurationRange(
                  discrete: lower.contains('sora')
                      ? const <int>[4, 8, 12]
                      : lower.contains('veo')
                          ? const <int>[5, 8]
                          : const <int>[5, 10],
                ));
      final resolutions = (existing != null && existing.resolutions.isNotEmpty)
          ? existing.resolutions
          : const <String>['720p', '1080p'];
      return ModelParameters(
        type: 'video',
        aspectRatios: List<String>.of(ratios),
        durations: durations,
        resolutions: List<String>.of(resolutions),
        sizes: existing?.sizes ?? const <String>[],
        qualities: existing?.qualities ?? const <String>[],
        constraints: existing?.constraints ?? const <String>[],
        confidence: existing?.confidence ?? 'auto',
        isUserDefined: existing?.isUserDefined ?? false,
      );
    }
    if (kind == ActiveModelKind.image) {
      final ratios = (existing != null && existing.aspectRatios.isNotEmpty)
          ? existing.aspectRatios
          : (lower.contains('flux')
              ? const <String>['1:1', '16:9', '9:16', '4:3', '3:4']
              : const <String>['1:1', '16:9', '9:16']);
      return ModelParameters(
        type: 'image',
        aspectRatios: List<String>.of(ratios),
        durations: null,
        resolutions: existing?.resolutions ?? const <String>[],
        sizes: existing?.sizes ?? const <String>[],
        qualities: existing?.qualities ?? const <String>[],
        constraints: existing?.constraints ?? const <String>[],
        confidence: existing?.confidence ?? 'auto',
        isUserDefined: existing?.isUserDefined ?? false,
      );
    }
    return existing ?? ModelParameters.unknown();
  }

  /// Согласование сохранённого уровня reasoning с возможностями модели:
  /// сохранённое значение остаётся, если модель его поддерживает; иначе
  /// берётся default_effort каталога; иначе первый допустимый уровень.
  static String _resolveReasoningLevel({
    required List<String> levels,
    required String? saved,
    required String defaultEffort,
  }) {
    final s = saved?.trim() ?? '';
    if (s.isNotEmpty) {
      final sl = s.toLowerCase();
      for (final l in levels) {
        if (l.toLowerCase() == sl) return l;
      }
    }
    final d = defaultEffort.trim();
    if (d.isNotEmpty) return d;
    if (levels.isNotEmpty) {
      final first = levels.first.trim();
      if (first.isNotEmpty) return first;
    }
    return 'off';
  }

  Future<void> _resolve(String modelId) async {
    final token = ++_resolveToken;
    final norm = ModelIdNormalizer.normalize(modelId);
    final modelChanged = _lastResolvedModelId != norm;
    _lastResolvedModelId = norm;

    // ---- Приоритет 0: каталог подключения (ProviderCatalogService) ----
    String? cid;
    CatalogEntry? entry;
    try {
      cid = _catalogConnectionId();
      if (cid != null && modelId.trim().isNotEmpty) {
        entry = await providerCatalog.lookup(cid, modelId);
      }
    } catch (_) {
      entry = null;
    }
    if (token != _resolveToken) return;

    String? typeOverride;
    try {
      typeOverride =
          await ModelTypeOverrideStore.instance.loadOverride(modelId);
      if (typeOverride == null && norm.isNotEmpty && norm != modelId.trim()) {
        typeOverride =
            await ModelTypeOverrideStore.instance.loadOverride(norm);
      }
    } catch (_) {
      typeOverride = null;
    }
    if (token != _resolveToken) return;

    final (kind, kindSource) = _kindWithCatalog(entry, typeOverride);

    final isPolzaMedia = cid == 'polza' &&
        (kind == ActiveModelKind.image || kind == ActiveModelKind.video);

    // ---- Параметры генерации (Stage 2b (c): merge по каждому полю) ----
    ModelParameters? params;
    String paramsSource = 'нет';
    final userOverride = await _loadUserOverride(modelId, norm);
    if (token != _resolveToken) return;

    ModelParameters? dynamicParams = _paramsFromCatalog(entry);
    var dynSource = 'каталог (${entry?.capabilitiesSource ?? 'нет'})';
    if (dynamicParams == null) {
      try {
        await GenerationCapabilityResolver.loadCache();
      } catch (_) {}
      final genCap = _genCapabilityQuietly(norm);
      if (genCap != null) {
        dynamicParams = _withConfidence(genCap, 'openrouter');
        dynSource = 'кэш OpenRouter';
      }
    }

    ModelParameters? curatedParams;
    if (!isPolzaMedia) {
      curatedParams = await _loadCuratedParams(modelId, norm);
      if (token != _resolveToken) return;
    }

    final merged = _mergeFieldLevel(
      user: userOverride,
      fromCatalog: dynamicParams,
      curated: curatedParams,
    );
    if (merged != null) {
      params = merged;
      paramsSource =
          userOverride != null ? 'override > $dynSource > curated' : dynSource;
    }
    if (token != _resolveToken) return;

    if (kind == ActiveModelKind.video || kind == ActiveModelKind.image) {
      if (params == null ||
          !params.hasAny ||
          (kind == ActiveModelKind.video &&
              (params.durations == null || params.durations!.isEmpty))) {
        final catalogFallback = isPolzaMedia
            ? null
            : await _lookupCatalogParams(modelId, norm);
        if (catalogFallback != null &&
            catalogFallback.hasAny &&
            !(kind == ActiveModelKind.video &&
                (catalogFallback.durations == null ||
                    catalogFallback.durations!.isEmpty) &&
                (params != null && params.hasAny))) {
          params = _mergeFieldLevel(
                user: userOverride,
                fromCatalog: params,
                curated: catalogFallback,
              ) ??
              catalogFallback;
        }
        if (params == null ||
            !params.hasAny ||
            (kind == ActiveModelKind.video &&
                (params.durations == null || params.durations!.isEmpty)) ||
            (kind == ActiveModelKind.video && params.resolutions.isEmpty)) {
          params = defaultMediaParams(kind, norm, params);
          paramsSource = 'дефолт медиа';
        }
      } else if (kind == ActiveModelKind.video &&
          params.resolutions.isEmpty) {
        params = defaultMediaParams(kind, norm, params);
      }
    }

    if (isHeuristicSearch(norm) && settings.searchMode == 'off') {
      settings.setSearchMode('native');
    }

    try {
      await SearchCapabilityResolver.loadCache();
    } catch (_) {}
    final nativeSearch = _supportsNativeSearch(norm);

    // ---- Reasoning ----
    final isText = kind == ActiveModelKind.text;
    var supportsReasoning = false;
    var reasoningLevels = <String>['off'];
    var reasoningDefault = 'off';
    var reasoningNoneAllowed = true;
    var reasoningSource = 'прежние резолверы';

    if (isText) {
      if (entry != null) {
        final r = entry.reasoning;
        if (r != null) {
          final levels = <String>[...r.levels];
          if (r.mandatory) {
            levels.removeWhere((l) => l == 'none' || l == 'off');
          }
          if (levels.isEmpty && r.defaultEffort.trim().isNotEmpty) {
            levels.add(r.defaultEffort.trim());
          }
          supportsReasoning = true;
          if (levels.isNotEmpty) {
            reasoningLevels = levels;
            reasoningSource =
                'каталог (${entry.capabilitiesSource})'
                '${r.mandatory ? ', mandatory' : ''}';
          } else {
            reasoningLevels = List<String>.of(_baseReasoningLevels);
            reasoningSource =
                'каталог (${entry.capabilitiesSource}), уровни не перечислены';
          }
          final def = r.defaultEffort.trim();
          if (def.isNotEmpty) reasoningDefault = def;
          reasoningNoneAllowed = !r.mandatory;
        } else if (!entry.reasoningUnknown) {
          supportsReasoning = false;
          reasoningLevels = const <String>[];
          reasoningDefault = '';
          reasoningNoneAllowed = true;
          reasoningSource =
              'каталог (${entry.capabilitiesSource}): reasoning отсутствует';
        }
      }
    }
    if (token != _resolveToken) return;

    // Vision только из каталога.
    final vision = entry != null &&
        entry.modalities.any((m) => m.toLowerCase() == 'image');

    final savedReasoning = settings.reasoningForModel(modelId);
    final resolvedReasoningLevel = _resolveReasoningLevel(
      levels: reasoningLevels,
      saved: savedReasoning,
      defaultEffort: reasoningDefault,
    );

    // Синхронизируем дефолты выбранных медиа-параметров для активной модели.
    // Смена модели (modelChanged) — жёсткий сброс на дефолты новой модели,
    // даже если застоявшееся значение попадает в её диапазон.
    if (kind == ActiveModelKind.video || kind == ActiveModelKind.image) {
      final ratios = params?.aspectRatios ?? const <String>[];
      if (ratios.isNotEmpty) {
        if (modelChanged ||
            _selectedAspectRatio == null ||
            !ratios.contains(_selectedAspectRatio)) {
          _selectedAspectRatio = ratios.first;
        }
      } else {
        _selectedAspectRatio = null;
      }

      if (kind == ActiveModelKind.video) {
        final range = params?.durations;
        final disc = range?.discrete ?? const <int>[];
        final current = _selectedDuration;
        final valid = current != null &&
            (disc.isNotEmpty
                ? disc.contains(current)
                : _inDurationRange(current, range));
        if (modelChanged || !valid) {
          // Дефолт из каталога (duration_default) важнее первого элемента
          // списка: у Seedance это 15 с при диапазоне 4..15.
          final catalogDefault = _catalogDurationDefault(entry) ??
              (range?.defaultValue);
          if (catalogDefault != null) {
            _selectedDuration = catalogDefault;
          } else if (disc.isNotEmpty) {
            _selectedDuration = disc.first;
          } else if (range != null && !range.isEmpty) {
            _selectedDuration = range.min ?? range.max;
          } else {
            _selectedDuration = null;
          }
        }
      } else {
        _selectedDuration = null;
      }

      final resList = params?.resolutions ?? const <String>[];
      if (resList.isNotEmpty) {
        if (modelChanged ||
            _selectedResolution == null ||
            !resList.contains(_selectedResolution)) {
          _selectedResolution = resList.first;
        }
      } else {
        _selectedResolution = null;
      }

      final qList = params?.qualities ?? const <String>[];
      if (qList.isNotEmpty) {
        if (modelChanged ||
            _selectedQuality == null ||
            !qList.contains(_selectedQuality)) {
          _selectedQuality = qList.first;
        }
      } else {
        _selectedQuality = null;
      }
    } else {
      // Текстовая модель: медиа-параметры не применяются — сбрасываем
      // выбранные значения, чтобы они не утекли в следующий запрос.
      _selectedAspectRatio = null;
      _selectedDuration = null;
      _selectedResolution = null;
      _selectedQuality = null;
    }

    _publishMergedParams(modelId, params);
    // Задача 4: фиксируем «mandatory» для активной модели, чтобы
    // ChatService.reasoningMandatoryProbe отвечал корректно.
    _activeReasoningNorm = norm;
    _activeReasoningNoneAllowed = reasoningNoneAllowed;
    _current = ActiveModelCapabilities(
      modelId: modelId,
      normalizedId: norm,
      kind: kind,
      params: params,
      vision: vision,
      reasoning: supportsReasoning,
      reasoningLevels: reasoningLevels,
      reasoningDefault: reasoningDefault,
      reasoningNoneAllowed: reasoningNoneAllowed,
      supportsNativeSearch: nativeSearch,
    );
    debugPrint(
      '[caps] $modelId (conn: ${cid ?? 'нет'}): '
      'type=${(entry?.type.isNotEmpty ?? false) ? entry!.type : '?'}, '
      'kind=${kind.name} [$kindSource], '
      'params=${params == null ? 'нет' : params.confidence} [$paramsSource], '
      'reasoning=[${reasoningLevels.join(',')}] '
      'default=${reasoningDefault.isEmpty ? '-' : reasoningDefault} '
      'noneAllowed=$reasoningNoneAllowed '
      'resolved=$resolvedReasoningLevel [$reasoningSource]',
    );
    notifyListeners();

    if (resolvedReasoningLevel.isNotEmpty) {
      settings.applyReasoningLevel(resolvedReasoningLevel);
    }
  }

  /// Параметры генерации из записи каталога подключения
  /// ([CatalogEntry]): пропорции, разрешения, длительности, качества.
  /// null — у записи нет медиа-данных.
  static ModelParameters? _paramsFromCatalog(CatalogEntry? e) {
    final en = e;
    if (en == null) return null;
    final durs = en.durations;
    // Длительность: сначала дискретные значения каталога, затем — только
    // диапазон min..max (mediaParams duration_min/duration_max). Диапазон
    // НЕ разворачивается в выдуманный список секунд.
    final defaultValue = _catalogDurationDefault(en);
    final durationRange = durs.isNotEmpty
        ? DurationRange(
            discrete: List<int>.of(durs),
            defaultValue: defaultValue,
          )
        : _durationRangeFromCatalog(en);
    final sizes = _entrySizes(en);
    final hasAny = en.aspectRatios.isNotEmpty ||
        en.resolutions.isNotEmpty ||
        durationRange != null ||
        en.qualities.isNotEmpty ||
        sizes.isNotEmpty;
    if (!hasAny) return null;
    return ModelParameters(
      type: en.type.isEmpty ? null : en.type,
      aspectRatios: List<String>.of(en.aspectRatios),
      durations: durationRange,
      resolutions: List<String>.of(en.resolutions),
      sizes: sizes,
      qualities: List<String>.of(en.qualities),
      constraints: const <String>[],
      confidence: en.capabilitiesSource,
      isUserDefined: false,
    );
  }

  /// Размеры холста из записи каталога, если провайдер их сообщил
  /// (mediaParams['sizes']); пустой список — данных нет. Отдельного
  /// поля sizes у CatalogEntry нет, поэтому читаем терпимо из mediaParams.
  static List<String> _entrySizes(CatalogEntry e) {
    final raw = e.mediaParams['sizes'];
    if (raw is! List) return const <String>[];
    return <String>[
      for (final v in raw)
        if (v != null && v.toString().trim().isNotEmpty) v.toString().trim(),
    ];
  }

  /// Диапазон duration из mediaParams каталога (duration_min/duration_max):
  /// провайдер не перечислил значения, но задал границы. null — границ нет.
  static DurationRange? _durationRangeFromCatalog(CatalogEntry e) {
    final min = _intFromCatalog(e.mediaParams['duration_min']);
    final max = _intFromCatalog(e.mediaParams['duration_max']);
    final def = _intFromCatalog(e.mediaParams['duration_default']);
    if (min == null && max == null && def == null) return null;
    return DurationRange(min: min, max: max, defaultValue: def);
  }

  /// Значение duration по умолчанию из каталога (duration_default).
  static int? _catalogDurationDefault(CatalogEntry? e) =>
      _intFromCatalog(e?.mediaParams['duration_default']);

  /// Терпимое приведение числового значения каталога к int.
  static int? _intFromCatalog(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.round();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  /// Попадает ли значение в диапазон min..max (границы необязательны).
  static bool _inDurationRange(int? value, DurationRange? range) {
    if (value == null || range == null || range.isEmpty) return false;
    final min = range.min;
    final max = range.max;
    if (min != null && value < min) return false;
    if (max != null && value > max) return false;
    return true;
  }

  /// Вид модели: ручной override, затем каталог с
  /// [CatalogTypeSources.catalog]. Эвристики и параметры не используются.
  (ActiveModelKind, String) _kindWithCatalog(
    CatalogEntry? entry,
    String? typeOverride,
  ) {
    if (typeOverride != null) {
      return (
        switch (typeOverride) {
          'image' => ActiveModelKind.image,
          'video' => ActiveModelKind.video,
          _ => ActiveModelKind.text,
        },
        'override типа',
      );
    }
    final e = entry;
    if (e != null && e.typeSource == CatalogTypeSources.catalog) {
      final type = e.type.trim().toLowerCase();
      switch (type) {
        case 'image':
          return (ActiveModelKind.image, 'каталог (${e.capabilitiesSource})');
        case 'video':
          return (ActiveModelKind.video, 'каталог (${e.capabilitiesSource})');
        case 'chat':
          return (ActiveModelKind.text, 'каталог (${e.capabilitiesSource})');
        case 'tts':
        case 'stt':
        case 'embedding':
        case 'music':
        case 'classification':
          return (ActiveModelKind.text, 'каталог: служебный тип $type');
        default:
          return (ActiveModelKind.text, 'каталог: неизвестный тип $type');
      }
    }
    return (ActiveModelKind.text, 'тип неизвестен');
  }

  /// Копия [ModelParameters] с заменённой достоверностью данных.
  static ModelParameters _withConfidence(
    ModelParameters p,
    String confidence,
  ) {
    return ModelParameters(
      aspectRatios: List<String>.of(p.aspectRatios),
      durations: p.durations,
      resolutions: List<String>.of(p.resolutions),
      sizes: List<String>.of(p.sizes),
      qualities: List<String>.of(p.qualities),
      constraints: List<String>.of(p.constraints),
      type: p.type,
      confidence: confidence,
      isUserDefined: p.isUserDefined,
    );
  }

  /// Данные кэша Generation для модели; null — записи нет либо резолвер
  /// недоступен. Ошибки не роняют разрешение модели.
  static ModelParameters? _genCapabilityQuietly(String normId) {
    try {
      return GenerationCapabilityResolver.getCapability(normId);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _presetController.removeListener(_onPresetChanged);
    providerCatalog.removeListener(_onCatalogChanged);
    super.dispose();
  }
}

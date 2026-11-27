```dart
// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../core/catalog/provider_catalog_service.dart';
import '../core/auth/polza_auth_service.dart';
import '../core/models/active_model_capabilities.dart';
import '../core/storage.dart';
import '../models.dart';
import '../models/attachment_draft.dart';
import '../models/model_config.dart';
import '../models/tool.dart';
import '../core/generation/active_model_controller.dart';
import '../core/generation/search_capability_resolver.dart';
import '../core/generation/generation_event.dart';
import '../core/models/gen_error.dart';
import '../core/models/gen_error_mapper.dart';
import '../core/generation/generation_request.dart';
import '../core/generation/generation_service.dart';
import '../core/generation/images_api_executor.dart';
import '../core/models/cost_estimate.dart';
import '../core/models/message_part.dart';
import '../core/models/tool_media.dart';
import '../core/providers/heuristic_rules.dart';
import '../core/generation/artifact_repository.dart';
import '../core/generation/curated_parameter_catalog.dart';
import '../core/generation/model_type_override_store.dart';
import '../core/models/artifact.dart';
import '../core/utils/file_block_extractor.dart';
import '../core/generation/parameter_translator.dart';
import '../core/generation/parameter_validation_exception.dart';
import '../core/generation/user_param_override_store.dart';
import '../core/models/generation_schema.dart';
import '../core/models/param_spec.dart';
import '../features/composer/modes/image_gen_mode.dart';
import '../core/utils/reasoning_mapper.dart';
import '../core/utils/stream_pacer.dart';
import '../services/chat_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart';
import '../theme.dart';
import '../features/composer/adaptive_chat_input_bar.dart';
import '../widgets/attachment_strip.dart';
import '../widgets/message_view.dart';
import '../widgets/theme_toggle_action.dart';
import 'history_drawer.dart';
import 'live_screen.dart';
import 'quick_access_sheet.dart';
import 'settings_screen.dart';

/// Подключение, восстановленное из снимка для повтора: адрес, ключ и
/// модель именно того запроса, а не текущего выбора пользователя.
class _RetryConn {
  final String baseUrl;
  final String apiKey;
  final String model;

  const _RetryConn({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final ChatService _chatService = ChatService();

  // Щипок двумя пальцами меняет размер шрифта, а не масштаб картинки.
  final Map<int, Offset> _pts = {};
  double _startDist = 0;
  double _startSize = 17;
  bool _pinching = false;

  bool _streaming = false;

  /// Пользователь у нижнего края списка: автоскролл при стриминге
  /// разрешён, кнопка «Вниз» скрыта.
  bool _atBottom = true;

  /// Пользователь листал вверх: автоскролл стриминга заблокирован,
  /// показывается кнопка «Вниз». Сбрасывается при отправке сообщения,
  /// тапе по «Вниз» либо когда пользователь сам долистал до низа.
  bool _userScrolledUp = false;
  Timer? _uiTimer;

  /// Выбранная пропорция изображения/видео. Пустая строка — дефолт
  /// определит каталог модели; панель ввода сразу перезапишет
  /// выбранным значением из каталога.
  String _aspectRatio = '';

  /// Выбранная длительность видео в секундах (режим генерации видео).
  int? _videoDuration;

  /// Выбранное разрешение и качество генерации (чипсы панели ввода);
  /// null — не выбрано (поле в запрос не отправляется).
  String? _mediaResolution;
  String? _mediaQuality;

  /// Активный исполнитель генерации изображений (для кнопки «стоп»).
  ImagesApiExecutor? _imageExecutor;

  /// Фасад генерации: видео-модели идут через него (асинхронные задачи).
  final GenerationService _genService = GenerationService();

  /// Подписка на восстановленные задачи (после перезапуска приложения).
  StreamSubscription<GenerationEvent>? _restoreSub;

  /// Вложения, ожидающие отправки (файлы и картинки) со статусами
  /// обработки: сжатие изображений выполняется в изоляте.
  final List<AttachmentDraft> _attachments = [];

  ModelConfig get _currentConfig {
    final modelId = effectiveConfig().model.toLowerCase();
    final caps = _activeModel.current;
    if (modelId.contains('live') ||
        modelId.contains('native-audio') ||
        caps.kind == ActiveModelKind.live) {
      return const LiveVoiceModelConfig();
    }
    if (_effectiveModelType == ModelTypes.image) {
      final catalogRatios = caps.params?.aspectRatios ?? const <String>[];
      return ImageGenModelConfig(
        availableAspectRatios: catalogRatios.isNotEmpty
            ? catalogRatios
            : <String>[
                for (final c in ImageGenMode.aspectRatios) c.id,
              ],
      );
    }
    return TextModelConfig(
      supportsAttachments: true,
      supportsWebSearch:
          settings.webSearchMode != 'off' || settings.searchMode != 'off',
    );
  }

  /// Эффективный тип модели для панели ввода: override/каталог из
  /// [_modelType], затем вид из [ActiveModelController]. Ручной «текст»
  /// больше не проигрывает каталожному video/image.
  ///
  /// R6-audio-robustness-3, п.1: служебные/аудио типы каталога (tts, stt,
  /// music, embedding, classification и прочие не-'chat/image/video') не
  /// маскируются под текст — панель получает ModelTypes.unknown и может
  /// показать «неподдерживаемый тип» вместо текстового режима. Явные
  /// ручные override 'image'/'video' сохраняют приоритет (осознанный
  /// выбор пользователя), ручной 'text' — нет: маскировку под текст
  /// контроллер уже не делает, здесь тоже.
  String get _effectiveModelType {
    if (_modelType == ModelTypes.image || _modelType == ModelTypes.video) {
      return _modelType;
    }
    if (_unsupportedCatalogType(_modelType)) {
      return ModelTypes.unknown;
    }
    if (_modelType == ModelTypes.text) return _modelType;
    switch (_activeModel.current.kind) {
      case ActiveModelKind.video:
        return ModelTypes.video;
      case ActiveModelKind.image:
        return ModelTypes.image;
      default:
        return ModelTypes.text;
    }
  }

  /// Служебные/аудио типы каталога (tts, stt, music, embedding,
  /// classification и прочие не-'text/image/video') не поддерживаются
  /// в чате: панель ввода получает ModelTypes.unknown, отправка
  /// блокируется с понятной ошибкой (R6-audio-robustness-3, п.1).
  /// Тип берётся из того же резолва каталога, что и маршрут отправки.
  static bool _unsupportedCatalogType(String rawType) {
    final t = rawType.trim().toLowerCase();
    return t.isNotEmpty &&
        t != ModelTypes.text &&
        t != ModelTypes.image &&
        t != ModelTypes.video;
  }

  /// Эффективный тип активной модели ('text'/'image'/'video') для панели
  /// ввода; '' — ещё не разрешён. Обновляется при смене модели и override.
  String _modelType = '';

  /// Модель, для которой разрешён [_modelType] (защита от гонки await).
  String _typeFor = '';

  /// Хранилище пользовательских override параметров модели.
  late final UserParamOverrideStore _overrideStore;

  /// Реактивный контроллер «что умеет активная модель».
  late final ActiveModelController _activeModel;

  @override
  void initState() {
    super.initState();
    // Умный автоскролл: следим, находится ли пользователь у нижнего края.
    _scroll.addListener(_onScroll);
    // Восстановление незавершённых видео-задач после перезапуска приложения.
    _restoreSub = _genService.restorePendingJobs().listen(_onRestoredEvent);
    // Контроллер возможностей активной модели: параметры, vision, reasoning.
    _overrideStore = UserParamOverrideStore();
    _activeModel = ActiveModelController(
      presetController: presets,
      overrides: _overrideStore,
      supportsNativeSearch: SearchCapabilityResolver.supportsNativeSearch,
    );
    // Смена активной модели (пресет либо общие настройки) -> переопределение
    // эффективного типа модели для панели ввода.
    settings.addListener(_onConfigChanged);
    presets.addListener(_onConfigChanged);
    _onConfigChanged();
  }

  void _onConfigChanged() {
    final modelId = effectiveConfig().model.trim();
    if (_typeFor != modelId) {
      // Смена модели: все выбранные медиа-параметры не должны переживать
      // смену модели. Панель ввода заново сообщит дефолты из каталога.
      // Пустая строка означает «пусть тело запроса возьмёт дефолт модели».
      _aspectRatio = '';
      _videoDuration = null;
      _mediaResolution = null;
      _mediaQuality = null;
    }
    if (ActiveModelController.isHeuristicSearch(modelId) &&
        settings.searchMode == 'off') {
      settings.setSearchMode('native');
    }
    _resolveType(modelId, force: true);
    _syncActiveModel(modelId);
  }

  /// Реактивная синхронизация контроллера текущей моделью без мутации
  /// PresetStore: при переключении пресета подтягиваются параметры
  /// (aspectRatios, durations) именно модели выбранного пресета.
  Future<void> _syncActiveModel(String modelId) async {
    final id = modelId.trim();
    try {
      await _activeModel.syncModel(id);
    } catch (_) {
      // Каталог недоступен — контроллер останется с пустыми параметрами.
    }
    if (mounted) setState(() {});
  }

  /// Эффективный тип активной модели для панели ввода.
  Future<void> _resolveType(String modelId, {bool force = false}) async {
    final id = modelId.trim();
    if (!force && id == _typeFor) return;
    _typeFor = id;
    String t;
    try {
      t = await ModelTypeOverrideStore.instance.resolveType(id);
    } catch (_) {
      t = ModelTypes.unknown;
    }
    if (!mounted || _typeFor != id) return;
    setState(() => _modelType = t);
  }

  @override
  void dispose() {
    settings.removeListener(_onConfigChanged);
    presets.removeListener(_onConfigChanged);
    _activeModel.dispose();
    _restoreSub?.cancel();
    _uiTimer?.cancel();
    _imageExecutor?.cancel();
    _chatService.cancel();
    _genService.cancel();
    ttsService.stop();
    _input.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  // ---------- восстановление видео-задач ----------

  /// События восстановленных задач: обновление прогресса в карточке
  /// PendingPart, замена её на VideoPart при успехе, снятие при ошибке.
  /// Прогресс доставляется с indeterminate и диагностикой (R6, п.8):
  /// придуманный процент не выдаётся за процент провайдера.
  void _onRestoredEvent(GenerationEvent ev) {
    if (ev is GenCompleted) {
      _clearJobIdInSnapshot(ev.jobId);
      _applyToJobParts(ev.jobId, (m, idx, part) {
        final path = ev.localPath.trim();
        m.parts[idx] = path.isNotEmpty
            ? VideoPart.fromPath(path)
            : VideoPart.fromUrl(ev.remoteUrl);
      });
      store.save();
    } else if (ev is GenProgress) {
      _applyToJobParts(ev.jobId, (m, idx, part) {
        m.parts[idx] = PendingPart(
          name: part.name,
          localPath: part.localPath,
          jobId: part.jobId,
          progress: ev.percent,
          indeterminate: ev.indeterminate,
          debugSnippets: ev.debugSnippets ?? part.debugSnippets,
          debugLogPath: ev.debugLogPath ?? part.debugLogPath,
        );
      });
    } else if (ev is SourcesReceived) {
      if (_applySourcesToLatestPending(ev.sources)) {
        store.save();
      }
    } else if (ev is GenerationFailure) {
      if (ev.error.message.contains('отменена')) {
        _applyToJobParts(ev.jobId, (m, idx, part) => m.parts.removeAt(idx));
      } else {
        _applyToJobParts(ev.jobId, (m, idx, part) {
          m.parts.removeAt(idx);
          m
            ..errorCode = ev.error.code
            ..errorText = GenErrorMapper.detailsOf(ev.error);
        });
      }
      store.save();
    }
    if (mounted) setState(() {});
  }

  /// Находит первое PendingPart с данным jobId во всех чатах
  /// и применяет к нему [apply].
  void _applyToJobParts(
    String jobId,
    void Function(ChatMessage m, int idx, PendingPart part) apply,
  ) {
    final id = jobId.trim();
    if (id.isEmpty) return;
    for (final chat in store.chats) {
      for (final m in chat.messages) {
        for (int i = 0; i < m.parts.length; i++) {
          final part = m.parts[i];
          if (part is PendingPart && part.jobId == id) {
            apply(m, i, part);
            return;
          }
        }
      }
    }
  }

  /// Добавляет источники в [target], отбрасывая пустые строки и дубликаты.
  static void _mergeSources(List<String> target, Iterable<String> incoming) {
    for (final raw in incoming) {
      final url = raw.trim();
      if (url.isEmpty) continue;
      if (!target.contains(url)) target.add(url);
    }
  }

  /// Прикрепляет источники к сообщению [reply] в TextPart.
  /// Существующие TextPart (например, со стоимостью) сохраняются,
  /// источники объединяются без дублей.
  static void _attachSourcesToReply(
    ChatMessage reply,
    Iterable<String> sources,
  ) {
    final merged = <String>[];
    for (final part in reply.parts) {
      if (part is TextPart) _mergeSources(merged, part.sources);
    }
    _mergeSources(merged, sources);
    if (merged.isEmpty) return;

    for (int i = 0; i < reply.parts.length; i++) {
      final part = reply.parts[i];
      if (part is TextPart) {
        reply.parts[i] = TextPart(
          part.text,
          cost: part.cost,
          sources: List<String>.of(merged),
        );
        // Один и тот же URL не должен дублироваться в разных TextPart.
        for (int j = 0; j < reply.parts.length; j++) {
          if (j == i) continue;
          final other = reply.parts[j];
          if (other is TextPart && other.sources.isNotEmpty) {
            reply.parts[j] = TextPart(
              other.text,
              cost: other.cost,
              sources: const <String>[],
            );
          }
        }
        return;
      }
    }
    reply.parts.add(TextPart('', sources: List<String>.of(merged)));
  }

  /// Источники восстановления не несут jobId, поэтому прикрепляем их
  /// к самому свежему сообщению с ожидающей задачей.
  bool _applySourcesToLatestPending(Iterable<String> sources) {
    final merged = <String>[];
    _mergeSources(merged, sources);
    if (merged.isEmpty) return false;
    for (final chat in store.chats) {
      for (int i = chat.messages.length - 1; i >= 0; i--) {
        final m = chat.messages[i];
        if (m.role != 'assistant') continue;
        if (m.parts.any((p) => p is PendingPart)) {
          _attachSourcesToReply(m, merged);
          return true;
        }
      }
    }
    return false;
  }

  /// Сбрасывает jobId в снимке запроса после успешного завершения:
  /// повтор завершённой задачи должен создавать новую, а не
  /// возобновлять уже готовую.
  void _clearJobIdInSnapshot(String jobId) {
    final id = jobId.trim();
    if (id.isEmpty) return;
    for (final chat in store.chats) {
      for (final m in chat.messages) {
        final snap = m.generationSnapshot;
        if (snap != null && snap.jobId == id) {
          snap.jobId = '';
        }
      }
    }
  }

  // ---------- щипок ----------

  double _dist() {
    final v = _pts.values.toList();
    return (v[0] - v[1]).distance;
  }

  void _down(PointerDownEvent e) {
    _pts[e.pointer] = e.position;
    if (_pts.length == 2) {
      _startDist = _dist();
      _startSize = settings.fontSizeN.value;
      setState(() => _pinching = true);
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pts.containsKey(e.pointer)) return;
    _pts[e.pointer] = e.position;
    if (_pinching && _pts.length == 2 && _startDist > 20) {
      settings.setFontSize(_startSize * (_dist() / _startDist));
    }
  }

  void _up(PointerEvent e) {
    _pts.remove(e.pointer);
    if (_pinching && _pts.length < 2) {
      setState(() => _pinching = false);
      settings.saveNow();
    }
  }

  // ---------- прокрутка ----------

  /// Слушатель ScrollController: в пределах 80 пикселей от нижнего края
  /// пользователь считается «на дне» — автоскролл разрешён; выше —
  /// автоскролл отключается и появляется кнопка «Вниз». setState
  /// вызывается только при изменении значения, чтобы не дёргать
  /// интерфейс на каждый тик прокрутки.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atBottom = pos.pixels >= pos.maxScrollExtent - 80;
    if (atBottom != _atBottom) {
      setState(() => _atBottom = atBottom);
    }
  }

  /// Слушатель пользовательской прокрутки (UserScrollNotification):
  /// листание вперёд (палец тянется вниз по экрану — список уходит вверх)
  /// блокирует автоскролл; долистывание назад до низа (в пределах
  /// 20 пикселей от maxScrollExtent) снова включает автоскролл.
  bool _onUserScroll(UserScrollNotification notification) {
    switch (notification.direction) {
      case ScrollDirection.forward:
        if (!_userScrolledUp) {
          setState(() => _userScrolledUp = true);
        }
      case ScrollDirection.reverse:
        if (_userScrolledUp &&
            _scroll.hasClients &&
            _scroll.position.pixels >=
                _scroll.position.maxScrollExtent - 20) {
          setState(() => _userScrolledUp = false);
        }
      case ScrollDirection.idle:
        break;
    }
    return false;
  }

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _opened() {
    _atBottom = true;
    _userScrolledUp = false;
    _toEnd();
  }

  void _scheduleUi() {
    if (_uiTimer != null) return;
    _uiTimer = Timer(const Duration(milliseconds: 60), () {
      _uiTimer = null;
      if (!mounted) return;
      setState(() {});
      // Приход новых токенов: если пользователь у дна — держим список
      // прижатым к нижнему краю (после того, как кадр перестроится).
      // Если пользователь листал вверх (_userScrolledUp), автоскролл
      // не выполняется — экран не уносится вниз.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_userScrolledUp) return;
        if (_atBottom && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    });
  }

  void _snack(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Шторка «Быстрый доступ»: список моделей из пресетов и общих настроек
  /// плюс секция «Тип модели» — ручной override типа активной модели.
  void _openQuickAccess() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => QuickAccessSheet(
        onTypeChanged: (_) {
          final id = effectiveConfig().model.trim();
          _resolveType(id, force: true);
          _syncActiveModel(id);
        },
      ),
    );
  }

  // ---------- голосовой ввод ----------

  Future<void> _toggleMic() async {
    if (speechService.listening.value) {
      await speechService.stop();
      return;
    }
    try {
      await speechService.start(
        localeId: 'ru_RU',
        onText: (text) {
          if (!mounted) return;
          setState(() {
            _input.text = text;
            _input.selection = TextSelection.collapsed(offset: text.length);
          });
        },
        onError: (msg) {
          if (!mounted) return;
          _snack(msg);
        },
      );
    } on SpeechServiceException catch (e) {
      if (!mounted) return;
      _snack(e.message);
    } catch (_) {
      if (mounted) _snack('Не удалось запустить голосовой ввод');
    }
  }

  // ---------- вложения ----------

  Future<void> _attach() async {
    if (_streaming) return;
    try {
      final res = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (!mounted) return;
      if (res == null) return;
      final fresh =
          res.files.where((f) => f.path != null && f.path!.isNotEmpty).toList();
      if (fresh.isEmpty) {
        _snack('Файлы недоступны для чтения');
        return;
      }
      // Каждое вложение проходит обработку: изображения сжимаются
      // в изоляте, статус виден в чипе вложения.
      final drafts = <AttachmentDraft>[
        for (final f in fresh) AttachmentDraft(file: File(f.path!)),
      ];
      setState(() => _attachments.addAll(drafts));
      for (final d in drafts) {
        final done = await processAttachment(d);
        if (!mounted) return;
        final i = _attachments.indexOf(d);
        if (i < 0) continue;
        setState(() => _attachments[i] = done);
        final st = done.status;
        if (st == AttachmentStatus.failed || st == AttachmentStatus.tooLarge) {
          _snack(done.error ?? 'Не удалось обработать файл');
        }
      }
    } catch (_) {
      if (mounted) _snack('Не удалось открыть выбор файлов');
    }
  }

  // ---------- уровень размышлений ----------

  /// Циклическая смена уровня размышлений только по уровням, которые
  /// перечислил каталог активной модели, в исходном порядке каталога.
  /// Если модель заявляет размышления, но каталог не перечисляет уровни —
  /// уровни не выставляются: уровень не меняется, показывается короткое
  /// уведомление (капсула в панели ввода остаётся неактивной).
  void _cycleReasoning() {
    final caps = _activeModel.current;
    if (!caps.reasoning) {
      settings.setReasoningLevel(ReasoningLevel.off.id);
      return;
    }
    final allowed = caps.reasoningLevels;
    if (allowed.isEmpty) {
      // Каталог заявил размышления, но не перечислил уровни:
      // ничего не выдумываем.
      _snack('У этой модели нет размышлений');
      return;
    }
    HapticFeedback.lightImpact();
    final current = settings.reasoningLevel.trim().toLowerCase();
    var idx = -1;
    for (var i = 0; i < allowed.length; i++) {
      if (allowed[i].trim().toLowerCase() == current) {
        idx = i;
        break;
      }
    }
    final next = allowed[(idx + 1) % allowed.length];
    // 'none' не является сохраняемым идентификатором настроек:
    // приводим через ReasoningMapper.
    settings.setReasoningLevel(ReasoningMapper.fromId(next).id);
  }

  // ---------- отправка ----------

  Future<void> _send() async {
    final txt = _input.text.trim();
    final hasReady =
        _attachments.any((a) => a.status == AttachmentStatus.ready);
    if ((txt.isEmpty && !hasReady) || _streaming) return;
    if (_attachments.any((a) => a.isBusy)) return;
    if (effectiveConfig().apiKey.isEmpty) {
      _snack('Создайте и выберите профиль модели в настройках');
      return;
    }

    final modelId = effectiveConfig().model.trim();
    String genType;
    try {
      genType = await ModelTypeOverrideStore.instance.resolveType(modelId);
    } catch (_) {
      if (!mounted) return;
      await _addGenErrorBubble(
        'Не удалось определить тип модели по каталогу. '
        'Обновите каталог и повторите запрос.',
      );
      return;
    }
    if (!mounted) return;

    // R6-audio-robustness-3, п.1: служебные/аудио типы каталога (tts, stt,
    // music, embedding, classification и прочие) не маскируются под текст.
    // Без явного ручного override типа отправка блокируется с понятной
    // ошибкой; осознанный override пользователя сохраняет прежнее поведение.
    final manualTypeOverride = await _typeOverrideFor(modelId);
    if (manualTypeOverride == null && _unsupportedCatalogType(genType)) {
      await _addGenErrorBubble(
        'Модель типа «$genType» пока не поддерживается в чате — '
        'аудио-режим ещё не реализован.',
      );
      return;
    }

    if (genType == ModelTypes.image) {
      if (!await _validateGenParams(
        modelId,
        isVideo: false,
        aspectRatio: _aspectRatio,
      )) {
        return;
      }
      await _sendImage(txt);
      return;
    }
    if (genType == ModelTypes.video) {
      if (!await _validateGenParams(
        modelId,
        isVideo: true,
        aspectRatio: _aspectRatio,
        duration: _videoDuration,
      )) {
        return;
      }
      await _sendVideo(txt);
      return;
    }
    if (genType != ModelTypes.text) {
      await _addGenErrorBubble(
        'Не удалось определить тип модели по каталогу. '
        'Обновите каталог и повторите запрос.',
      );
      return;
    }

    final picked = <PickedFileRef>[
      for (final a in _attachments)
        if (a.status == AttachmentStatus.ready)
          PickedFileRef(attachmentName(a.file.path), a.file.path),
    ];
    dynamic apiContent;
    try {
      apiContent = await ChatService.buildUserContent(txt, picked);
    } catch (_) {
      apiContent = txt;
    }
    if (!mounted) return;

    final chat = store.current ?? store.createChat();
    final shown = txt.isEmpty
        ? 'Вложения: ${picked.map((f) => f.name).join(', ')}'
        : txt;
    chat.messages.add(ChatMessage(id: newId(), role: 'user', content: shown));
    if (chat.title == 'Новый чат') {
      chat.title = shown.length > 40 ? '${shown.substring(0, 40)}…' : shown;
    }
    _input.clear();
    setState(() => _attachments.clear());
    _atBottom = true;
    _userScrolledUp = false;
    await _runCompletion(chat, userApiContent: apiContent);
  }

  /// Текущий тип-переопределение модели (null — «Авто»); пишется в снимок.
  Future<String?> _typeOverrideFor(String modelId) async {
    try {
      return await ModelTypeOverrideStore.instance.loadOverride(modelId);
    } catch (_) {
      return null;
    }
  }

  /// Идентификатор активного подключения по той же логике, что
  /// GenerationService._connectionIdFor; пишется в снимок запроса и
  /// сравнивается при повторе.
  String? _snapshotConnectionId() {
    final cfg = effectiveConfig();
    return ModelTypeOverrideStore.resolveConnectionId(
      baseUrl: cfg.baseUrl,
      apiKey: cfg.apiKey,
    );
  }

  /// Восстанавливает подключение из снимка. Возвращает null, если
  /// подключение сменилось и восстановить его нельзя (тогда повтор
  /// показывает понятную ошибку, а не молча уходит в текстовый чат).
  _RetryConn? _retryConnFor(GenerationSnapshot snap) {
    final cfg = effectiveConfig();
    final snapId = snap.connectionId.trim();
    final curId = _snapshotConnectionId();
    final model = snap.modelId.trim().isNotEmpty
        ? snap.modelId.trim()
        : cfg.model.trim();

    // Снимок без id подключения (совместимость) либо совпадение с текущим:
    // используем текущие адрес и ключ.
    if (snapId.isEmpty || snapId == curId) {
      if (cfg.apiKey.trim().isEmpty) return null;
      return _RetryConn(
        baseUrl: cfg.baseUrl.trim(),
        apiKey: cfg.apiKey.trim(),
        model: model,
      );
    }

    // Подключение из снимка отличается от текущего — восстанавливаем его.
    // Polza OAuth восстанавливается независимо от активного пресета.
    if (snapId == 'polza') {
      final token =
          polzaAuth.isAuthenticated ? polzaAuth.accessToken.trim() : '';
      if (token.isEmpty) return null;
      return _RetryConn(
        baseUrl: PolzaAuthService.polzaBaseUrl,
        apiKey: token,
        model: model,
      );
    }
    // Прочие подключения (пресет/global/routerai) при смене недоступны.
    return null;
  }

  /// Понятный текст ошибки, когда подключение из снимка восстановить нельзя.
  String _retryConnectionError(GenerationSnapshot snap) {
    final id = snap.connectionId.trim();
    if (id == 'polza') {
      return 'Сессия Polza истекла. Войдите заново и повторите запрос.';
    }
    return 'Подключение, использованное для этого запроса, больше недоступно. '
        'Выберите его в настройках и повторите.';
  }

  /// Идентификатор подключения для поиска записи каталога по [baseUrl].
  /// Для Polza достаточно адреса; для остальных — текущее подключение.
  String _catalogConnectionIdFor(String baseUrl) {
    final url = baseUrl.trim().toLowerCase();
    if (url.contains('polza.ai')) return 'polza';
    return _snapshotConnectionId() ?? 'global';
  }

  /// `mediaParams` записи каталога для модели: сырые цены и условия
  /// тиров (resolution, has_video, duration и т.п.).
  Future<Map<String, dynamic>?> _mediaParamsForModel(
    String modelId, {
    String baseUrl = '',
  }) async {
    final id = modelId.trim();
    if (id.isEmpty) return null;
    try {
      final entry = await providerCatalog.lookup(
        _catalogConnectionIdFor(baseUrl),
        id,
      );
      final media = entry.mediaParams;
      if (media.isEmpty) return null;
      return <String, dynamic>{...media};
    } catch (_) {
      return null;
    }
  }

  /// Оценка с учётом сырых цен каталога и фактического выбора пользователя
  /// (resolution/duration/hasVideo), а не дефолта «наугад».
  Future<CostEstimate> _estimateWithCatalog({
    required String modelId,
    required String prompt,
    required Map<String, dynamic> parameters,
    required bool isVideo,
    String baseUrl = '',
  }) async {
    final media = await _mediaParamsForModel(modelId, baseUrl: baseUrl);
    final rawResolution = parameters[ParamKeys.resolution];
    final resolution = rawResolution?.toString().trim() ?? '';
    final rawDuration = parameters[ParamKeys.duration];
    int? duration;
    if (rawDuration is int) {
      duration = rawDuration;
    } else if (rawDuration is num) {
      duration = rawDuration.round();
    } else if (rawDuration is String) {
      duration = int.tryParse(rawDuration.trim());
    }
    return CostEstimator.estimate(
      modelId: modelId,
      prompt: prompt,
      mediaParams: media,
      resolution: resolution.isEmpty ? null : resolution,
      durationSeconds: duration,
      hasVideo: isVideo,
    );
  }

  /// Генерация изображения: результат попадает в чат как сообщение
  /// ассистента с markdown-ссылкой на изображение.
  Future<void> _sendImage(String txt) async {
    if (txt.isEmpty) {
      _snack('Опишите изображение');
      return;
    }
    final chat = store.current ?? store.createChat();
    final cfg = effectiveConfig();
    final modelId = cfg.model.trim();
    final ratio = _aspectRatio.trim();
    final params = <String, dynamic>{
      if (ratio.isNotEmpty) ParamKeys.aspectRatio: ratio,
      if ((_mediaResolution ?? '').trim().isNotEmpty)
        ParamKeys.resolution: _mediaResolution!.trim(),
      if ((_mediaQuality ?? '').trim().isNotEmpty)
        ParamKeys.quality: _mediaQuality!.trim(),
    };
    final typeOverride = await _typeOverrideFor(modelId);
    final snap = GenerationSnapshot(
      route: ModelTypes.image,
      modelId: modelId,
      connectionId: _snapshotConnectionId() ?? '',
      connectionBaseUrl: cfg.baseUrl.trim(),
      prompt: txt,
      typeOverride: typeOverride,
      parameters: params,
    );
    chat.messages.add(ChatMessage(
      id: newId(),
      role: 'user',
      content: txt,
      generationSnapshot: snap,
    ));
    if (chat.title == 'Новый чат') {
      chat.title = txt.length > 40 ? '${txt.substring(0, 40)}…' : txt;
    }
    _input.clear();
    await _generateImage(
      chat: chat,
      prompt: txt,
      conn: _RetryConn(
        baseUrl: cfg.baseUrl,
        apiKey: cfg.apiKey,
        model: modelId,
      ),
      parameters: params,
      snapshot: snap,
    );
  }

  /// Общий путь генерации изображения (используется и при отправке,
  /// и при повторе из снимка).
  Future<void> _generateImage({
    required Chat chat,
    required String prompt,
    required _RetryConn conn,
    required Map<String, dynamic> parameters,
    GenerationSnapshot? snapshot,
  }) async {
    final reply = ChatMessage(id: newId(), role: 'assistant');
    chat.messages.add(reply);
    setState(() => _streaming = true);
    store.touch(chat);
    _toEnd();

    final model = conn.model.trim();
    final rawRatio = parameters[ParamKeys.aspectRatio]?.toString().trim() ?? '';
    final aspectRatio = rawRatio.isNotEmpty ? rawRatio : '1:1';
    final estimate = await _estimateWithCatalog(
      modelId: model,
      prompt: prompt,
      parameters: parameters,
      isVideo: false,
      baseUrl: conn.baseUrl,
    );
    final resumeJobId = snapshot?.jobId.trim() ?? '';
    final executor = ImagesApiExecutor(
      aspectRatio: aspectRatio,
      resumeJobId: resumeJobId.isEmpty ? null : resumeJobId,
    );
    _imageExecutor = executor;
    final request = GenerationRequest(
      baseUrl: conn.baseUrl,
      apiKey: conn.apiKey,
      model: model,
      messages: <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': prompt},
      ],
      stream: false,
      parameters: parameters,
      estimatedUsd: estimate.estimatedUsd,
      routeHint: ModelTypes.image,
    );
    GenError? genError;
    final sources = <String>[];
    try {
      await for (final ev in executor.run(request)) {
        if (ev is GenerationDelta) {
          reply.content += ev.content;
          if (snapshot != null) snapshot.jobId = '';
        } else if (ev is SourcesReceived) {
          _mergeSources(sources, ev.sources);
        } else if (ev is GenProgress) {
          if (ev.jobId.isNotEmpty && snapshot != null) {
            snapshot.jobId = ev.jobId;
          }
        } else if (ev is GenerationFailure) {
          if (ev.jobId.isNotEmpty && snapshot != null) {
            snapshot.jobId = ev.jobId;
          }
          genError = ev.error;
        }
        _scheduleUi();
      }
    } catch (e) {
      genError = GenErrorMapper.fromException(e);
    }
    _imageExecutor = null;

    _uiTimer?.cancel();
    _uiTimer = null;
    if (genError != null) {
      reply
        ..errorCode = genError.code
        ..errorText = GenErrorMapper.detailsOf(genError);
    } else if (reply.content.isEmpty) {
      chat.messages.remove(reply);
    } else {
      // Оценка по каталогу — это предварительная оценка, а не фактическое
      // списание: в стоимость сообщения попадает только известная цена
      // каталога в рублях. Неизвестная оценка не превращается в 1,5 ₽,
      // USD не переводится фиксированным курсом — оценка и списание
      // раздельны.
      final amount = estimate.estimatedUsd;
      final currency = estimate.currency.trim().toUpperCase();
      if (estimate.isKnown &&
          amount != null &&
          amount.isFinite &&
          currency == 'RUB') {
        final imgCost = MessageCost(cost: amount, currency: 'RUB');
        reply.parts.add(TextPart('', cost: imgCost));
        _addKnownRub(chat, imgCost);
      }
    }
    if (genError == null &&
        chat.messages.contains(reply) &&
        sources.isNotEmpty) {
      _attachSourcesToReply(reply, sources);
    }
    if (!mounted) {
      await store.save();
      return;
    }
    setState(() => _streaming = false);
    store.touch(chat);
    await store.save();
  }

  /// Генерация видео: асинхронная задача с PendingPart и прогрессом.
  Future<void> _sendVideo(String txt) async {
    if (txt.isEmpty) {
      _snack('Опишите видео');
      return;
    }
    final chat = store.current ?? store.createChat();
    final cfg = effectiveConfig();
    final modelId = cfg.model.trim();
    final ratio = _aspectRatio.trim();
    final params = <String, dynamic>{
      if (ratio.isNotEmpty) ParamKeys.aspectRatio: ratio,
      if (_videoDuration != null) ParamKeys.duration: _videoDuration!,
      if ((_mediaResolution ?? '').trim().isNotEmpty)
        ParamKeys.resolution: _mediaResolution!.trim(),
      if ((_mediaQuality ?? '').trim().isNotEmpty)
        ParamKeys.quality: _mediaQuality!.trim(),
    };
    final typeOverride = await _typeOverrideFor(modelId);
    final snap = GenerationSnapshot(
      route: ModelTypes.video,
      modelId: modelId,
      connectionId: _snapshotConnectionId() ?? '',
      connectionBaseUrl: cfg.baseUrl.trim(),
      prompt: txt,
      typeOverride: typeOverride,
      parameters: params,
    );
    chat.messages.add(ChatMessage(
      id: newId(),
      role: 'user',
      content: txt,
      generationSnapshot: snap,
    ));
    if (chat.title == 'Новый чат') {
      chat.title = txt.length > 40 ? '${txt.substring(0, 40)}…' : txt;
    }
    _input.clear();
    await _generateVideo(
      chat: chat,
      prompt: txt,
      conn: _RetryConn(
        baseUrl: cfg.baseUrl,
        apiKey: cfg.apiKey,
        model: modelId,
      ),
      parameters: params,
      snapshot: snap,
    );
  }

  /// Общий путь генерации видео (/v1/media через AsyncJobExecutor,
  /// тот же, что и при обычной отправке; используется и при повторе).
  Future<void> _generateVideo({
    required Chat chat,
    required String prompt,
    required _RetryConn conn,
    required Map<String, dynamic> parameters,
    GenerationSnapshot? snapshot,
  }) async {
    final reply = ChatMessage(
      id: newId(),
      role: 'assistant',
      parts: <MessagePart>[
        PendingPart(
          name: 'Генерация видео',
          jobId: snapshot?.jobId ?? '',
        ),
      ],
    );
    chat.messages.add(reply);
    setState(() => _streaming = true);
    store.touch(chat);
    _toEnd();

    final model = conn.model.trim();
    final resumeJobId = snapshot?.jobId.trim() ?? '';
    final estimate = await _estimateWithCatalog(
      modelId: model,
      prompt: prompt,
      parameters: parameters,
      isVideo: true,
      baseUrl: conn.baseUrl,
    );
    GenError? genError;
    var cancelled = false;
    final sources = <String>[];
    try {
      final Stream<GenerationEvent> events;
      if (resumeJobId.isNotEmpty) {
        events = _genService.resumeJob(
          resumeJobId,
          baseUrl: conn.baseUrl,
          apiKey: conn.apiKey,
          model: model,
          prompt: prompt,
        );
      } else {
        final request = GenerationRequest(
          baseUrl: conn.baseUrl,
          apiKey: conn.apiKey,
          model: model,
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': prompt},
          ],
          stream: false,
          parameters: parameters,
          estimatedUsd: estimate.estimatedUsd,
          routeHint: ModelTypes.video,
        );
        events = _genService.generate(request);
      }

      await for (final ev in events) {
        if (ev is GenProgress) {
          if (ev.jobId.isNotEmpty && snapshot != null) {
            snapshot.jobId = ev.jobId;
          }
          // Диагностика и indeterminate доставляются до UI (R6, п.8):
          // PendingPart хранит и то, и другое; придуманный процент не
          // выдаётся за процент провайдера.
          _updateVideoPending(
            reply,
            jobId: ev.jobId,
            progress: ev.percent,
            indeterminate: ev.indeterminate,
            debugSnippets: ev.debugSnippets,
            debugLogPath: ev.debugLogPath,
          );
        } else if (ev is SourcesReceived) {
          _mergeSources(sources, ev.sources);
        } else if (ev is GenCompleted) {
          if (snapshot != null) snapshot.jobId = '';
          final path = ev.localPath.trim();
          reply.parts
            ..clear()
            ..add(
              path.isNotEmpty
                  ? VideoPart.fromPath(path)
                  : VideoPart.fromUrl(ev.remoteUrl),
            );
        } else if (ev is GenerationFailure) {
          if (ev.jobId.isNotEmpty && snapshot != null) {
            snapshot.jobId = ev.jobId;
          }
          if (ev.error.message.contains('отменена')) {
            cancelled = true;
          } else {
            genError = ev.error;
          }
        }
        _scheduleUi();
      }
    } catch (e) {
      genError = GenErrorMapper.fromException(e);
    }

    _uiTimer?.cancel();
    _uiTimer = null;
    if (cancelled || genError != null) {
      reply.parts.clear();
    }
    if (genError != null) {
      reply
        ..errorCode = genError.code
        ..errorText = GenErrorMapper.detailsOf(genError);
    }
    if (!cancelled && genError == null && sources.isNotEmpty) {
      _attachSourcesToReply(reply, sources);
    }
    if (reply.parts.isEmpty &&
        reply.content.isEmpty &&
        reply.errorCode.isEmpty &&
        chat.messages.isNotEmpty &&
        identical(chat.messages.last, reply)) {
      chat.messages.removeLast();
    }
    if (!mounted) {
      await store.save();
      return;
    }
    setState(() => _streaming = false);
    store.touch(chat);
    await store.save();
  }

  /// Обновляет ожидающую часть видео-задачи в сообщении [reply].
  /// Уже накопленная диагностика части сохраняется, если событие не
  /// принесло новую; indeterminate фиксируется в PendingPart (R6, п.8).
  void _updateVideoPending(
    ChatMessage reply, {
    required String jobId,
    required double progress,
    bool indeterminate = false,
    List<String>? debugSnippets,
    String? debugLogPath,
  }) {
    for (int i = 0; i < reply.parts.length; i++) {
      final part = reply.parts[i];
      if (part is PendingPart) {
        reply.parts[i] = PendingPart(
          name: part.name,
          localPath: part.localPath,
          jobId: jobId.isNotEmpty ? jobId : part.jobId,
          progress: progress,
          indeterminate: indeterminate,
          debugSnippets: debugSnippets ?? part.debugSnippets,
          debugLogPath: debugLogPath ?? part.debugLogPath,
        );
        return;
      }
    }
  }

  /// Сохраняет файлы из блоков ответа модели.
  Future<void> _materializeResponseFiles(
    ChatMessage reply,
    String modelId,
  ) async {
    final files = FileBlockExtractor.extract(reply.content);
    for (final f in files) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory('${docs.path}/GenTech/files');
        await dir.create(recursive: true);
        final safe = FileBlockExtractor.sanitizeFileName(f.filename);
        if (safe.isEmpty) continue;
        var file = File('${dir.path}/$safe');
        if (await file.exists()) {
          final dot = safe.lastIndexOf('.');
          final base = dot > 0 ? safe.substring(0, dot) : safe;
          final ext = dot > 0 ? safe.substring(dot) : '';
          file = File(
            '${dir.path}/${base}_${DateTime.now().millisecondsSinceEpoch}$ext',
          );
        }
        await file.writeAsString(f.content, flush: true);
        await ArtifactRepository.instance.register(Artifact(
          id: newId(),
          kind: Artifact.kindFile,
          localPath: file.path,
          prompt: safe,
          modelId: modelId,
        ));
      } catch (_) {
        // Диск недоступен — ответ не ломается.
      }
    }
  }

  /// Добавляет в чат сообщение-ошибку для ErrorBubble.
  Future<void> _addGenErrorBubble(String text) async {
    final chat = store.current ?? store.createChat();
    chat.messages.add(ChatMessage(
      id: newId(),
      role: 'assistant',
      errorCode: 'bad_request',
      errorText: text,
    ));
    store.touch(chat);
    if (mounted) setState(() {});
    _toEnd();
    await store.save();
  }

  /// Валидация отправки для генеративных моделей.
  Future<bool> _validateGenParams(
    String modelId, {
    required bool isVideo,
    String? aspectRatio,
    int? duration,
  }) async {
    try {
      if (!CuratedParameterCatalog.isLoaded) {
        await CuratedParameterCatalog.load();
      }
    } catch (_) {}
    ModelParameters? spec;
    try {
      spec = await ParameterTranslator.resolveParams(
        modelId,
        userParamOverrideStore,
      );
    } catch (_) {
      spec = null;
    }
    spec ??= _activeModel.current.params;
    spec ??= ActiveModelController.defaultMediaParams(
      isVideo ? ActiveModelKind.video : ActiveModelKind.image,
      HeuristicRules.normalize(modelId),
      null,
    );
    try {
      final p = UniversalParams.fromRaw(<String, dynamic>{
        if (aspectRatio != null && aspectRatio.isNotEmpty)
          ParamKeys.aspectRatio: aspectRatio,
        if (duration != null) ParamKeys.duration: duration,
      });
      if (isVideo) {
        ParameterTranslator.toVideoBody(p, spec);
      } else {
        ParameterTranslator.toImageBody(p, spec);
      }
    } on ParameterValidationException catch (e) {
      await _addGenErrorBubble(e.message);
      return false;
    }
    return true;
  }

  /// Повтор последнего запроса. Читает снимок из user-сообщения и
  /// воспроизводит ИСХОДНЫЙ маршрут: видео -> /v1/media, картинка ->
  /// images API, текст -> _runCompletion. Без снимка (старая история) —
  /// ведёт себя как раньше (текстовый повтор), без падения.
  Future<void> _regenerate() async {
    final chat = store.current;
    if (chat == null || chat.messages.isEmpty || _streaming) return;
    if (chat.messages.last.role == 'assistant') chat.messages.removeLast();
    if (chat.messages.isEmpty) return;
    _atBottom = true;
    _userScrolledUp = false;

    final last = chat.messages.last;
    final snap = last.role == 'user' ? last.generationSnapshot : null;

    // Старая история без снимка либо текстовый маршрут — как раньше.
    if (snap == null) {
      if (effectiveConfig().apiKey.isEmpty) {
        _snack('Создайте и выберите профиль модели в настройках');
        return;
      }
      await _runCompletion(chat);
      return;
    }

    final route = snap.route.trim().toLowerCase();
    if (route.isEmpty) {
      await _addGenErrorBubble(
        'Не удалось восстановить маршрут запроса из снимка. '
        'Отправьте запрос заново.',
      );
      return;
    }
    if (route == ModelTypes.text) {
      if (effectiveConfig().apiKey.isEmpty) {
        _snack('Создайте и выберите профиль модели в настройках');
        return;
      }
      await _runCompletion(chat);
      return;
    }
    if (route != ModelTypes.image && route != ModelTypes.video) {
      await _addGenErrorBubble(
        'Не удалось восстановить маршрут запроса из снимка. '
        'Отправьте запрос заново.',
      );
      return;
    }
    if (snap.prompt.trim().isEmpty) {
      await _addGenErrorBubble(
        'В снимке запроса нет промпта — отправьте запрос заново.',
      );
      return;
    }

    // Восстановление подключения из снимка: если сменилось или OAuth истёк —
    // понятная ошибка в карточке, а не молчаливый текстовый чат.
    final conn = _retryConnFor(snap);
    if (conn == null) {
      await _addGenErrorBubble(_retryConnectionError(snap));
      return;
    }

    final params = Map<String, dynamic>.of(snap.parameters);
    if (route == ModelTypes.video) {
      await _generateVideo(
        chat: chat,
        prompt: snap.prompt,
        conn: conn,
        parameters: params,
        snapshot: snap,
      );
    } else {
      await _generateImage(
        chat: chat,
        prompt: snap.prompt,
        conn: conn,
        parameters: params,
        snapshot: snap,
      );
    }
  }

  void _stop() {
    _imageExecutor?.cancel();
    _chatService.cancel();
    _genService.cancel();
  }

  Future<List<Tool>> _activeTools() async {
    try {
      final pr = presets.active;
      if (pr == null || pr.enabledToolIds.isEmpty) return const <Tool>[];
      final all = await storage.getTools();
      return [
        for (final t in all)
          if (pr.enabledToolIds.contains(t.id)) t,
      ];
    } catch (_) {
      return const <Tool>[];
    }
  }

  /// История диалога для API: полная упорядоченная цепочка вызовов
  /// инструментов сохраняется и в следующих ходах — assistant-сообщение
  /// получает `tool_calls`, следом идёт tool-ответ с `tool_call_id`.
  /// Карточки предзапроса поиска (это только UI: результат уже был
  /// встроен в system-контекст того запроса) и карточки без результата
  /// в историю не попадают.
  List<Map<String, dynamic>> _buildHistoryMessages(
    Chat chat,
    ChatMessage reply,
    EffectiveConfig cfg,
  ) {
    final msgs = <Map<String, dynamic>>[
      if (cfg.systemPrompt.trim().isNotEmpty)
        <String, dynamic>{
          'role': 'system',
          'content': '${cfg.systemPrompt.trim()}\n\n$kFileBlockInstruction',
        },
    ];
    for (final m in chat.messages) {
      if (identical(m, reply)) continue;
      if (m.isToolCall) {
        // Карточка предзапроса поиска: сам предзапрос уже встроил
        // результаты в system-контекст того запроса; tool-сообщение
        // без соответствующих tool_calls было бы некорректной историей.
        if (m.toolName == ChatService.preQueryToolName) continue;
        final result = m.toolResult.trim();
        if (m.toolName.trim().isEmpty || result.isEmpty) continue;
        final assistantIdx =
            msgs.lastIndexWhere((x) => x['role'] == 'assistant');
        if (assistantIdx < 0) continue;
        final callId = 'call_${m.id}';
        final assistant = msgs[assistantIdx];
        final rawCalls = assistant['tool_calls'];
        final calls = rawCalls is List<Map<String, dynamic>>
            ? rawCalls
            : <Map<String, dynamic>>[];
        calls.add(<String, dynamic>{
          'id': callId,
          'type': 'function',
          'function': <String, dynamic>{
            'name': m.toolName.trim(),
            'arguments':
                m.toolArgs.trim().isEmpty ? '{}' : m.toolArgs.trim(),
          },
        });
        assistant['tool_calls'] = calls;
        msgs.add(<String, dynamic>{
          'role': 'tool',
          'tool_call_id': callId,
          'content': result,
        });
        continue;
      }
      if (m.content.isEmpty) continue;
      msgs.add(<String, dynamic>{'role': m.role, 'content': m.content});
    }
    return msgs;
  }

  /// Добавляет/обновляет ожидающую медиа-часть инструмента (jobId
  /// виден для восстановления задачи после перезапуска без новой оплаты).
  void _upsertPendingToolMedia(
    ChatMessage reply,
    String jobId,
    double progress,
  ) {
    for (int i = 0; i < reply.parts.length; i++) {
      final p = reply.parts[i];
      if (p is PendingPart && p.jobId == jobId) {
        reply.parts[i] = PendingPart(
          name: p.name,
          localPath: p.localPath,
          jobId: jobId,
          progress: progress,
          debugSnippets: p.debugSnippets,
          debugLogPath: p.debugLogPath,
        );
        return;
      }
    }
    reply.parts.add(PendingPart(
      name: 'Медиа инструмента',
      jobId: jobId,
      progress: progress,
    ));
  }

  /// Убирает ожидающую медиа-часть [jobId] — инструмент завершился ошибкой.
  void _removePendingToolMedia(ChatMessage reply, String jobId) {
    for (int i = 0; i < reply.parts.length; i++) {
      final p = reply.parts[i];
      if (p is PendingPart && p.jobId == jobId) {
        reply.parts.removeAt(i);
        return;
      }
    }
  }

  /// Материализует медиа-результат инструмента в ImagePart/VideoPart
  /// в том же ответе [reply]: локальный путь — как файл, http(s)/data —
  /// как ссылка. Ожидающая часть с [pendingJobId] замещается результатом.
  void _attachToolMedia(
    ChatMessage reply,
    List<ToolMedia> media,
    String? pendingJobId,
  ) {
    final pending = pendingJobId?.trim() ?? '';
    for (final m in media) {
      final url = m.url.trim();
      if (url.isEmpty) continue;
      final kind = m.kind.trim().toLowerCase();
      final clean = url.startsWith('file://')
          ? url.substring('file://'.length)
          : url;
      final isLocal = clean.startsWith('/');
      final MessagePart part;
      if (kind == 'video') {
        part = isLocal ? VideoPart.fromPath(clean) : VideoPart.fromUrl(url);
      } else {
        part = isLocal ? ImagePart.fromPath(clean) : ImagePart.fromUrl(url);
      }
      var replaced = false;
      if (pending.isNotEmpty) {
        for (int i = 0; i < reply.parts.length; i++) {
          final p = reply.parts[i];
          if (p is PendingPart && p.jobId == pending) {
            reply.parts[i] = part;
            replaced = true;
            break;
          }
        }
      }
      if (!replaced) reply.parts.add(part);
    }
  }

  Future<void> _runCompletion(Chat chat, {dynamic userApiContent}) async {
    final reply = ChatMessage(id: newId(), role: 'assistant');
    chat.messages.add(reply);
    setState(() => _streaming = true);
    store.touch(chat);
    _toEnd();

    final cfg = effectiveConfig();
    // Уровень размышлений перечисляет только каталог активной модели:
    // выбранный уровень уходит провайдеру КАК ЕСТЬ, без ремапа (low не
    // превращается в medium, xhigh/max — в high). Выключенный уровень
    // ('off') для Polza — ЯВНЫЙ effort: none, а не отсутствие блока
    // (отсутствие блока означает поведение модели по умолчанию, не
    // обязательно «выключено»). Модель без заявленных размышлений —
    // блок не отправляется вовсе. Адаптивный reasoning (type/
    // effort_level) каталог не выражает — ничего не выдумываем.
    final caps = _activeModel.current;
    final supportsReasoning = caps.reasoning && caps.reasoningLevels.isNotEmpty;
    final String? reasoningEffort = supportsReasoning
        ? ReasoningMapper.fromId(settings.reasoningLevel).name
        : null;
    final msgs = _buildHistoryMessages(chat, reply, cfg);
    if (userApiContent != null) {
      for (int i = msgs.length - 1; i >= 0; i--) {
        if (msgs[i]['role'] == 'user') {
          msgs[i]['content'] = userApiContent;
          break;
        }
      }
    }

    ChatMessage? toolMsg;
    GenError? genError;
    /// jobId последнего прогресса медиа-инструмента: по нему ожидающая
    /// часть замещается результатом (или снимается при ошибке).
    String? pendingMediaJobId;
    // Стоимость каждого раунда (usage провайдера): раундов может быть
    // несколько (вызовы инструментов), итог собирается из всех.
    final roundCosts = <MessageCost>[];
    final sources = <String>[];
    StreamPacer? pacer;
    void onPaced() {
      if (!mounted) return;
      final shown = pacer?.shown ?? '';
      if (shown.length > reply.content.length) {
        reply.content = shown;
        _scheduleUi();
      }
    }

    try {
      final tools = await _activeTools();
      await for (final ch in _chatService.sendMessage(
        baseUrl: cfg.baseUrl,
        apiKey: cfg.apiKey,
        model: cfg.model,
        messages: msgs,
        stream: cfg.stream,
        temperature: cfg.temperature,
        reasoningEffort: reasoningEffort,
        tools: tools,
      )) {
        if (pacer == null) {
          pacer = _chatService.activePacer;
          pacer?.displayed.addListener(onPaced);
        }
        if (ch.toolName != null) {
          final jobId = (ch.toolJobId ?? '').trim();
          if (ch.toolStatus == toolStatusRunning) {
            if (jobId.isNotEmpty) {
              // Прогресс медиа-задачи инструмента: карточка ожидания
              // в том же ответе; jobId сохраняется в PendingPart для
              // возобновления после перезапуска (не новая платная задача).
              pendingMediaJobId = jobId;
              _upsertPendingToolMedia(reply, jobId, ch.toolProgress ?? 0);
            } else {
              // Начало вызова инструмента: карточка в чате.
              toolMsg = ChatMessage(
                id: newId(),
                role: 'tool_call',
                toolName: ch.toolName ?? '',
                toolArgs: ch.toolArgs ?? '',
                toolStatus: toolStatusRunning,
              );
              chat.messages.add(toolMsg);
            }
          } else {
            if (toolMsg != null) {
              toolMsg
                ..toolResult = ch.toolResult ?? ''
                ..toolStatus = ch.toolStatus ?? toolStatusDone;
            }
            // Типизированный медиа-результат инструмента: материализация
            // в ImagePart/VideoPart в том же ответе; при ошибке инструмента
            // ожидающая часть снимается, а не висит вечно.
            final media = ch.toolMedia;
            final pending = pendingMediaJobId;
            if (media != null && media.isNotEmpty) {
              _attachToolMedia(reply, media, pending);
            } else if (pending != null && pending.isNotEmpty) {
              _removePendingToolMedia(reply, pending);
            }
            pendingMediaJobId = null;
          }
          _scheduleUi();
          continue;
        }
        reply.content += ch.content;
        reply.reasoning += ch.reasoning;
        if (ch.usage != null) {
          final roundCost = MessageCost.fromUsage(ch.usage);
          if (roundCost != null) roundCosts.add(roundCost);
        }
        _mergeSources(sources, ch.sources);
        _scheduleUi();
      }
    } catch (e) {
      if (!_chatService.wasCancelled) genError = GenErrorMapper.fromException(e);
    }
    pacer?.displayed.removeListener(onPaced);

    _uiTimer?.cancel();
    _uiTimer = null;
    final err = genError;
    if (err != null) {
      reply
        ..errorCode = err.code
        ..errorText = GenErrorMapper.detailsOf(err);
    } else if (reply.content.isEmpty &&
        reply.reasoning.isEmpty &&
        reply.parts.isEmpty) {
      chat.messages.remove(reply);
    }
    if (err == null && chat.messages.contains(reply)) {
      // Итоговая стоимость всех раундов: токены суммируются всегда,
      // суммы — только при одной известной валюте у всех раундов.
      final usageCost = _sumRoundCosts(roundCosts);
      if (usageCost != null) {
        reply.parts.add(TextPart(
          '',
          cost: usageCost,
          sources: List<String>.of(sources),
        ));
        _addKnownRub(chat, usageCost);
      } else if (sources.isNotEmpty) {
        reply.parts.add(TextPart('', sources: List<String>.of(sources)));
      }
    }
    if (err == null &&
        chat.messages.contains(reply) &&
        reply.content.trim().isNotEmpty) {
      await _materializeResponseFiles(reply, cfg.model.trim());
    }
    if (!mounted) {
      await store.save();
      return;
    }
    setState(() => _streaming = false);
    store.touch(chat);
    await store.save();
    if (err == null &&
        settings.autoTts &&
        reply.content.trim().isNotEmpty) {
      ttsService.speakAuto(reply.id, reply.content);
    }
  }

  /// Прибавляет к суммарной стоимости чата только известную рублёвую
  /// сумму: неизвестная сумма (cost == null), нечисловое значение или
  /// сумма в чужой валюте не прибавляется и не переводится наугад
  /// фиксированным курсом. «Нет суммы» — это null cost, а не ноль.
  static void _addKnownRub(Chat chat, MessageCost cost) {
    final amount = cost.cost;
    if (amount == null || !amount.isFinite) return;
    if (cost.currency.trim().toUpperCase() != 'RUB') return;
    chat.totalCost += amount;
  }

  /// Итоговая стоимость раундов одного ответа: счётчики токенов
  /// складываются всегда; суммы — только когда все раунды с суммой
  /// сообщили одну и ту же известную валюту. Разные валюты (итоговая
  /// сумма не выдумывается: cost остаётся null, валюта пустая) и суммы
  /// без валюты в итоговую сумму не складываются.
  static MessageCost? _sumRoundCosts(List<MessageCost> rounds) {
    if (rounds.isEmpty) return null;
    var prompt = 0;
    var completion = 0;
    double? amount;
    var currency = '';
    var sawAmount = false;
    var conflicting = false;
    for (final c in rounds) {
      prompt += c.promptTokens;
      completion += c.completionTokens;
      // «Суммы нет» — null cost и/или пустая валюта (R6: откат
      // non-nullable адаптации, где ноль выдавался за отсутствие данных).
      final sum = c.cost;
      final cur = c.currency.trim().toUpperCase();
      if (sum == null || cur.isEmpty) continue;
      sawAmount = true;
      if (currency.isEmpty) {
        currency = cur;
        amount = sum;
      } else if (currency == cur) {
        amount = (amount ?? 0) + sum;
      } else {
        conflicting = true;
      }
    }
    if (conflicting) {
      // Суммы противоречат друг другу: итоговую сумму не выдумываем —
      // остаются только счётчики токенов (cost null, валюта пустая).
      return MessageCost(
        promptTokens: prompt,
        completionTokens: completion,
      );
    }
    if (!sawAmount) {
      // Ни один раунд не сообщил сумму: только токены, ничего не нулём.
      return MessageCost(
        promptTokens: prompt,
        completionTokens: completion,
      );
    }
    return MessageCost(
      cost: amount,
      currency: currency,
      promptTokens: prompt,
      completionTokens: completion,
    );
  }

  // ---------- интерфейс ----------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[store, settings, presets]),
      builder: (context, _) {
        final chat = store.current;
        final p = settings.palette;
        final cfg = effectiveConfig();
        final activeModel = cfg.model
            .trim()
            .replaceFirst(RegExp(r'^models/', caseSensitive: false), '');
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: 76,
            title: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  chat?.title ?? 'Новый чат',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _openQuickAccess,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border:
                          Border.all(color: p.accent.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.speed, size: 15, color: p.accent),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            activeModel.isEmpty
                                ? 'Быстрый доступ'
                                : activeModel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: fontStyle(
                              activeModel.isEmpty
                                  ? settings.bodyFont
                                  : settings.codeFont,
                              size: 12,
                              height: 1.2,
                              weight: FontWeight.w600,
                              color: p.accent,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.expand_more, size: 15, color: p.accent),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              const ThemeToggleAction(),
              IconButton(
                tooltip: 'Новый чат',
                icon: const Icon(Icons.add_comment_outlined),
                onPressed: _streaming
                    ? null
                    : () {
                        store.startNew();
                        _opened();
                      },
              ),
              IconButton(
                tooltip: 'Настройки',
                icon: const Icon(Icons.tune_rounded),
                onPressed: () {
                  ttsService.stop();
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                },
              ),
            ],
          ),
          drawer: HistoryDrawer(enabled: !_streaming, onOpened: _opened),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(child: _messages(chat, p)),
                _attachmentActions(p),
                ListenableBuilder(
                  listenable: _activeModel,
                  builder: (ctx, _) {
                    final caps = _activeModel.current;
                    final effType = _effectiveModelType;
                    final effectiveLevel =
                        (caps.reasoning && caps.reasoningLevels.isNotEmpty)
                            ? ReasoningMapper.fromId(settings.reasoningLevel)
                            : ReasoningLevel.off;
                    return AdaptiveChatInputBar(
                      key: ValueKey(caps.normalizedId + effType),
                      config: _currentConfig,
                      capabilities: caps,
                      controller: _input,
                      modelType: effType,
                      attachmentsBusy: _attachments.any((a) => a.isBusy),
                      onAspectRatioChanged: (r) => _aspectRatio = r,
                      onDurationChanged: (d) => _videoDuration = d,
                      onResolutionChanged: (r) => _mediaResolution = r,
                      onQualityChanged: (q) => _mediaQuality = q,
                      streaming: _streaming,
                      reasoningLevel: effectiveLevel.index,
                      onCycleReasoning: _cycleReasoning,
                      onToggleMic: _toggleMic,
                      onAttach: _attach,
                      onSend: _send,
                      onStop: _stop,
                      onStartLive: () {
                        ttsService.stop();
                        final key = effectiveConfig().apiKey.trim();
                        Navigator.push(
                          ctx,
                          MaterialPageRoute(
                            builder: (_) => LiveScreen(apiKey: key),
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _messages(Chat? chat, Palette p) {
    if (chat == null || chat.messages.isEmpty) return _empty(p);
    final msgs = chat.messages;
    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            child: SelectionArea(
              child: NotificationListener<UserScrollNotification>(
                onNotification: _onUserScroll,
                child: ListView.builder(
                  controller: _scroll,
                  physics: _pinching
                      ? const NeverScrollableScrollPhysics()
                      : const ClampingScrollPhysics(),
                  padding: const EdgeInsets.only(top: 4, bottom: 20),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final m = msgs[i];
                    final isLast = i == msgs.length - 1;
                    final live = _streaming && isLast && m.role == 'assistant';
                    final canRegen =
                        !_streaming && isLast && m.role == 'assistant';
                    final view = MessageView(
                      key: ValueKey(m.id),
                      message: m,
                      streaming: live,
                      onRegenerate: canRegen ? _regenerate : null,
                    );
                    if (isLast && !_streaming && m.role == 'user') {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          view,
                          Padding(
                            padding: const EdgeInsets.only(left: 12),
                            child: TextButton.icon(
                              onPressed: _regenerate,
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: const Text('Повторить запрос'),
                            ),
                          ),
                        ],
                      );
                    }
                    return view;
                  },
                ),
              ),
            ),
          ),
        ),
        if (_userScrolledUp)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              tooltip: 'Вниз',
              heroTag: 'chat_scroll_to_bottom',
              onPressed: _scrollToBottom,
              child: const Icon(Icons.arrow_downward),
            ),
          ),
      ],
    );
  }

  /// Кнопка «Вниз»: возвращает список к нижнему краю.
  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    setState(() {
      _atBottom = true;
      _userScrolledUp = false;
    });
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  /// Шторка промптов-пресетов.
  void _showPresetsSheet(BuildContext context, Palette p, List<String> prompts) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: p.surface,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Параметры и пресеты',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: p.text,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final prompt in prompts)
                    ActionChip(
                      label: Text(
                        prompt.trim(),
                        style: TextStyle(fontSize: 12, color: p.text),
                      ),
                      backgroundColor: p.card,
                      side: BorderSide(color: p.border),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _input.text = prompt;
                        _input.selection = TextSelection.collapsed(
                          offset: _input.text.length,
                        );
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty(Palette p) {
    const prompts = <String>[
      'Объясни простыми словами ',
      'Напиши чистый код для ',
      'Составь краткий план ',
    ];
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.speed, size: 40, color: p.accent),
            const SizedBox(height: 16),
            Text(
              'GenTech Chat',
              style: fontStyle(
                settings.bodyFont,
                size: 26,
                weight: FontWeight.w600,
                color: p.text,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Сведите или разведите два пальца в чате, чтобы изменить размер текста.',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
            ListenableBuilder(
              listenable: polzaAuth,
              builder: (context, _) {
                if (effectiveConfig().apiKey.trim().isNotEmpty ||
                    polzaAuth.isAuthenticated) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: FilledButton.icon(
                    onPressed: polzaAuth.isAuthenticating
                        ? null
                        : polzaAuth.startOAuthPkceFlow,
                    icon: const Icon(Icons.bolt_rounded, size: 18),
                    label: Text(
                      polzaAuth.isAuthenticating
                          ? 'Ожидание браузера…'
                          : 'Войти через Polza AI в 1 клик',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: p.accent,
                      foregroundColor: Colors.white,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final prompt in prompts.take(4))
                  ActionChip(
                    label: Text(
                      prompt.trim(),
                      style: TextStyle(fontSize: 12, color: p.text),
                    ),
                    backgroundColor: p.surface,
                    side: BorderSide(color: p.border),
                    onPressed: () {
                      _input.text = prompt;
                      _input.selection = TextSelection.collapsed(
                        offset: _input.text.length,
                      );
                    },
                  ),
                if (prompts.length > 4)
                  ActionChip(
                    avatar: Icon(Icons.tune, size: 16, color: p.accent),
                    label: Text(
                      'Параметры',
                      style: TextStyle(fontSize: 12, color: p.accent),
                    ),
                    backgroundColor: p.surface,
                    side: BorderSide(color: p.accent.withValues(alpha: 0.4)),
                    onPressed: () => _showPresetsSheet(context, p, prompts),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _attachmentActions(Palette p) {
    return AttachmentStrip(
      attachments: _attachments,
      onRemove: (i) => setState(() {
        if (i >= 0 && i < _attachments.length) _attachments.removeAt(i);
      }),
    );
  }
}
```

// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/storage.dart';
import '../models.dart';
import '../models/model_config.dart';
import '../models/tool.dart';
import '../core/generation/generation_event.dart';
import '../core/models/gen_error.dart';
import '../core/models/gen_error_mapper.dart';
import '../core/generation/generation_request.dart';
import '../core/generation/images_api_executor.dart';
import '../core/models/model_info.dart';
import '../core/providers/heuristic_rules.dart';
import '../features/composer/modes/image_gen_mode.dart';
import '../services/chat_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart';
import '../theme.dart';
import '../features/composer/adaptive_chat_input_bar.dart';
import '../widgets/message_view.dart';
import 'history_drawer.dart';
import 'live_screen.dart';
import 'settings_screen.dart';

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
  bool _stick = true;
  Timer? _uiTimer;

  /// Уровень размышлений: 0 = Low, 1 = Medium, 2 = High,
  /// 3 = xHigh, 4 = Max.
  int _reasoningLevel = 0;

  /// Выбранная пропорция изображения (режим генерации картинок).
  String _aspectRatio = '1:1';

  /// Активный исполнитель генерации изображений (для кнопки «стоп»).
  ImagesApiExecutor? _imageExecutor;

  /// Вложения, ожидающие отправки (файлы и картинки).
  final List<PlatformFile> _pending = [];

  ModelConfig get _currentConfig {
    final modelId = effectiveConfig().model.toLowerCase();
    if (modelId.contains('live') || modelId.contains('native-audio')) {
      return const LiveVoiceModelConfig();
    }
    if (_isImageModel(modelId)) {
      return ImageGenModelConfig(
        availableAspectRatios: <String>[
          for (final c in ImageGenMode.aspectRatios) c.id,
        ],
      );
    }
    return TextModelConfig(
      supportsAttachments: true,
      supportsWebSearch: settings.webSearchMode != 'off',
    );
  }

  /// Модель-картинка: маршрут генерации изображений по эвристике
  /// (dall-e, flux, imagen и т.п.). Каталог провайдера имеет приоритет,
  /// но здесь он недоступен — эвристика консервативна и безопасна.
  static bool _isImageModel(String modelId) =>
      HeuristicRules.inferRoute(HeuristicRules.normalize(modelId)) ==
      GenerationRoute.imageGeneration;

  @override
  void dispose() {
    _uiTimer?.cancel();
    _imageExecutor?.cancel();
    _chatService.cancel();
    ttsService.stop();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
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

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _opened() {
    _stick = true;
    _toEnd();
  }

  void _scheduleUi() {
    if (_uiTimer != null) return;
    _uiTimer = Timer(const Duration(milliseconds: 60), () {
      _uiTimer = null;
      if (!mounted) return;
      setState(() {});
      if (_stick) _toEnd();
    });
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Шторка «Быстрый доступ»: список доступных моделей из пресетов и общих настроек.
  void _openQuickAccess() {
    final models = <String>[];
    void addModel(String raw) {
      final m = raw.trim();
      if (m.isEmpty || models.contains(m)) return;
      models.add(m);
    }

    for (final pr in presets.items) {
      addModel(pr.model);
    }
    addModel(settings.model);

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final p = settings.palette;
        final currentModel = effectiveConfig().model.trim();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Быстрый доступ',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      if (models.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: Text(
                            'Моделей пока нет. Задайте модель в настройках провайдера.',
                            style: TextStyle(color: p.muted, fontSize: 13),
                          ),
                        )
                      else
                        for (final m in models)
                          ListTile(
                            dense: true,
                            title: Text(
                              m.replaceFirst(
                                RegExp(r'^models/', caseSensitive: false),
                                '',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: p.text,
                                fontFamily: 'JetBrains Mono',
                                fontFamilyFallback: const ['monospace'],
                              ),
                            ),
                            trailing: m == currentModel
                                ? Icon(Icons.check, size: 18, color: p.accent)
                                : null,
                            onTap: () {
                              Preset? matched;
                              for (final pr in presets.items) {
                                if (pr.model.trim() == m) {
                                  matched = pr;
                                  break;
                                }
                              }
                              if (matched != null) {
                                presets.setActive(matched.id);
                              } else {
                                settings.setConnection(mdl: m);
                                setState(() {});
                              }
                              Navigator.pop(ctx);
                            },
                          ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
      if (!mounted) return;
      _snack('Не удалось запустить голосовой ввод');
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
      setState(() => _pending.addAll(fresh));
    } catch (_) {
      if (mounted) _snack('Не удалось открыть выбор файлов');
    }
  }

  // ---------- уровень размышлений ----------

  void _cycleReasoning() {
    HapticFeedback.lightImpact();
    setState(() => _reasoningLevel = (_reasoningLevel + 1) % 5);
  }

  // ---------- отправка ----------

  Future<void> _send() async {
    final txt = _input.text.trim();
    if ((txt.isEmpty && _pending.isEmpty) || _streaming) return;
    if (effectiveConfig().apiKey.isEmpty) {
      _snack('Создайте и выберите профиль модели в настройках');
      return;
    }
    // Модель-картинка: отправка идёт через /images/generations,
    // вложения и уровень размышлений не используются.
    if (_isImageModel(effectiveConfig().model.toLowerCase())) {
      await _sendImage(txt);
      return;
    }
    final picked = <PickedFileRef>[
      for (final f in _pending)
        if (f.path != null && f.path!.isNotEmpty)
          PickedFileRef(f.name, f.path!),
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
    setState(() => _pending.clear());
    _stick = true;
    await _runCompletion(chat, userApiContent: apiContent);
  }

  /// Генерация изображения: запрос к /images/generations через
  /// [ImagesApiExecutor]. Результат приходит одним markdown-изображением
  /// (ссылка провайдера либо локальный файл) и попадает в чат как
  /// обычное сообщение ассистента.
  Future<void> _sendImage(String txt) async {
    if (txt.isEmpty) {
      _snack('Опишите изображение');
      return;
    }
    final chat = store.current ?? store.createChat();
    final reply = ChatMessage(id: newId(), role: 'assistant');
    chat.messages.add(ChatMessage(id: newId(), role: 'user', content: txt));
    chat.messages.add(reply);
    if (chat.title == 'Новый чат') {
      chat.title = txt.length > 40 ? '${txt.substring(0, 40)}…' : txt;
    }
    _input.clear();
    setState(() => _streaming = true);
    store.touch(chat);
    _toEnd();

    final cfg = effectiveConfig();
    final executor = ImagesApiExecutor(aspectRatio: _aspectRatio);
    _imageExecutor = executor;
    final request = GenerationRequest(
      baseUrl: cfg.baseUrl,
      apiKey: cfg.apiKey,
      model: cfg.model,
      messages: <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': txt},
      ],
      stream: false,
    );
    GenError? genError;
    try {
      await for (final ev in executor.run(request)) {
        if (ev is GenerationDelta) {
          reply.content += ev.content;
        } else if (ev is GenerationFailure) {
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
      // Ошибка генерации изображения: карточка ErrorBubble в чате
      // вместо снекбара, с возможностью повторить запрос.
      reply
        ..errorCode = genError.code
        ..errorText = GenErrorMapper.detailsOf(genError);
    } else if (reply.content.isEmpty) {
      chat.messages.remove(reply);
    }
    if (!mounted) {
      await store.save();
      return;
    }
    setState(() => _streaming = false);
    store.touch(chat);
    await store.save();
  }

  Future<void> _regenerate() async {
    final chat = store.current;
    if (chat == null || chat.messages.isEmpty || _streaming) return;
    if (effectiveConfig().apiKey.isEmpty) {
      _snack('Создайте и выберите профиль модели в настройках');
      return;
    }
    if (chat.messages.last.role == 'assistant') chat.messages.removeLast();
    if (chat.messages.isEmpty) return;
    _stick = true;
    await _runCompletion(chat);
  }

  void _stop() {
    _imageExecutor?.cancel();
    _chatService.cancel();
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

  Future<void> _runCompletion(Chat chat, {dynamic userApiContent}) async {
    final reply = ChatMessage(id: newId(), role: 'assistant');
    chat.messages.add(reply);
    setState(() => _streaming = true);
    store.touch(chat);
    _toEnd();

    final cfg = effectiveConfig();
    final String? reasoningEffort = switch (_reasoningLevel) {
      1 => 'medium',
      2 => 'high',
      _ => null,
    };
    final msgs = <Map<String, dynamic>>[
      if (cfg.systemPrompt.trim().isNotEmpty)
        <String, dynamic>{
          'role': 'system',
          'content': '${cfg.systemPrompt.trim()}\n\n$kFileBlockInstruction',
        },
      for (final m in chat.messages)
        if (!identical(m, reply) && !m.isToolCall && m.content.isNotEmpty)
          <String, dynamic>{'role': m.role, 'content': m.content},
    ];
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
        if (ch.toolName != null) {
          if (ch.toolStatus == toolStatusRunning) {
            toolMsg = ChatMessage(
              id: newId(),
              role: 'tool_call',
              toolName: ch.toolName ?? '',
              toolArgs: ch.toolArgs ?? '',
              toolStatus: toolStatusRunning,
            );
            chat.messages.add(toolMsg);
          } else if (toolMsg != null) {
            toolMsg
              ..toolResult = ch.toolResult ?? ''
              ..toolStatus = ch.toolStatus ?? toolStatusDone;
          }
          _scheduleUi();
          continue;
        }
        reply.content += ch.content;
        reply.reasoning += ch.reasoning;
        _scheduleUi();
      }
    } catch (e) {
      if (!_chatService.wasCancelled) genError = GenErrorMapper.fromException(e);
    }

    _uiTimer?.cancel();
    _uiTimer = null;
    final err = genError;
    if (err != null) {
      // Ошибка сохраняется в самом сообщении и отображается через
      // ErrorBubble (MessageView читает errorCode/errorText): карточка
      // с иконкой, текстом и одной контекстной кнопкой «Повторить».
      reply
        ..errorCode = err.code
        ..errorText = GenErrorMapper.detailsOf(err);
    } else if (reply.content.isEmpty && reply.reasoning.isEmpty) {
      chat.messages.remove(reply);
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
                        Icon(Icons.auto_awesome, size: 13, color: p.accent),
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
                AdaptiveChatInputBar(
                  config: _currentConfig,
                  controller: _input,
                  onAspectRatioChanged: (r) => _aspectRatio = r,
                  streaming: _streaming,
                  reasoningLevel: _reasoningLevel,
                  onCycleReasoning: _cycleReasoning,
                  onToggleMic: _toggleMic,
                  onAttach: _attach,
                  onSend: _send,
                  onStop: _stop,
                  onStartLive: () {
                    ttsService.stop();
                    final key = effectiveConfig().apiKey.trim();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LiveScreen(apiKey: key),
                      ),
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
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.axis == Axis.vertical) {
            _stick = n.metrics.extentAfter < 140;
          }
          return false;
        },
        child: SelectionArea(
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
              final canRegen = !_streaming && isLast && m.role == 'assistant';
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
    );
  }

  Widget _empty(Palette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 36, color: p.accent),
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
            const SizedBox(height: 16),
            Text(
              'Сведите или разведите два пальца в чате, чтобы изменить размер текста.',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _attachmentActions(Palette p) {
    if (_pending.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: SizedBox(
        height: 44,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: _pending.length,
          itemBuilder: (context, i) {
            final f = _pending[i];
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InputChip(
                label: Text(
                  f.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: p.text),
                ),
                deleteIconColor: p.muted,
                onDeleted: () => setState(() => _pending.removeAt(i)),
              ),
            );
          },
        ),
      ),
    );
  }
}

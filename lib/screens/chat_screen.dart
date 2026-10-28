// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/storage.dart';
import '../models.dart';
import '../models/tool.dart';
import '../services/chat_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart';
import '../theme.dart';
import '../widgets/message_view.dart';
import '../widgets/mic_button.dart';
import 'history_drawer.dart';
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

  // Щипок двумя пальцами: меняем размер шрифта, а не масштаб картинки.
  final Map<int, Offset> _pts = {};
  double _startDist = 0;
  double _startSize = 17;
  bool _pinching = false;

  bool _streaming = false;
  bool _reasoningEnabled = false;
  bool _stick = true;
  Timer? _uiTimer;

  // Вложения, ожидающие отправки (файлы и картинки).
  final List<PlatformFile> _pending = [];

  // Голосовой ввод: базовый текст поля на момент старта записи.
  String _speechBase = '';

  @override
  void dispose() {
    _uiTimer?.cancel();
    _chatService.cancel();
    ttsService.stop();
    speechService.stop();
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

  // ---------- вложения ----------

  Future<void> _attach() async {
    if (_streaming) return;
    try {
      final res = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (!mounted) return;
      if (res == null) return; // пользователь отменил выбор
      final fresh = res.files
          .where((f) => f.path != null && f.path!.isNotEmpty)
          .toList();
      if (fresh.isEmpty) {
        _snack('Файлы недоступны для чтения');
        return;
      }
      setState(() => _pending.addAll(fresh));
    } catch (_) {
      if (mounted) _snack('Не удалось открыть выбор файлов');
    }
  }

  // ---------- голосовой ввод ----------

  /// Старт/стоп распознавания речи. Распознанный текст вставляется
  /// в поле ввода по мере поступления; ошибки показываются снекбаром.
  Future<void> _toggleSpeech() async {
    if (speechService.listening.value) {
      await speechService.stop();
      return;
    }
    _speechBase = _input.text;
    try {
      await speechService.start(
        localeId: 'ru_RU',
        onText: (text) {
          if (!mounted) return;
          final base = _speechBase.trim();
          final full = base.isEmpty ? text : '$base $text';
          _input.text = full;
          _input.selection = TextSelection.collapsed(offset: full.length);
        },
        onError: (msg) {
          if (mounted) _snack(msg);
        },
      );
    } on SpeechServiceException catch (e) {
      if (mounted) _snack(e.message);
    } catch (_) {
      if (mounted) _snack('Не удалось запустить распознавание речи');
    }
  }

  // ---------- отправка ----------

  Future<void> _send() async {
    final txt = _input.text.trim();
    if ((txt.isEmpty && _pending.isEmpty) || _streaming) return;
    if (effectiveConfig().apiKey.isEmpty) {
      _snack('Создайте и выберите профиль модели в настройках');
      return;
    }
    final picked = <PickedFileRef>[
      for (final f in _pending)
        if (f.path != null && f.path!.isNotEmpty) PickedFileRef(f.name, f.path!),
    ];
    // Готовим content для API (base64-картинки, текст файлов) заранее:
    // любые ошибки чтения уже обработаны внутри, отправка не падает.
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

  void _stop() => _chatService.cancel();

  /// Активные инструменты: разрешённые в текущем пресете.
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

  Future<void> _runCompletion(
    Chat chat, {
    dynamic userApiContent,
  }) async {
    final reply = ChatMessage(id: newId(), role: 'assistant');
    chat.messages.add(reply);
    setState(() => _streaming = true);
    store.touch(chat);
    _toEnd();

    final cfg = effectiveConfig();
    final reasoningEffort = _reasoningEnabled ? 'high' : null;
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
    // Для последнего пользовательского сообщения подставляем расширенный
    // content (base64-картинки и содержимое текстовых файлов).
    if (userApiContent != null) {
      for (int i = msgs.length - 1; i >= 0; i--) {
        if (msgs[i]['role'] == 'user') {
          msgs[i]['content'] = userApiContent;
          break;
        }
      }
    }

    ChatMessage? toolMsg;
    String? error;
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
          // Специальное сообщение-вызов инструмента: создаётся при старте
          // вызова и обновляется по завершении (готово/ошибка).
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
    } on ChatServiceException catch (e) {
      error = e.message;
    } catch (e) {
      if (!_chatService.wasCancelled) error = 'Ошибка соединения: $e';
    }

    _uiTimer?.cancel();
    _uiTimer = null;
    if (reply.content.isEmpty && reply.reasoning.isEmpty) {
      chat.messages.remove(reply);
    }
    if (!mounted) {
      await store.save();
      return;
    }
    setState(() => _streaming = false);
    store.touch(chat);
    await store.save();
    // Автоозвучка: читаем готовый ответ вслух, не блокируя интерфейс.
    if (error == null && settings.autoTts && reply.content.trim().isNotEmpty) {
      ttsService.speakAuto(reply.id, reply.content);
    }
    if (error != null) _snack(error);
  }

  // ---------- интерфейс ----------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[store, settings, presets]),
      builder: (context, _) {
        final chat = store.current;
        final p = settings.palette;
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: 76,
            title: Text(
              chat?.title ?? 'Новый чат',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600),
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
                  // Озвучка не должна продолжаться на другом экране.
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
                _inputBar(p),
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

  /// Чипы выбранных файлов над полем ввода. Кнопка-скрепка переехала
  /// в панель ввода, поэтому при пустом списке строка не занимает места.
  Widget _attachmentActions(Palette p) {
    if (_pending.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Прикрепить файл',
            icon: Icon(Icons.attach_file, size: 22, color: p.muted),
            onPressed: _streaming ? null : _attach,
          ),
          Expanded(child: _attachmentsBar(p)),
        ],
      ),
    );
  }

  /// Чипы выбранных файлов над полем ввода: имя и кнопка удаления.
  Widget _attachmentsBar(Palette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: SizedBox(
        height: 46,
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

  /// Поле ввода: капсула с плавной анимацией высоты (AnimatedSize).
  /// Внутри — два яруса: сверху текст на всю ширину, снизу ряд иконок
  /// (скрепка, мозг, микрофон) и круглая кнопка отправки справа.
  Widget _inputBar(Palette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.bottomCenter,
        child: Container(
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: p.border),
          ),
          padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Верхний ярус: текст на всю ширину капсулы.
              TextField(
                controller: _input,
                minLines: 1,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                cursorColor: p.accent,
                style: fontStyle(settings.bodyFont, size: 16, color: p.text),
                decoration: InputDecoration(
                  hintText: 'Сообщение',
                  hintStyle: TextStyle(color: p.muted),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                ),
              ),
              // Нижний ярус: иконки слева, отправка справа. Левый отступ
              // меньше отступа текста: иконка центрируется внутри кнопки
              // 44dp и визуально встаёт на одну вертикаль с текстом.
              Padding(
                padding: const EdgeInsets.only(left: 3, right: 2, bottom: 2),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Прикрепить файл',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 44,
                      ),
                      visualDensity: VisualDensity.compact,
                      iconSize: 22,
                      icon: Icon(Icons.attach_file, size: 22, color: p.muted),
                      onPressed: _streaming ? null : _attach,
                    ),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 44,
                      ),
                      visualDensity: VisualDensity.compact,
                      tooltip: _reasoningEnabled
                          ? 'Выключить подробные размышления'
                          : 'Включить подробные размышления',
                      isSelected: _reasoningEnabled,
                      icon: Icon(
                        Icons.psychology,
                        size: 22,
                        color: _reasoningEnabled
                            ? const Color(0xFFE53935)
                            : p.muted,
                      ),
                      onPressed: _streaming
                          ? null
                          : () => setState(() {
                                _reasoningEnabled = !_reasoningEnabled;
                              }),
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: speechService.listening,
                      builder: (context, listening, _) => MicButton(
                        listening: listening,
                        onTap: _streaming ? null : _toggleSpeech,
                        mutedColor: p.muted,
                      ),
                    ),
                    const Spacer(),
                    IconButton.filled(
                      onPressed: _streaming ? _stop : _send,
                      style: IconButton.styleFrom(
                        backgroundColor: p.accent,
                        foregroundColor: Colors.white,
                      ),
                      icon: Icon(
                        _streaming
                            ? Icons.stop_rounded
                            : Icons.arrow_upward_rounded,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

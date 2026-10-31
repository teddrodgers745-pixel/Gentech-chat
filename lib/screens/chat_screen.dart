// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
import 'presets_sheet.dart';
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

  /// Вложения, ожидающие отправки (файлы и картинки).
  final List<PlatformFile> _pending = [];

  /// Подписи уровней мышления (строго на английском).
  static const List<String> _reasoningLabels = <String>[
    'Low',
    'Medium',
    'High',
    'xHigh',
    'Max',
  ];

  /// Единый радиус скругления панели ввода и капсулы: без прямых углов
  /// и без артефактов нахлёстов.
  static const double _radius = 24;

  /// Цвет заливки капсулы «Мышление» зависит от выбранного уровня:
  /// Low — спокойный тёплый графит, Medium — насыщенный терракотовый,
  /// High — благородный терракотово-кирпичный Color(0xFFB85D4B),
  /// xHigh — глубокий терракотово-кирпичный, Max — жжёный тёмный кирпич.
  static const List<Color> _reasoningFills = <Color>[
    Color(0xFF71594B), // Low — спокойный, гармоничный к палитре
    Color(0xFFC07650), // Medium — насыщенный терракотовый
    Color(0xFFB85D4B), // High — благородный терракотово-кирпичный
    Color(0xFF9C4A34), // xHigh — глубокий терракотово-кирпичный
    Color(0xFF7D3524), // Max — жжёный тёмный кирпич
  ];

  /// Цвет подписи уровня мышления. Подпись обязана читаться на своей
  /// заливке, поэтому Low — янтарный, Medium — светло-синий, High —
  /// тёплый белый: тёмно-синий на терракоте и красный на красном
  /// сливались бы с фоном капсулы. xHigh — светлая медь, Max — тёплый
  /// кремовый: оба хорошо читаются на тёмных кирпичных заливках.
  static const List<Color> _reasoningLevelColors = <Color>[
    Color(0xFFFFC107), // Low — янтарный, читается на тёплом графите
    Color(0xFFBFDBFE), // Medium — светло-синий, читается на терракоте
    Color(0xFFFFF4F0), // High — тёплый белый, читается на терракотово-кирпичном
    Color(0xFFFFCF9E), // xHigh — светлая медь, читается на глубоком кирпичном
    Color(0xFFFFEFD9), // Max — тёплый кремовый, читается на жжёном кирпиче
  ];

  /// Светло-синяя заливка капсулы «Поиск» (включённое состояние).
  static const Color _searchFill = Color(0xFF3B82F6);

  /// Светлый текст и иконка на синей заливке.
  static const Color _searchTextOn = Color(0xFFF3F7FF);

  @override
  void dispose() {
    _uiTimer?.cancel();
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

  /// Шторка выбора пресета (модели): список всех профилей подключения.
  void _openPresets() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const PresetsSheet(),
    );
  }

  // ---------- голосовой ввод ----------

  /// Кнопка микрофона: старт/стоп распознавания речи. Распознанный текст
  /// подставляется в поле ввода, промежуточные результаты видны сразу.
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
      if (res == null) return; // пользователь отменил выбор
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
    final picked = <PickedFileRef>[
      for (final f in _pending)
        if (f.path != null && f.path!.isNotEmpty)
          PickedFileRef(f.name, f.path!),
    ];
    // content для API (base64-картинки, текст файлов) готовим заранее:
    // ошибки чтения уже обработаны внутри, отправка не падает.
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

  Future<void> _runCompletion(Chat chat, {dynamic userApiContent}) async {
    final reply = ChatMessage(id: newId(), role: 'assistant');
    chat.messages.add(reply);
    setState(() => _streaming = true);
    store.touch(chat);
    _toEnd();

    final cfg = effectiveConfig();
    // Low — поле не отправляется (прежнее поведение),
    // Medium и High — соответствующие значения reasoning_effort.
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
          // Сообщение-вызов инструмента: создаётся на старте вызова
          // и обновляется по завершению (готово/ошибка).
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
                PresetChip(onTap: _openPresets),
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

  /// Чипы выбранных файлов над полем ввода: имя и кнопка удаления.
  /// Скрепка живёт в самой панели ввода, поэтому при пустом списке
  /// строка не занимает места.
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

  /// Нижняя панель ввода: единая капсула с плавной анимацией высоты.
  /// Контейнер, его фон и капсулы используют один и тот же радиус
  /// [_radius] — прямоугольных нахлёстов и торчащих уголков нет.
  /// Сверху — текстовое поле на всю ширину капсулы, снизу — ряд
  /// с капсулами «Мышление» и «Поиск», скрепкой и круглой кнопкой.
  /// Строка печати принудительно поднята к верхней границе поля:
  /// верхний отступ contentPadding уменьшен до 2.
  Widget _inputBar(Palette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 160),
        alignment: Alignment.bottomCenter,
        // Тень должна выходить за границы капсулы, поэтому без обрезки.
        clipBehavior: Clip.none,
        child: Container(
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(_radius),
            border: Border.all(color: p.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 15,
                spreadRadius: 1,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 14,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          // Дети обрезаются по скруглению капсулы: ничего не торчит.
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Верхний ярус: текст на всю ширину капсулы.
              // filled: false убирает прямоугольную заливку из темы.
              // contentPadding: верх уменьшен до 2 — строка ввода
              // принудительно приподнята к верхней границе поля.
              TextField(
                controller: _input,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                cursorColor: p.accent,
                style: fontStyle(settings.bodyFont, size: 16, color: p.text),
                decoration: const InputDecoration(
                  isDense: true,
                  filled: false,
                  hintText: 'Сообщение',
                  hintStyle: TextStyle(color: Color(0xFFA8A096)),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.fromLTRB(16, 2, 16, 11.6),
                ),
                minLines: 1,
                maxLines: 6,
              ),
              // «Воздух» между полем и рядом нижних кнопок: капсулы
              // опущены чуть ниже, чтобы не прилипали к тексту.
              const SizedBox(height: 13.3),
              // Нижний ярус: капсулы слева, скрепка и отправка справа.
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _reasoningCapsule(),
                          const SizedBox(width: 8),
                          _searchCapsule(p),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _attachButton(p),
                  const SizedBox(width: 2),
                  ValueListenableBuilder<bool>(
                    valueListenable: speechService.listening,
                    builder: (context, listening, _) => MicButton(
                      listening: listening,
                      onTap: _streaming ? null : _toggleMic,
                      mutedColor: p.muted,
                    ),
                  ),
                  const SizedBox(width: 2),
                  _sendButton(p),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Кнопка скрепки: выбор файлов для отправки.
  Widget _attachButton(Palette p) {
    return IconButton(
      tooltip: 'Прикрепить файл',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      visualDensity: VisualDensity.compact,
      iconSize: 26,
      icon: Icon(Icons.attach_file, size: 26, color: p.muted),
      onPressed: _streaming ? null : _attach,
    );
  }

  /// Круглая акцентная кнопка: отправка сообщения или остановка ответа.
  Widget _sendButton(Palette p) {
    return IconButton.filled(
      tooltip: _streaming ? 'Остановить' : 'Отправить',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      onPressed: _streaming ? _stop : _send,
      style: IconButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
      ),
      icon: Icon(
        _streaming ? Icons.stop_rounded : Icons.rocket_launch_rounded,
        size: 26,
      ),
    );
  }

  /// Капсула «Мышление»: циклический выбор уровня Low -> Medium -> High
  /// -> xHigh -> Max. Заливка капсулы меняется вместе с уровнем
  /// (см. [_reasoningFills]).
  /// Слева от подписи — значок уровня 32, выровнен по центру капсулы.
  /// Единый линейный комплект иконок по нарастанию накала мысли:
  /// Low -> Icons.speed (лёгкий, быстрый ход),
  /// Medium -> Icons.lightbulb_outline (осмысленная глубина),
  /// High -> Icons.troubleshoot (высокий накал),
  /// xHigh -> прежняя картинка мозга (assets/icons/brain_high.png, 32x32),
  /// Max -> Icons.biotech. Значки красятся цветом уровня.
  Widget _reasoningCapsule() {
    final label = _reasoningLabels[_reasoningLevel];
    final fill = _reasoningFills[_reasoningLevel];
    final levelColor = _reasoningLevelColors[_reasoningLevel];
    final Widget leading;
    if (_reasoningLevel == 0) {
      // Low: «спидометр» цвета уровня — лёгкий, быстрый режим.
      leading = Icon(Icons.speed, size: 32, color: levelColor);
    } else if (_reasoningLevel == 1) {
      // Medium: «лампочка» цвета уровня — средняя глубина.
      leading = Icon(Icons.lightbulb_outline, size: 32, color: levelColor);
    } else if (_reasoningLevel == 2) {
      // High: «поиск неполадок» цвета уровня — высокий накал.
      leading = Icon(Icons.troubleshoot, size: 32, color: levelColor);
    } else if (_reasoningLevel == 4) {
      // Max: вместо картинки мозга — иконка «биотех» цвета уровня.
      leading = Icon(Icons.biotech, size: 32, color: levelColor);
    } else {
      // xHigh: прежняя картинка мозга 32x32 — без изменений.
      leading = Image.asset(
        'assets/icons/brain_high.png',
        width: 32,
        height: 32,
        fit: BoxFit.contain,
      );
    }
    return Tooltip(
      message: 'Уровень размышлений: $label',
      child: InkWell(
        borderRadius: BorderRadius.circular(_radius),
        onTap: _streaming ? null : _cycleReasoning,
        child: Container(
          height: 36,
          constraints: const BoxConstraints(minWidth: 112),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(_radius),
            border: Border.all(color: fill),
            boxShadow: [
              BoxShadow(
                color: fill.withValues(alpha: 0.35),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            // Значок и подпись выровнены по вертикальному центру капсулы.
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              leading,
              const SizedBox(width: 6),
              Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: levelColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Капсула «Поиск».
  /// Текст ВСЕГДА просто 'Поиск'. Без AnimatedSize, только AnimatedContainer
  /// для изменения цвета фона (синий при включении, прозрачный при выключении).
  /// Ширина капсулы слегка увеличена вправо (горизонтальный padding увеличен до 13).
  Widget _searchCapsule(Palette p) {
    final on = settings.webSearchEnabled;
    return InkWell(
      borderRadius: BorderRadius.circular(_radius),
      onTap: _streaming
          ? null
          : () {
              HapticFeedback.lightImpact();
              setState(() => settings.setWebSearch(!on));
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: 36,
        padding: const EdgeInsets.only(left: 12, right: 24),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: on ? _searchFill : Colors.transparent,
          borderRadius: BorderRadius.circular(_radius),
          border: Border.all(color: on ? _searchFill : p.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/icons/search.svg',
              width: 20,
              height: 20,
              colorFilter: ColorFilter.mode(
                on ? _searchTextOn : p.muted,
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Поиск',
              maxLines: 1,
              style: TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: on ? _searchTextOn : p.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

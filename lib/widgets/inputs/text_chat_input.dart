// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../app_state.dart';
import '../../core/models/active_model_capabilities.dart';
import '../../core/search/search_strategy.dart';
import '../../core/utils/reasoning_mapper.dart';
import '../../features/composer/widgets/reasoning_sheet.dart';
import '../../models/model_config.dart';
import '../../screens/settings_screen.dart';
import '../../theme.dart';

/// Панель текстового ввода чата: капсула с полем сообщения,
/// капсулами мышления и поиска, микрофоном, скрепкой и кнопкой отправки.
class TextChatInput extends StatefulWidget {
  final TextModelConfig config;

  /// Возможности активной модели (vision, reasoning, параметры генерации).
  final ActiveModelCapabilities capabilities;
  final TextEditingController? controller;
  final bool streaming;
  final int reasoningLevel;
  final VoidCallback? onCycleReasoning;
  final VoidCallback? onToggleSearch;
  final VoidCallback? onToggleMic;
  final VoidCallback? onAttach;
  final VoidCallback? onSend;
  final VoidCallback? onStop;

  /// Есть ли вложения в обработке: кнопка «Отправить» неактивна.
  final bool attachmentsBusy;

  const TextChatInput({
    super.key,
    this.config = const TextModelConfig(),
    required this.capabilities,
    this.controller,
    this.streaming = false,
    this.reasoningLevel = 0,
    this.onCycleReasoning,
    this.onToggleSearch,
    this.onToggleMic,
    this.onAttach,
    this.onSend,
    this.onStop,
    this.attachmentsBusy = false,
  });

  @override
  State<TextChatInput> createState() => _TextChatInputState();
}

class _TextChatInputState extends State<TextChatInput> {
  TextEditingController? _internalController;

  /// Фокус поля сообщения: капсула подсвечивает обводку акцентом.
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  static const double _radius = 24;

  /// Фоны и цвета текста капсулы для каждого из шести уровней
  /// ([ReasoningLevel]): off — серый, low — синий, medium — оранжевый,
  /// high — фиолетовый, xhigh — пурпурный, max — тёплый медный.
  static const List<Color> _reasoningFills = <Color>[
    Color(0xFF3A3733), // off — серый
    Color(0xFF2D5A88), // low — синий
    Color(0xFFB05A28), // medium — оранжевый
    Color(0xFF6C3FA0), // high — фиолетовый
    Color(0xFF8E2D5E), // xhigh — пурпурный
    Color(0xFF8A5A2B), // max — тёплый медный
  ];

  static const List<Color> _reasoningLevelColors = <Color>[
    Color(0xFFA8A096), // off — серый
    Color(0xFFBFDBFE), // low — голубой
    Color(0xFFFFD9B3), // medium — тёплый оранжевый
    Color(0xFFE5D4FF), // high — светло-фиолетовый
    Color(0xFFF7C7E2), // xhigh — светло-розовый
    Color(0xFFF3DDB9), // max — тёплый песочный
  ];

  static const Color _searchFill = Color(0xFF3B82F6);
  static const Color _searchTextOn = Color(0xFFF3F7FF);

  /// Локальный флаг поиска для текущего чата: включается капсулой,
  /// только если в настройках выбран режим поиска (не off).
  bool _searchOn = false;

  TextEditingController get _effectiveController =>
      widget.controller ?? (_internalController ??= TextEditingController());



  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _internalController?.dispose();
    super.dispose();
  }

  /// Тап по капсуле: циклическая смена уровня размышлений
  /// (off -> low -> medium -> high -> off). Выбор сохраняется в настройках
  /// (settings.reasoningLevel) и применяется к следующим запросам.
  void _cycleLevel() {
    final cb = widget.onCycleReasoning;
    if (cb != null) {
      cb();
      return;
    }
    HapticFeedback.lightImpact();
    settings.setReasoningLevel(
      ReasoningMapper.fromId(settings.reasoningLevel).next().id,
    );
  }

  /// Долгое нажатие по капсуле: шторка со слайдером уровней размышлений.
  /// Список позиций — уровни, которые разрешает активная модель
  /// ([ActiveModelCapabilities.reasoningLevels]); выбор сохраняется
  /// в настройках (settings.reasoningLevel).
  void _openReasoningSheet() {
    HapticFeedback.lightImpact();
    final levels = ReasoningMapper.levelsFromNames(
      widget.capabilities.reasoningLevels,
    );
    showReasoningSheet(
      context,
      levels: levels.isEmpty
          ? const <ReasoningLevel>[
              ReasoningLevel.off,
              ReasoningLevel.low,
              ReasoningLevel.medium,
              ReasoningLevel.high,
              ReasoningLevel.xhigh,
              ReasoningLevel.max,
            ]
          : levels,
      currentId: settings.reasoningLevel,
    );
  }

  /// Тап по капсуле «Поиск». Логика по режиму из настроек
  /// (settings.searchMode):
  ///  - off — капсула серая, поиск НЕ включается: SnackBar с подсказкой
  ///    и кнопкой «Настроить» (переход в экран настроек);
  ///  - любой другой режим — переключение локального флага текущего
  ///    чата (ярко-синяя капсула <-> бледно-синяя).
  void _handleToggleSearch() {
    HapticFeedback.lightImpact();
    final mode = SearchModes.fromId(settings.searchMode);
    if (mode == SearchMode.off) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: const Text('Выберите режим поиска в настройках'),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: 'Настроить',
            onPressed: _openSearchSettings,
          ),
        ),
      );
      return;
    }
    setState(() => _searchOn = !_searchOn);
    widget.onToggleSearch?.call();
  }

  /// Переход в настройки (секция «Поиск» находится на экране настроек).
  void _openSearchSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 160),
            alignment: Alignment.bottomCenter,
            clipBehavior: Clip.none,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(_radius),
                border: Border.all(
                  color: _focus.hasFocus
                      ? p.accent.withValues(alpha: 0.45)
                      : p.border,
                ),
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
              clipBehavior: Clip.none,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _effectiveController,
                    focusNode: _focus,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    cursorColor: p.accent,
                    style: fontStyle(
                      settings.bodyFont,
                      size: 16,
                      color: p.text,
                    ),
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
                  const SizedBox(height: 13.3),
                  Row(
                    children: [
                      // ЛЕВАЯ ГРУППА: «Мышление», затем «Поиск» — обычный
                      // Row без скролла и обёрток: капсулы не обрезаются.
                      _reasoningCapsule(),
                      const SizedBox(width: 8),
                      _searchCapsule(p),
                      // Распорка: раздвигает группы по краям.
                      const Spacer(),
                      // ПРАВАЯ ГРУППА: Микрофон -> Скрепка
                      // -> Кнопка «Отправить» (медный кружок).
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 32,
                            height: 32,
                            child: _micButton(p),
                          ),
                          if (widget.config.supportsAttachments) ...[
                            const SizedBox(width: 2),
                            _attachButton(p),
                          ],
                          const SizedBox(width: 4),
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _sendButton(p),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _attachButton(Palette p) {
    return IconButton(
      tooltip: 'Прикрепить файл',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      visualDensity: VisualDensity.compact,
      iconSize: 26,
      icon: Icon(Icons.attach_file, size: 26, color: p.muted),
      onPressed: widget.streaming ? null : widget.onAttach,
    );
  }

  Widget _micButton(Palette p) {
    return IconButton(
      tooltip: 'Голосовой ввод',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      visualDensity: VisualDensity.compact,
      iconSize: 28,
      icon: Icon(Icons.mic, size: 28, color: p.muted),
      onPressed: widget.streaming ? null : widget.onToggleMic,
    );
  }

  Widget _sendButton(Palette p) {
    // Отправка недоступна, пока хоть одно вложение обрабатывается.
    final canSend = widget.onSend != null && !widget.attachmentsBusy;
    return IconButton.filled(
      tooltip: widget.streaming ? 'Остановить' : 'Отправить',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      onPressed: widget.streaming
          ? widget.onStop
          : (canSend ? widget.onSend : null),
      style: IconButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: p.accent.withValues(alpha: 0.35),
        shape: const CircleBorder(),
      ),
      icon: Icon(
        widget.streaming ? Icons.stop_rounded : Icons.rocket_launch_rounded,
        size: 26,
      ),
    );
  }

  Widget _reasoningCapsule() {
    final level = ReasoningMapper.fromId(settings.reasoningLevel);
    final label = level.label;
    final fill = _reasoningFills[level.index];
    final levelColor = _reasoningLevelColors[level.index];
    // Иконка уровня берётся из extension ReasoningLevelX (iconWidget):
    // у high — пользовательская SVG-иконка мозга, у остальных —
    // стандартные иконки Material с цветом уровня.
    final Widget leading = level.iconWidget;
    return Tooltip(
      message:
          'Уровень размышлений: $label (тап — сменить, удержание — подробно)',
      child: InkWell(
        borderRadius: BorderRadius.circular(_radius),
        onTap: widget.streaming ? null : _cycleLevel,
        onLongPress: widget.streaming ? null : _openReasoningSheet,
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

  Widget _searchCapsule(Palette p) {
    final mode = SearchModes.fromId(settings.searchMode);
    final available = mode != SearchMode.off;
    final on = available && _searchOn;
    final Color fill;
    final Color content;
    final Color borderColor;
    if (!available) {
      // Состояние 1: режим не выбран в настройках — серая неактивная капсула.
      fill = Colors.transparent;
      content = Colors.grey;
      borderColor = p.border;
    } else if (!on) {
      // Состояние 2: режим выбран, но поиск выключен в чате — серая/прозрачная.
      fill = Colors.transparent;
      content = p.muted;
      borderColor = p.border;
    } else {
      // Состояние 3: режим выбран и поиск включён в чате — синяя активная.
      fill = _searchFill;
      content = _searchTextOn;
      borderColor = _searchFill;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(_radius),
      onTap: widget.streaming ? null : _handleToggleSearch,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: 36,
        padding: const EdgeInsets.only(left: 12, right: 24),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(_radius),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/icons/search.svg',
              width: 20,
              height: 20,
              colorFilter: ColorFilter.mode(content, BlendMode.srcIn),
            ),
            const SizedBox(width: 6),
            Text(
              'Поиск',
              maxLines: 1,
              style: TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: content,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

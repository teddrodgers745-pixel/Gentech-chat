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

  /// Фоны и цвета иконок/текста капсулы для каждого из шести уровней
  /// ([ReasoningLevel]): off — серый, low — голубой, medium — зелёный,
  /// high — красно-жёлтый (огонь), xhigh — красный, max — фиолетовый.
  static const List<Color> _reasoningFills = <Color>[
    Color(0xFF3A3733), // off — серый
    Color(0xFF1A3A54), // low — голубой
    Color(0xFF1B4332), // medium — зелёный
    Color(0xFF5A2612), // high — красно-жёлтый (огонь)
    Color(0xFF5C1922), // xhigh — красный
    Color(0xFF3F1D6B), // max — фиолетовый
  ];

  static const List<Color> _reasoningLevelColors = <Color>[
    Color(0xFF9E9E9E), // off — серый
    Color(0xFF38BDF8), // low — голубой
    Color(0xFF4ADE80), // medium — зелёный
    Color(0xFFFFAB40), // high — красно-жёлтый (огонь)
    Color(0xFFFF5252), // xhigh — красный
    Color(0xFFC084FC), // max — фиолетовый
  ];

  static const Color _searchFill = Color(0xFF3B82F6);
  static const Color _searchTextOn = Color(0xFFF3F7FF);

  /// Локальный флаг поиска для текущего чата: при активном режиме поиска
  /// (например, native) включён по умолчанию, чтобы капсула сразу была синей.
  bool _searchOn = true;

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
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
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
                      // ПРАВАЯ ГРУППА: [Скрепка] -> [Микрофон] -> [Отправить]
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.config.supportsAttachments) ...[
                            _attachButton(p),
                            const SizedBox(width: 2),
                          ],
                          _micButton(p),
                          const SizedBox(width: 8),
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
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
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      visualDensity: VisualDensity.compact,
      iconSize: 24,
      icon: Icon(Icons.attach_file, size: 24, color: p.muted),
      onPressed: widget.streaming ? null : widget.onAttach,
    );
  }

  Widget _micButton(Palette p) {
    return IconButton(
      tooltip: 'Голосовой ввод',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      visualDensity: VisualDensity.compact,
      iconSize: 24,
      icon: Icon(Icons.mic, size: 24, color: p.muted),
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

  Widget _buildReasoningIcon(ReasoningLevel level, Color levelColor) {
    final raw = level.iconWidget;
    Widget icon;
    if (level == ReasoningLevel.high) {
      final baseChild = raw is Icon
          ? Icon(
              Icons.local_fire_department_rounded,
              size: 24,
              color: levelColor,
            )
          : SizedBox(
              width: 24,
              height: 24,
              child: FittedBox(fit: BoxFit.contain, child: raw),
            );
      icon = ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: <Color>[Color(0xFFFF3D00), Color(0xFFFFEA00)],
        ).createShader(bounds),
        blendMode: BlendMode.srcIn,
        child: baseChild,
      );
    } else if (raw is Icon) {
      icon = Icon(
        raw.icon ?? Icons.psychology_outlined,
        size: 24,
        color: levelColor,
      );
    } else {
      icon = ColorFiltered(
        colorFilter: ColorFilter.mode(levelColor, BlendMode.srcIn),
        child: SizedBox(
          width: 24,
          height: 24,
          child: FittedBox(fit: BoxFit.contain, child: raw),
        ),
      );
    }
    return SizedBox(
      width: 24,
      height: 24,
      child: Center(child: icon),
    );
  }

  Widget _reasoningCapsule() {
    final level = ReasoningMapper.fromId(settings.reasoningLevel);
    final label = level.label;
    final fill = _reasoningFills[level.index];
    final levelColor = _reasoningLevelColors[level.index];
    final Widget leading = _buildReasoningIcon(level, levelColor);
    return Tooltip(
      message:
          'Уровень размышлений: $label (тап — сменить, удержание — подробно)',
      child: InkWell(
        borderRadius: BorderRadius.circular(_radius),
        onTap: widget.streaming ? null : _cycleLevel,
        onLongPress: widget.streaming ? null : _openReasoningSheet,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          height: 36,
          constraints: const BoxConstraints(minWidth: 112),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(_radius),
            border: Border.all(color: levelColor.withValues(alpha: 0.35)),
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
    final configuredMode = SearchModes.fromId(settings.searchMode);
    final available = configuredMode != SearchMode.off;
    final on = available && _searchOn;
    final Color fill;
    final Color content;
    final Color borderColor;
    if (!available) {
      // Состояние 1: SearchMode.off — серая неактивная капсула.
      fill = const Color(0xFF3A3733).withValues(alpha: 0.25);
      content = Colors.grey;
      borderColor = p.border;
    } else if (configuredMode == SearchMode.native || on) {
      // Состояние 2: режим native либо поиск включён в чате — синяя активная.
      fill = _searchFill;
      content = _searchTextOn;
      borderColor = _searchFill;
    } else {
      // Состояние 3: режим настроен, но временно отключён для чата.
      fill = _searchFill.withValues(alpha: 0.14);
      content = _searchFill;
      borderColor = _searchFill.withValues(alpha: 0.45);
    }
    return InkWell(
      borderRadius: BorderRadius.circular(_radius),
      onTap: widget.streaming ? null : _handleToggleSearch,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
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

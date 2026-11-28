// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_state.dart';
import '../../core/generation/active_model_controller.dart';
import '../../core/generation/model_type_override_store.dart' show ModelTypes;
import '../../core/generation/user_param_override_store.dart';
import 'widgets/manual_params_sheet.dart';
import '../../core/models/active_model_capabilities.dart';
import '../../core/models/param_spec.dart';
import '../../models/attachment_draft.dart';
import '../../models/model_config.dart';
import '../../theme.dart';
import '../../widgets/attachment_strip.dart';
import '../../widgets/inputs/live_voice_input.dart';
import '../../widgets/inputs/text_chat_input.dart';
import 'modes/image_gen_mode.dart';

/// Адаптивная панель ввода чата. Мгновенно перестраивается при смене
/// пресета или модели:
///  - Live -> панель голосового режима;
///  - Video / Image -> композитор промпта с интерактивными чипсами
///    пропорций, длительности и разрешения из каталога активной модели;
///  - Text (и любые остальные по умолчанию) -> полный [TextChatInput]
///    с капсулами «Мышление», «Поиск», скрепкой, микрофоном и отправкой.
/// Поле ввода никогда не исчезает: у каждой рабочей модели есть панель.
///
/// G2-media-references: в медиа-композере скрепка референсов и полоса
/// миниатюр показываются ТОЛЬКО когда каталог активной модели сообщил
/// maxReferenceImages > 0 (ActiveModelCapabilities.supportsReferenceImages).
class AdaptiveChatInputBar extends StatefulWidget {
  final ModelConfig config;
  final ActiveModelCapabilities capabilities;
  final TextEditingController? controller;

  /// Эффективный тип модели ('text', 'image', 'video').
  final String modelType;
  final bool streaming;
  final bool attachmentsBusy;
  final int reasoningLevel;

  final ValueChanged<String>? onAspectRatioChanged;
  final ValueChanged<int>? onDurationChanged;
  final ValueChanged<String>? onResolutionChanged;
  final ValueChanged<String>? onQualityChanged;
  final VoidCallback? onCycleReasoning;
  final VoidCallback? onToggleSearch;
  final VoidCallback? onToggleMic;
  final VoidCallback? onAttach;
  final VoidCallback? onSend;
  final VoidCallback? onStop;
  final VoidCallback? onStartLive;

  /// G2-media-references: референсные изображения медиа-модели
  /// (image/video) — черновики вложений для полосы миниатюр в
  /// медиа-композере. Пустой список — полоса скрыта.
  final List<AttachmentDraft> mediaAttachments;

  /// Удаление референса по индексу; null — удаление недоступно.
  final ValueChanged<int>? onRemoveMediaAttachment;

  const AdaptiveChatInputBar({
    super.key,
    required this.config,
    this.capabilities = ActiveModelCapabilities.empty,
    this.controller,
    this.modelType = '',
    this.streaming = false,
    this.attachmentsBusy = false,
    this.reasoningLevel = 0,
    this.onAspectRatioChanged,
    this.onDurationChanged,
    this.onResolutionChanged,
    this.onQualityChanged,
    this.onCycleReasoning,
    this.onToggleSearch,
    this.onToggleMic,
    this.onAttach,
    this.onSend,
    this.onStop,
    this.onStartLive,
    this.mediaAttachments = const <AttachmentDraft>[],
    this.onRemoveMediaAttachment,
  });

  @override
  State<AdaptiveChatInputBar> createState() => _AdaptiveChatInputBarState();
}

class _AdaptiveChatInputBarState extends State<AdaptiveChatInputBar> {
  TextEditingController? _internalController;
  final FocusNode _focus = FocusNode();

  String _selectedRatio = '1:1';
  int? _selectedDuration;
  String? _selectedResolution;
  String? _selectedQuality;

  /// Локальная копия сохранённого override параметров: чипсы обновляются
  /// сразу после сохранения, не дожидаясь пересборки контроллера модели.
  ModelParameters? _override;

  TextEditingController get _effectiveController =>
      widget.controller ?? (_internalController ??= TextEditingController());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
    // `key` содержит normalizedId + тип, поэтому initState срабатывает
    // при смене модели/типа — форсируем сброс на дефолты новой модели.
    _syncDefaultParams(forceReset: true);
  }

  @override
  void didUpdateWidget(covariant AdaptiveChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final modelChanged = oldWidget.capabilities.normalizedId !=
        widget.capabilities.normalizedId;
    if (modelChanged) _override = null;
    if (modelChanged ||
        oldWidget.capabilities.params != widget.capabilities.params ||
        oldWidget.modelType != widget.modelType ||
        oldWidget.config != widget.config) {
      _syncDefaultParams(forceReset: modelChanged);
    }
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  List<String> _availableAspectRatios() {
    final ov = _override?.aspectRatios;
    if (ov != null && ov.isNotEmpty) return ov;
    final fromCaps =
        widget.capabilities.params?.aspectRatios ?? const <String>[];
    if (fromCaps.isNotEmpty) return fromCaps;
    final cfg = widget.config;
    if (cfg is ImageGenModelConfig && cfg.availableAspectRatios.isNotEmpty) {
      return cfg.availableAspectRatios;
    }
    if (_isVideoMode) {
      return const <String>['16:9', '9:16', '1:1'];
    }
    return <String>[for (final r in ImageGenMode.aspectRatios) r.id];
  }

  /// Длительности для чипсов панели: только значения, перечисленные
  /// каталогом (`duration.values`), либо заданные пользователем.
  /// Диапазон min..max значениями не считается: у Seedance в каталоге
  /// Polza есть лишь границы 4..15 и default 15, поэтому выдуманных
  /// чипсов (5 с, 8 с и т.п.) быть не должно — дефолт берётся из каталога
  /// через [ActiveModelController].
  List<int> _availableDurations() {
    final ov = _override?.durations;
    if (ov != null && !ov.isEmpty) return _durationList(ov);
    final d = widget.capabilities.params?.durations;
    if (d == null || d.isEmpty) return const <int>[];
    final disc = d.discrete;
    if (disc == null || disc.isEmpty) return const <int>[];
    return List<int>.of(disc);
  }

  /// Длительности из диапазона/списка: дискретный список либо шаг 5 с
  /// внутри min..max (не более 10 вариантов), иначе [5, 10].
  static List<int> _durationList(DurationRange d) {
    final disc = d.discrete;
    if (disc != null && disc.isNotEmpty) return List<int>.of(disc);
    final min = d.min;
    final max = d.max;
    if (min != null && max != null && max >= min) {
      final list = <int>[];
      for (int v = min; v <= max && list.length < 10; v += 5) {
        list.add(v);
      }
      if (list.isNotEmpty) return list;
    }
    final only = min ?? max;
    if (only != null) return <int>[only];
    return const <int>[5, 10];
  }

  List<String> _availableResolutions() {
    final ov = _override?.resolutions;
    if (ov != null && ov.isNotEmpty) return ov;
    return widget.capabilities.params?.resolutions ?? const <String>[];
  }

  /// Качества генерации модели ('standard', 'hd' ...); пустой список —
  /// чипсы качества не показываются. Override пользователя приоритетен.
  List<String> _availableQualities() {
    final ov = _override?.qualities;
    if (ov != null && ov.isNotEmpty) return ov;
    return widget.capabilities.params?.qualities ?? const <String>[];
  }

  /// [forceReset] — жёсткий сброс на дефолты новой модели (при смене
  /// модели): все выбранные значения (ratio, duration, resolution,
  /// quality) заменяются на первый элемент каталога/дефолт контроллера.
  /// Без флага — только «подтягиваем» невалидные значения.
  void _syncDefaultParams({bool forceReset = false}) {
    final ratios = _availableAspectRatios();
    if (forceReset) {
      _selectedRatio = '';
    }
    if (ratios.isNotEmpty && !ratios.contains(_selectedRatio)) {
      _selectedRatio = ratios.first;
    }

    final durations = _availableDurations();
    if (forceReset) {
      _selectedDuration = null;
    }
    if (durations.isNotEmpty) {
      if (_selectedDuration == null ||
          !durations.contains(_selectedDuration)) {
        _selectedDuration = durations.first;
      }
    } else {
      // Каталог не перечислил значения (только диапазон min..max):
      // сохраняем дефолт из каталога (например, 15 с у Seedance),
      // а не стираем выбор и не подставляем первый элемент списка.
      _selectedDuration = ActiveModelController.selectedDuration;
    }

    if (forceReset) {
      _selectedResolution = null;
      _selectedQuality = null;
    }
    final resolutions = _availableResolutions();
    if (resolutions.isNotEmpty) {
      if (_selectedResolution == null ||
          !resolutions.contains(_selectedResolution)) {
        _selectedResolution = resolutions.first;
      }
    } else {
      _selectedResolution = null;
    }
    final qualities = _availableQualities();
    if (qualities.isNotEmpty) {
      if (_selectedQuality == null || !qualities.contains(_selectedQuality)) {
        _selectedQuality = qualities.first;
      }
    } else {
      _selectedQuality = null;
    }

    ActiveModelController.updateSelectedMediaParams(
      aspectRatio: _selectedRatio,
      duration: _selectedDuration,
      resolution: _selectedResolution,
      quality: _selectedQuality,
      clearNulls: true,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_selectedRatio.isNotEmpty) {
        widget.onAspectRatioChanged?.call(_selectedRatio);
      }
      if (_selectedDuration != null) {
        widget.onDurationChanged?.call(_selectedDuration!);
      }
      if (_selectedResolution != null) {
        widget.onResolutionChanged?.call(_selectedResolution!);
      }
      if (_selectedQuality != null) {
        widget.onQualityChanged?.call(_selectedQuality!);
      }
    });
  }

  bool get _isLiveMode =>
      widget.config is LiveVoiceModelConfig ||
      widget.capabilities.kind == ActiveModelKind.live;

  bool get _isVideoMode =>
      widget.modelType == ModelTypes.video ||
      widget.capabilities.kind == ActiveModelKind.video;

  bool get _isImageMode =>
      !_isVideoMode &&
      (widget.modelType == ModelTypes.image ||
          widget.capabilities.kind == ActiveModelKind.image ||
          widget.config is ImageGenModelConfig);

  /// G2-media-references: поддержка референсов — ТОЛЬКО по каталогу
  /// (maxReferenceImages > 0). Никаких захардкоженных списков моделей:
  /// что дал каталог — то и показываем.
  bool get _supportsReferences =>
      widget.capabilities.supportsReferenceImages;

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _internalController?.dispose();
    super.dispose();
  }

  /// Ручной ввод параметров (когда модель неизвестна каталогу): открывает
  /// шторку ManualParamsSheet с полями пропорций/длительностей и секцией
  /// MEDIA (чипсы разрешений/качества из caps). Результат сохраняется
  /// как override пользователя (UserParamOverrideStore).
  Future<void> _openManualParamsDialog() async {
    final normId = widget.capabilities.normalizedId;
    if (normId.isEmpty) return;
    final res = await showManualParamsSheet(
      context,
      initial: _override,
      allowedResolutions: _availableResolutions(),
      allowedQualities: _availableQualities(),
    );
    if (res == null || !res.hasAny) return;
    if (_isVideoMode) {
      res.type = 'video';
    } else if (_isImageMode) {
      res.type = 'image';
    }
    await userParamOverrideStore.save(normId, res);
    if (!mounted) return;
    setState(() {
      _override = res;
      if (res.aspectRatios.isNotEmpty) {
        _selectedRatio = res.aspectRatios.first;
        widget.onAspectRatioChanged?.call(_selectedRatio);
      }
      final durs = _availableDurations();
      if (durs.isNotEmpty) {
        _selectedDuration = durs.first;
        widget.onDurationChanged?.call(_selectedDuration!);
      }
      final resList = _availableResolutions();
      if (resList.isNotEmpty) {
        _selectedResolution = resList.first;
        widget.onResolutionChanged?.call(_selectedResolution!);
      }
      final qList = _availableQualities();
      if (qList.isNotEmpty) {
        _selectedQuality = qList.first;
        widget.onQualityChanged?.call(_selectedQuality!);
      }
      ActiveModelController.updateSelectedMediaParams(
        aspectRatio: _selectedRatio,
        duration: _selectedDuration,
        resolution: _selectedResolution,
        quality: _selectedQuality,
        clearNulls: true,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLiveMode) {
      return LiveVoiceInput(onStartLive: widget.onStartLive);
    }
    if (_isVideoMode || _isImageMode) {
      return _buildMediaComposer(context, isVideo: _isVideoMode);
    }
    final textConfig = widget.config is TextModelConfig
        ? widget.config as TextModelConfig
        : const TextModelConfig(
            supportsAttachments: true,
            supportsWebSearch: true,
          );
    return TextChatInput(
      config: textConfig,
      capabilities: widget.capabilities,
      controller: _effectiveController,
      streaming: widget.streaming,
      reasoningLevel: widget.reasoningLevel,
      attachmentsBusy: widget.attachmentsBusy,
      onCycleReasoning: widget.onCycleReasoning,
      onToggleSearch: widget.onToggleSearch,
      onToggleMic: widget.onToggleMic,
      onAttach: widget.onAttach,
      onSend: widget.onSend,
      onStop: widget.onStop,
    );
  }

  /// Композитор медиа-генерации (изображение/видео): чипсы параметров
  /// из каталога модели, скрепка референсов (только по каталогу),
  /// полоса миниатюр референсов, поле промпта, голосовой ввод и отправка.
  Widget _buildMediaComposer(BuildContext context, {required bool isVideo}) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final ratios = _availableAspectRatios();
        final durations = isVideo ? _availableDurations() : const <int>[];
        final resolutions = _availableResolutions();
        final qualities = _availableQualities();
        final hasSpec =
            _override != null || widget.capabilities.params != null;

        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.bottomCenter,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(24),
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
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: p.accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isVideo
                                  ? Icons.videocam_rounded
                                  : Icons.image_rounded,
                              size: 15,
                              color: p.accent,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              isVideo ? 'Видео' : 'Изображение',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: p.accent,
                              ),
                            ),
                          ],
                        ),
                      ),
                      for (final ratio in ratios)
                        _paramChip(
                          p: p,
                          icon: Icons.crop_rounded,
                          label: ratio,
                          selected: _selectedRatio == ratio,
                          onTap: widget.streaming
                              ? null
                              : () {
                                  HapticFeedback.selectionClick();
                                  setState(() => _selectedRatio = ratio);
                                  ActiveModelController
                                      .updateSelectedMediaParams(
                                    aspectRatio: ratio,
                                  );
                                  widget.onAspectRatioChanged?.call(ratio);
                                },
                        ),
                      if (isVideo && durations.isNotEmpty)
                        for (final sec in durations)
                          _paramChip(
                            p: p,
                            icon: Icons.timer_outlined,
                            label: '${sec}с',
                            selected: _selectedDuration == sec,
                            onTap: widget.streaming
                                ? null
                                : () {
                                    HapticFeedback.selectionClick();
                                    setState(() => _selectedDuration = sec);
                                    ActiveModelController
                                        .updateSelectedMediaParams(
                                      duration: sec,
                                    );
                                    widget.onDurationChanged?.call(sec);
                                  },
                          ),
                      if (resolutions.isNotEmpty)
                        for (final res in resolutions)
                          _paramChip(
                            p: p,
                            icon: Icons.high_quality_outlined,
                            label: res,
                            selected: _selectedResolution == res,
                            onTap: widget.streaming
                                ? null
                                : () {
                                    HapticFeedback.selectionClick();
                                    setState(() => _selectedResolution = res);
                                    ActiveModelController
                                        .updateSelectedMediaParams(
                                      resolution: res,
                                    );
                                    widget.onResolutionChanged?.call(res);
                                  },
                          ),
                      if (qualities.isNotEmpty)
                        for (final q in qualities)
                          _paramChip(
                            p: p,
                            icon: Icons.auto_awesome_outlined,
                            label: q,
                            selected: _selectedQuality == q,
                            onTap: widget.streaming
                                ? null
                                : () {
                                    HapticFeedback.selectionClick();
                                    setState(() => _selectedQuality = q);
                                    ActiveModelController
                                        .updateSelectedMediaParams(
                                      quality: q,
                                    );
                                    widget.onQualityChanged?.call(q);
                                  },
                          ),
                      if (!hasSpec)
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          avatar: Icon(
                            Icons.tune_rounded,
                            size: 15,
                            color: p.accent,
                          ),
                          label: Text(
                            'Указать параметры вручную',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: p.accent,
                            ),
                          ),
                          backgroundColor: p.accent.withValues(alpha: 0.10),
                          side: BorderSide(
                            color: p.accent.withValues(alpha: 0.35),
                          ),
                          onPressed: _openManualParamsDialog,
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // G2-media-references: полоса миниатюр референсов со
                  // счётчиком «N / max» над полем ввода — только когда
                  // каталог модели разрешил референсы и они есть.
                  if (_supportsReferences &&
                      widget.mediaAttachments.isNotEmpty)
                    _referenceStrip(p),
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
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      hintText: isVideo
                          ? 'Опишите видео для генерации…'
                          : 'Опишите изображение для генерации…',
                      hintStyle: TextStyle(color: p.muted),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding:
                          const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    ),
                    minLines: 1,
                    maxLines: 5,
                  ),
                  Row(
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: widget.streaming
                            ? null
                            : _openManualParamsDialog,
                        icon: Icon(
                          Icons.tune_rounded,
                          size: 16,
                          color: p.muted,
                        ),
                        label: Text(
                          'Параметры',
                          style: TextStyle(fontSize: 12.5, color: p.muted),
                        ),
                      ),
                      const Spacer(),
                      // G2-media-references: скрепка референсов в
                      // медиа-режиме — строго по каталогу модели.
                      if (_supportsReferences) ...[
                        IconButton(
                          key: const ValueKey('g2_media_attach'),
                          tooltip: 'Прикрепить референс',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 34,
                            minHeight: 34,
                          ),
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          visualDensity: VisualDensity.compact,
                          iconSize: 24,
                          icon: Icon(
                            Icons.attach_file,
                            size: 24,
                            color: p.muted,
                          ),
                          onPressed: widget.streaming
                              ? null
                              : widget.onAttach,
                        ),
                        const SizedBox(width: 4),
                      ],
                      IconButton(
                        tooltip: 'Голосовой ввод',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        visualDensity: VisualDensity.compact,
                        iconSize: 24,
                        icon: Icon(Icons.mic, size: 24, color: p.muted),
                        onPressed:
                            widget.streaming ? null : widget.onToggleMic,
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: widget.streaming
                            ? 'Остановить'
                            : (isVideo
                                ? 'Создать видео'
                                : 'Создать изображение'),
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        onPressed: widget.streaming
                            ? widget.onStop
                            : (!widget.attachmentsBusy
                                ? () {
                                    ActiveModelController
                                        .updateSelectedMediaParams(
                                      aspectRatio: _selectedRatio,
                                      duration: _selectedDuration,
                                      resolution: _selectedResolution,
                                      quality: _selectedQuality,
                                    );
                                    widget.onSend?.call();
                                  }
                                : null),
                        style: IconButton.styleFrom(
                          backgroundColor: p.accent,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                              p.accent.withValues(alpha: 0.35),
                          shape: const CircleBorder(),
                        ),
                        icon: Icon(
                          widget.streaming
                              ? Icons.stop_rounded
                              : Icons.auto_awesome_rounded,
                          size: 24,
                        ),
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

  /// Полоса миниатюр референсов со счётчиком лимита «N / max».
  /// Удаление каждого вложения — кнопкой в углу миниатюры
  /// (делегирует в [AdaptiveChatInputBar.onRemoveMediaAttachment]).
  Widget _referenceStrip(Palette p) {
    final refs = widget.mediaAttachments;
    final max = widget.capabilities.maxReferenceImages ?? 0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: AttachmentStrip(
            attachments: refs,
            onRemove: (i) => widget.onRemoveMediaAttachment?.call(i),
          ),
        ),
        const SizedBox(width: 4),
        if (max > 0)
          Text(
            '${refs.length} / $max',
            key: const ValueKey('g2_ref_counter'),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: p.muted,
            ),
          ),
      ],
    );
  }

  Widget _paramChip({
    required Palette p,
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    final bg = selected
        ? p.accent.withValues(alpha: 0.18)
        : p.bg.withValues(alpha: 0.55);
    final fg = selected ? p.accent : p.text;
    final border = selected ? p.accent : p.border;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

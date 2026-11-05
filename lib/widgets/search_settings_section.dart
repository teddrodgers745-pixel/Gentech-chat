// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/search/search_strategy.dart';
import '../core/storage.dart';
import '../services/search_probe.dart';
import '../theme.dart';
import '../ui/screens/tools_screen.dart';

/// Секция «ПОИСК» на экране настроек: выпадающий список режима поиска
/// (Выключен / Нативный / Провайдер / Инструмент) и динамическая область
/// под списком (SearchModeDetailView):
///  - off — ничего не показывается;
///  - native — пояснение «настройки не требуются»;
///  - modelAsTool — кнопка «⚙️ Настроить инструмент поиска»
///    (переход на экран инструментов) плюс выбор модели-инструмента;
///  - provider — auto-ping: при выборе режима автоматически выполняется
///    лёгкий probe-запрос (tools: [{'type': 'web_search'}]); ответ 200 —
///    зелёный баннер с иконкой обновления, ответ 400 — красный баннер
///    с кнопкой «Повторить».
/// Все значения сохраняются в SharedPreferences через [AppSettings].
class SearchSettingsSection extends StatefulWidget {
  const SearchSettingsSection({super.key});

  @override
  State<SearchSettingsSection> createState() =>
      _SearchSettingsSectionState();
}

/// Состояние авто-проверки поддержки веб-поиска (режим «Провайдер»).
enum _ProbeState { idle, checking, supported, unsupported, error }

class _SearchSettingsSectionState extends State<SearchSettingsSection> {
  static const Color _green = Color(0xFF2E7D32);
  static const Color _red = Color(0xFFB3261E);

  late final TextEditingController _apiKey;
  late final TextEditingController _toolModel;
  Timer? _debounce;
  bool _showKey = false;

  /// Состояние авто-проверки поддержки веб-поиска.
  _ProbeState _probeState = _ProbeState.idle;

  /// Текст проблемы последней проверки (нет подключения, сбой сети);
  /// null — проблемы нет.
  String? _probeError;

  /// Идентификаторы моделей из инструментов типа «модель»
  /// (Tool.typeModel) — кандидаты для роли модели-инструмента.
  List<String> _toolModels = const <String>[];

  /// Режимы выпадающего списка: ровно четыре варианта из задания.
  static const List<SearchMode> _modes = <SearchMode>[
    SearchMode.off,
    SearchMode.native,
    SearchMode.provider,
    SearchMode.modelAsTool,
  ];

  @override
  void initState() {
    super.initState();
    _apiKey = TextEditingController(text: settings.customSearchApiKey);
    _toolModel = TextEditingController(text: settings.searchToolModel);
    _loadToolModels();
    // Auto-ping: режим «Провайдер» уже выбран при открытии настроек —
    // проверка поддержки запускается автоматически.
    if (SearchModes.fromId(settings.searchMode) == SearchMode.provider) {
      unawaited(_runProbe());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _apiKey.dispose();
    _toolModel.dispose();
    super.dispose();
  }

  Future<void> _loadToolModels() async {
    try {
      final tools = await storage.getTools();
      final ids = <String>{
        for (final t in tools)
          if (t.isModel && t.modelId.trim().isNotEmpty) t.modelId.trim(),
      };
      final list = ids.toList()..sort();
      if (!mounted) return;
      setState(() => _toolModels = list);
    } catch (_) {
      // Хранилище недоступно — остаётся ручной ввод модели.
    }
  }

  /// Сохранение текстовых полей с задержкой, чтобы не писать
  /// в хранилище на каждом нажатии клавиши.
  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      settings.setCustomSearchApiKey(_apiKey.text);
      settings.setSearchToolModel(_toolModel.text);
    });
  }

  /// Подписи вариантов выпадающего списка.
  static String _modeLabel(SearchMode mode) => switch (mode) {
        SearchMode.off => 'Выключен',
        SearchMode.native => 'Нативный',
        SearchMode.provider => 'Провайдер',
        SearchMode.modelAsTool => 'Инструмент',
        SearchMode.customApi => 'Свой API',
      };

  /// Auto-ping: лёгкая проверка поддержки серверного веб-поиска
  /// (POST /chat/completions с tools: [{'type': 'web_search'}]).
  /// 200 -> «Провайдер поддерживает веб-поиск», 400 -> «не поддерживает».
  /// Итог сохраняется в настройках — от него зависит добавление
  /// инструмента web_search в реальные запросы чата.
  Future<void> _runProbe() async {
    if (_probeState == _ProbeState.checking) return;
    final cfg = effectiveConfig();
    if (cfg.baseUrl.trim().isEmpty ||
        cfg.model.trim().isEmpty ||
        cfg.apiKey.trim().isEmpty) {
      if (!mounted) return;
      setState(() {
        _probeState = _ProbeState.error;
        _probeError =
            'Для проверки задайте Base URL, API-ключ и модель в настройках.';
      });
      return;
    }
    setState(() {
      _probeState = _ProbeState.checking;
      _probeError = null;
    });
    final res = await probeWebSearchSupport(
      baseUrl: cfg.baseUrl,
      apiKey: cfg.apiKey,
      model: cfg.model,
    );
    if (!mounted) return;
    setState(() {
      switch (res) {
        case WebSearchProbeResult.supported:
          _probeState = _ProbeState.supported;
          settings.setWebSearchSupported(true);
          settings.setProviderSearchSupported(true);
        case WebSearchProbeResult.unsupported:
          _probeState = _ProbeState.unsupported;
          settings.setWebSearchSupported(false);
          settings.setProviderSearchSupported(false);
        case WebSearchProbeResult.error:
          _probeState = _ProbeState.error;
          _probeError =
              'Проверка не удалась: проверьте сеть и повторите.';
      }
    });
  }

  /// Смена режима в выпадающем списке; при выборе «Провайдер»
  /// автоматически запускается проверка поддержки (auto-ping).
  void _onModeChanged(SearchMode? mode) {
    if (mode == null) return;
    settings.setSearchMode(mode.id);
    if (mode == SearchMode.provider) {
      unawaited(_runProbe());
    } else {
      setState(() {
        _probeState = _ProbeState.idle;
        _probeError = null;
      });
    }
  }

  /// Динамическая область под выпадающим списком (SearchModeDetailView).
  Widget _detailView(Palette p, SearchMode mode) {
    switch (mode) {
      case SearchMode.off:
        return const SizedBox.shrink();
      case SearchMode.native:
        return Text(
          'Поиск выполняется самой моделью. Настройки не требуются.',
          style: TextStyle(color: p.muted, fontSize: 13, height: 1.35),
        );
      case SearchMode.provider:
        return _providerDetail(p);
      case SearchMode.modelAsTool:
        return _toolDetail(p);
      case SearchMode.customApi:
        return _customApiDetail(p);
    }
  }

  /// Режим «Провайдер»: auto-ping и баннеры результата.
  Widget _providerDetail(Palette p) {
    switch (_probeState) {
      case _ProbeState.checking:
        return Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Проверка поддержки...',
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
            ),
          ],
        );
      case _ProbeState.supported:
        return _banner(
          border: _green,
          bg: _green.withValues(alpha: 0.12),
          content: Row(
            children: [
              Expanded(
                child: Text(
                  '🟢 Провайдер поддерживает веб-поиск',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _green,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Проверить снова',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
                icon: Icon(Icons.refresh_rounded, size: 18, color: p.accent),
                onPressed: _runProbe,
              ),
            ],
          ),
        );
      case _ProbeState.unsupported:
        return _banner(
          border: _red,
          bg: _red.withValues(alpha: 0.10),
          content: Row(
            children: [
              Expanded(
                child: Text(
                  '🔴 Текущая модель не поддерживает поиск',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _red,
                  ),
                ),
              ),
              TextButton(
                onPressed: _runProbe,
                style: TextButton.styleFrom(
                  foregroundColor: _red,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('Повторить'),
              ),
            ],
          ),
        );
      case _ProbeState.error:
        return _banner(
          border: p.border,
          bg: p.card,
          content: Row(
            children: [
              Expanded(
                child: Text(
                  _probeError ?? 'Проверка не удалась.',
                  style: TextStyle(color: p.muted, fontSize: 12.5, height: 1.35),
                ),
              ),
              TextButton(
                onPressed: _runProbe,
                style: TextButton.styleFrom(
                  foregroundColor: p.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('Повторить'),
              ),
            ],
          ),
        );
      case _ProbeState.idle:
        return const SizedBox.shrink();
    }
  }

  /// Баннер результата проверки в тёплой гамме темы.
  Widget _banner({
    required Color border,
    required Color bg,
    required Widget content,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border.withValues(alpha: 0.6)),
      ),
      child: content,
    );
  }

  /// Режим «Инструмент»: выбор модели-инструмента и переход к настройке
  /// инструментов.
  Widget _toolDetail(Palette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _toolModel,
          autocorrect: false,
          cursorColor: p.accent,
          onChanged: (_) => _scheduleSave(),
          decoration: const InputDecoration(
            labelText: 'Модель-инструмент',
            hintText: 'Идентификатор модели для поиска',
          ),
        ),
        if (_toolModels.isNotEmpty) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey<String>(
              'search_tool_dd_${_toolModel.text.trim()}',
            ),
            initialValue: _toolModels.contains(_toolModel.text.trim())
                ? _toolModel.text.trim()
                : null,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Выбрать из моделей-инструментов',
            ),
            items: [
              for (final m in _toolModels)
                DropdownMenuItem<String>(
                  value: m,
                  child: Text(
                    m,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              if (v == null) return;
              _toolModel.text = v;
              _toolModel.selection =
                  TextSelection.collapsed(offset: v.length);
              settings.setSearchToolModel(v);
              setState(() {});
            },
          ),
        ],
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ToolsScreen()),
          ),
          child: const Text('⚙️ Настроить инструмент поиска'),
        ),
      ],
    );
  }

  /// Режим «Свой API»: ключ пользовательского поискового API
  /// (прежняя работающая функциональность сохранена).
  Widget _customApiDetail(Palette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _apiKey,
          obscureText: !_showKey,
          autocorrect: false,
          enableSuggestions: false,
          cursorColor: p.accent,
          onChanged: (_) => _scheduleSave(),
          decoration: InputDecoration(
            labelText: 'Ключ поискового API',
            hintText: 'Ключ вашего поискового сервиса',
            suffixIcon: IconButton(
              tooltip: _showKey ? 'Скрыть ключ' : 'Показать ключ',
              icon: Icon(
                _showKey ? Icons.visibility_off : Icons.visibility,
              ),
              onPressed: () => setState(() => _showKey = !_showKey),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final mode = SearchModes.fromId(settings.searchMode);
        final dropdownValue =
            _modes.any((m) => m.id == mode.id) ? mode : SearchMode.off;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ПОИСК',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: p.accent,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Как модель получает свежие данные из интернета',
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<SearchMode>(
              initialValue: dropdownValue,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Режим поиска'),
              items: <DropdownMenuItem<SearchMode>>[
                for (final m in _modes)
                  DropdownMenuItem<SearchMode>(
                    value: m,
                    child: Text(_modeLabel(m)),
                  ),
              ],
              onChanged: _onModeChanged,
            ),
            const SizedBox(height: 12),
            _detailView(p, mode),
          ],
        );
      },
    );
  }
}

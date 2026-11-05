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
/// (Выключен / Нативный / Провайдер / Инструмент), проверка поддержки
/// серверного веб-поиска провайдера лёгким probe-запросом (режим
/// «Провайдер») и переход к настройке инструментов (режим «Инструмент»).
/// Все значения сохраняются в SharedPreferences через [AppSettings].
class SearchSettingsSection extends StatefulWidget {
  const SearchSettingsSection({super.key});

  @override
  State<SearchSettingsSection> createState() => _SearchSettingsSectionState();
}

class _SearchSettingsSectionState extends State<SearchSettingsSection> {
  late final TextEditingController _apiKey;
  late final TextEditingController _toolModel;
  Timer? _debounce;
  bool _showKey = false;

  /// Идёт ли probe-проверка поддержки веб-поиска прямо сейчас.
  bool _checking = false;

  /// Текст ошибки последней проверки (сеть/таймаут); null — ошибки нет.
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

  /// Подписи вариантов выпадающего списка (по заданию).
  static String _modeLabel(SearchMode mode) => switch (mode) {
        SearchMode.off => 'Выключен',
        SearchMode.native => 'Нативный',
        SearchMode.provider => 'Провайдер',
        SearchMode.modelAsTool => 'Инструмент',
        SearchMode.customApi => 'Свой API',
      };

  static String _hintFor(SearchMode mode) => switch (mode) {
        SearchMode.off =>
          'Поиск выключен: модель отвечает только из своих знаний.',
        SearchMode.native =>
          'Встроенный поиск самой модели, без дополнительных настроек.',
        SearchMode.provider =>
          'Серверный поиск, который предоставляет подключённый провайдер.',
        SearchMode.modelAsTool =>
          'Поиск выполняет отдельная модель, подключённая как инструмент.',
        SearchMode.customApi =>
          'Запросы уходят в ваш собственный поисковый API с этим ключом.',
      };

  /// Проверка поддержки серверного веб-поиска: лёгкий запрос
  /// (model, messages: ping, max_tokens: 1, tools: web_search).
  /// 200 -> web_search_supported = true («Поддерживается»),
  /// 400 -> false («Не поддерживается»).
  Future<void> _runProbe() async {
    if (_checking) return;
    final cfg = effectiveConfig();
    if (cfg.baseUrl.trim().isEmpty ||
        cfg.model.trim().isEmpty ||
        cfg.apiKey.trim().isEmpty) {
      setState(() {
        _probeError =
            'Для проверки задайте Base URL, API-ключ и модель в настройках.';
      });
      return;
    }
    setState(() {
      _checking = true;
      _probeError = null;
    });
    final res = await probeWebSearchSupport(
      baseUrl: cfg.baseUrl,
      apiKey: cfg.apiKey,
      model: cfg.model,
    );
    if (!mounted) return;
    setState(() {
      _checking = false;
      switch (res) {
        case WebSearchProbeResult.supported:
          settings.setWebSearchSupported(true);
        case WebSearchProbeResult.unsupported:
          settings.setWebSearchSupported(false);
        case WebSearchProbeResult.error:
          _probeError =
              'Не удалось выполнить проверку: проверьте сеть и повторите.';
      }
    });
  }

  /// Смена режима в выпадающем списке; при выборе «Провайдер»
  /// сразу запускается проверка поддержки веб-поиска.
  void _onModeChanged(SearchMode? mode) {
    if (mode == null) return;
    settings.setSearchMode(mode.id);
    if (mode == SearchMode.provider) _runProbe();
  }

  /// Строка статуса проверки поддержки (режим «Провайдер»).
  Widget _probeRow(Palette p) {
    final Widget status;
    if (_checking) {
      status = Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Проверяем поддержку веб-поиска…',
              style: TextStyle(color: p.muted, fontSize: 12.5),
            ),
          ),
        ],
      );
    } else if (_probeError != null) {
      status = Text(
        _probeError!,
        style: TextStyle(color: p.muted, fontSize: 12.5, height: 1.35),
      );
    } else {
      status = Row(
        children: [
          Icon(
            settings.webSearchSupported
                ? Icons.check_circle_rounded
                : Icons.cancel_outlined,
            size: 16,
            color: settings.webSearchSupported ? p.accent : p.muted,
          ),
          const SizedBox(width: 6),
          Text(
            settings.webSearchSupported
                ? 'Поддерживается'
                : 'Не поддерживается',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: settings.webSearchSupported ? p.accent : p.muted,
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: status),
        const SizedBox(width: 8),
        TextButton(
          onPressed: _checking ? null : _runProbe,
          style: TextButton.styleFrom(
            foregroundColor: p.accent,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(fontSize: 12.5),
          ),
          child: Text(_probeError == null ? 'Проверить снова' : 'Проверить'),
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
            const SizedBox(height: 8),
            Text(
              _hintFor(mode),
              style: TextStyle(color: p.muted, fontSize: 12.5, height: 1.35),
            ),
            if (mode == SearchMode.provider) ...[
              const SizedBox(height: 12),
              _probeRow(p),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ToolsScreen()),
                ),
                icon: const Icon(Icons.build_outlined, size: 18),
                label: const Text('Настроить'),
              ),
            ],
            if (mode == SearchMode.customApi) ...[
              const SizedBox(height: 12),
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
            if (mode == SearchMode.modelAsTool) ...[
              const SizedBox(height: 12),
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
                    _toolModel.selection = TextSelection.collapsed(
                      offset: v.length,
                    );
                    settings.setSearchToolModel(v);
                    setState(() {});
                  },
                ),
              ],
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ToolsScreen()),
                ),
                icon: const Icon(Icons.build_outlined, size: 18),
                label: const Text('Настроить'),
              ),
            ],
          ],
        );
      },
    );
  }
}

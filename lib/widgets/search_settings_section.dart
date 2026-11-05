// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/search/search_strategy.dart';
import '../core/storage.dart';
import '../theme.dart';

/// Секция «ПОИСК» на экране настроек: выбор режима поиска ([SearchMode]),
/// поле ключа пользовательского поискового API (режим customApi) и выбор
/// модели-инструмента (режим modelAsTool). Все значения сохраняются
/// в SharedPreferences через [AppSettings] и переживают перезапуск.
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

  /// Идентификаторы моделей из инструментов типа «модель»
  /// (Tool.typeModel) — кандидаты для роли модели-инструмента.
  List<String> _toolModels = const <String>[];

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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final mode = SearchModes.fromId(settings.searchMode);
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in SearchMode.values) _modeChip(m, p),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _hintFor(mode),
              style: TextStyle(color: p.muted, fontSize: 12.5, height: 1.35),
            ),
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
            ],
          ],
        );
      },
    );
  }

  /// Чип режима в общем стиле приложения (как выбор темы и типа модели):
  /// акцентная заливка и галочка у выбранного варианта.
  Widget _modeChip(SearchMode mode, Palette p) {
    final selected = SearchModes.fromId(settings.searchMode) == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => settings.setSearchMode(mode.id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? p.accent.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? p.accent : p.border,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(Icons.check_rounded, size: 15, color: p.accent),
              const SizedBox(width: 4),
            ],
            Text(
              mode.label,
              maxLines: 1,
              style: TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: selected ? p.accent : p.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

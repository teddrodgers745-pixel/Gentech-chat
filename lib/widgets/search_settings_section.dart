// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/search/search_strategy.dart';
import '../core/storage.dart';
// F2-settings-probe: авто-проба legacy-инструмента web_search ИСКЛЮЧЕНА
// из секции «ПОИСК» — она гейтила режим «Провайдер» поддержкой legacy-
// инструмента {'type': 'web_search'}, что противоречит контракту F2:
// polza:web_search — серверный инструмент Polza, независимый от нативного
// поиска модели (и от её поддержки вызова функций: для моделей без
// function calling Polza выполняет поиск как плагин web ДО обращения
// к модели — docs/gaidy/server-tools.md). Поэтому красный баннер
// «Текущая модель не поддерживает поиск» и кнопка «Повторить» в режиме
// «Провайдер» удалены вместе с пробой.
// Импорт сохранён по правилам проекта (не удалять существующие импорты).
// ignore: unused_import
import '../services/search_probe.dart';
// F2-settings-probe: ОДНО правило настроек и чата — эффективный режим
// поиска считает ChatService.effectiveSearchMode (тот же вызов, что
// использует ChatService._roundOnce при сборке тела запроса).
import '../services/chat_service.dart';
import '../theme.dart';
import '../ui/screens/tools_screen.dart';

/// Секция «ПОИСК» на экране настроек: выпадающий список режима поиска
/// (Выключен / Нативный / Провайдер / Инструмент) и динамическая область
/// под списком (SearchModeDetailView):
///  - off — ничего не показывается;
///  - native — правило ОДНО с чатом: эффективный режим считает
///    ChatService.effectiveSearchMode. Если «нативный» у модели без
///    нативного поиска переводится в «провайдер», показывается
///    спокойная информационная подпись (НЕ красная ошибка);
///  - provider — серверный поиск провайдера (для Polza — polza:web_search):
///    работает независимо от нативного поиска модели, поэтому НИКАКИХ
///    проб и баннеров — спокойное пояснение;
///  - modelAsTool — кнопка «⚙️ Настроить инструмент поиска»
///    (переход на экран инструментов) плюс выбор модели-инструмента;
///  - customApi — ключ пользовательского поискового API.
/// Все значения сохраняются в SharedPreferences через [AppSettings].
class SearchSettingsSection extends StatefulWidget {
  const SearchSettingsSection({super.key});

  @override
  State<SearchSettingsSection> createState() =>
      _SearchSettingsSectionState();
}

class _SearchSettingsSectionState extends State<SearchSettingsSection> {
  late final TextEditingController _apiKey;
  late final TextEditingController _toolModel;
  Timer? _debounce;
  bool _showKey = false;

  /// Идентификаторы моделей из инструментов типа «модель»
  /// (Tool.typeModel) — кандидаты для роли модели-инструмента.
  List<String> _toolModels = const <String>[];

  /// Режимы выпадающего списка: четыре варианта из задания.
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

  /// Подписи вариантов выпадающего списка.
  static String _modeLabel(SearchMode mode) => switch (mode) {
        SearchMode.off => 'Выключен',
        SearchMode.native => 'Нативный',
        SearchMode.provider => 'Провайдер',
        SearchMode.modelAsTool => 'Инструмент',
        SearchMode.customApi => 'Свой API',
      };

  /// Смена режима в выпадающем списке. Авто-проба режима «Провайдер»
  /// удалена (F2-settings-probe): режим не гейтится пробой и всегда
  /// показывается спокойно.
  void _onModeChanged(SearchMode? mode) {
    if (mode == null) return;
    settings.setSearchMode(mode.id);
    setState(() {});
  }

  /// Динамическая область под выпадающим списком (SearchModeDetailView).
  Widget _detailView(Palette p, SearchMode mode) {
    switch (mode) {
      case SearchMode.off:
        return const SizedBox.shrink();
      case SearchMode.native:
        return _nativeDetail(p);
      case SearchMode.provider:
        return _providerDetail(p);
      case SearchMode.modelAsTool:
        return _toolDetail(p);
      case SearchMode.customApi:
        return _customApiDetail(p);
    }
  }

  /// Активное подключение: адрес и модель, как их увидит чат
  /// (effectiveConfig — тот же источник, что у ChatService).
  EffectiveConfig _config() => effectiveConfig();

  /// Режим «Нативный»: правило ОДНО с чатом — эффективный режим считает
  /// ChatService.effectiveSearchMode (в чате тот же вызов применяется
  /// в _roundOnce). Если «нативный» у модели без нативного поиска
  /// переводится в «провайдер» — спокойная информационная подпись,
  /// а не красная ошибка.
  Widget _nativeDetail(Palette p) {
    final cfg = _config();
    final effective = ChatService.effectiveSearchMode(
      baseUrl: cfg.baseUrl,
      model: cfg.model,
      mode: SearchMode.native,
    );
    if (effective != SearchMode.native) {
      return Text(
        'У модели нет нативного поиска — будет использован поиск '
        'провайдера Polza.',
        style: TextStyle(color: p.muted, fontSize: 13, height: 1.35),
      );
    }
    return Text(
      'Поиск выполняется самой моделью. Настройки не требуются.',
      style: TextStyle(color: p.muted, fontSize: 13, height: 1.35),
    );
  }

  /// Режим «Провайдер»: серверный поиск выполняет провайдер
  /// (для Polza — polza:web_search). Он НЕ зависит от нативного поиска
  /// модели и НИКОГДА не показывает баннер «Текущая модель не
  /// поддерживает поиск»: проба legacy-инструмента web_search удалена
  /// как противоречащая контракту F2.
  Widget _providerDetail(Palette p) {
    final cfg = _config();
    final isPolza = cfg.baseUrl.trim().toLowerCase().contains('polza.ai');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isPolza
              ? 'Поиск выполняет сервер Polza инструментом polza:web_search — '
                  'работает независимо от нативного поиска модели.'
              : 'Поиск выполняется на стороне провайдера.',
          style: TextStyle(color: p.muted, fontSize: 13, height: 1.35),
        ),
        const SizedBox(height: 6),
        Text(
          'Если модель не принимает вызовы инструментов, поиск выполняет '
          'предзапрос моделью-инструментом.',
          style: TextStyle(color: p.muted, fontSize: 12.5, height: 1.35),
        ),
      ],
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

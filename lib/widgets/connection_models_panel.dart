// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/catalog/provider_catalog_service.dart';

/// Панель моделей внутри карточки подключения.
class ConnectionModelsPanel extends StatefulWidget {
  /// Идентификатор подключения для providerCatalog.sync
  /// ('polza' / 'routerai').
  final String connectionId;

  /// Base URL подключения без ключа в строке.
  final String baseUrl;

  /// Ключ/токен активной OAuth-сессии.
  final String apiKey;

  const ConnectionModelsPanel({
    super.key,
    required this.connectionId,
    required this.baseUrl,
    required this.apiKey,
  });

  @override
  State<ConnectionModelsPanel> createState() =>
      _ConnectionModelsPanelState();
}

class _ConnectionModelsPanelState extends State<ConnectionModelsPanel> {
  static const Duration _autoRefreshInterval = Duration(hours: 2);

  bool _loading = false;
  String? _error;
  String? _selectionError;
  List<String> _models = const <String>[];
  Timer? _autoRefreshTimer;

  /// Ответ запроса с предыдущими параметрами подключения не должен
  /// заменять список, загруженный для нового подключения.
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadModels());
    });
    _autoRefreshTimer = Timer.periodic(
      _autoRefreshInterval,
      (_) => unawaited(_loadModels()),
    );
  }

  @override
  void didUpdateWidget(covariant ConnectionModelsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connectionId == widget.connectionId &&
        oldWidget.baseUrl == widget.baseUrl &&
        oldWidget.apiKey == widget.apiKey) {
      return;
    }

    _requestVersion++;
    _loading = false;
    _error = null;
    _selectionError = null;
    _models = const <String>[];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadModels());
    });
  }

  @override
  void dispose() {
    _requestVersion++;
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    super.dispose();
  }

  static String _normalizeBase(String value) =>
      value.trim().replaceAll(RegExp(r'/+$'), '');

  static String _normalizeKey(String value) => value
      .trim()
      .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');

  /// Base URL подключения без хвостовых слэшей.
  String get _base => _normalizeBase(widget.baseUrl);

  /// Ключ подключения без префикса 'Bearer '.
  String get _key => _normalizeKey(widget.apiKey);

  /// Панель может менять модель только для фактической пары адрес/ключ.
  /// Имя подключения само по себе не доказывает совпадение реквизитов.
  bool _matchesEffectiveConnection(EffectiveConfig config) {
    final base = _base;
    final key = _key;
    return base.isNotEmpty &&
        key.isNotEmpty &&
        _normalizeBase(config.baseUrl) == base &&
        _normalizeKey(config.apiKey) == key;
  }

  Future<void> _loadModels() async {
    if (_loading) return;
    final base = _base;
    final key = _key;
    final connectionId = widget.connectionId;
    if (base.isEmpty || key.isEmpty) return;

    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await providerCatalog.sync(
        CatalogConnection(id: connectionId, baseUrl: base, apiKey: key),
        force: true,
      );
      if (!mounted || version != _requestVersion) return;

      final ids = <String>{
        for (final entry in result.entries)
          if (entry.id.trim().isNotEmpty) entry.id.trim(),
      }.toList()
        ..sort();

      setState(() {
        _loading = false;
        if (ids.isNotEmpty) _models = ids;
        _error = result.error;
        if (ids.isEmpty && _error == null) {
          _error = 'Сервер не вернул ни одной модели.';
        }
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить модели: проверьте сеть.';
      });
    }
  }

  /// Не меняем глобальное подключение в обход активного пресета или OAuth:
  /// это могло показать модель одной панели и отправить её через другую
  /// пару адрес/ключ. При несовпадении пользователь сначала выбирает
  /// подходящее подключение в настройках.
  Future<void> _pickModel(String v) async {
    if (!_matchesEffectiveConnection(effectiveConfig())) {
      setState(() {
        _selectionError =
            'Выберите в настройках профиль с этим адресом и ключом. '
            'Модель не изменена.';
      });
      return;
    }

    setState(() => _selectionError = null);
    try {
      await presets.updateActivePresetModel(v);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _selectionError = 'Не удалось сохранить выбранную модель.';
      });
      return;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[settings, presets]),
      builder: (context, _) {
        final p = settings.palette;
        final config = effectiveConfig();
        final matchesConnection = _matchesEffectiveConnection(config);
        final current = config.model.trim();
        final dropdownValue =
            matchesConnection && _models.contains(current) ? current : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OutlinedButton.icon(
              onPressed: _loading ? null : () => _loadModels(),
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                  color: p.accent.withValues(alpha: 0.6),
                  width: 1,
                ),
              ),
              icon: _loading
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: p.accent,
                      ),
                    )
                  : const Icon(Icons.keyboard_double_arrow_down, size: 24),
              label: const Text('Загрузить модели'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _error!,
                  softWrap: true,
                  style: TextStyle(color: p.muted, fontSize: 13),
                ),
              ),
            if (_selectionError != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _selectionError!,
                  softWrap: true,
                  style: TextStyle(color: p.muted, fontSize: 13),
                ),
              ),
            if (_models.isNotEmpty) ...[
              const SizedBox(height: 4),
              DropdownButtonFormField<String>(
                key: ValueKey<String?>(dropdownValue),
                initialValue: dropdownValue,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Выберите модель',
                ),
                items: [
                  for (final m in _models)
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
                  if (v != null) _pickModel(v);
                },
              ),
              const SizedBox(height: 4),
              Text(
                'Подключение: $_base',
                softWrap: true,
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
            ],
          ],
        );
      },
    );
  }
}

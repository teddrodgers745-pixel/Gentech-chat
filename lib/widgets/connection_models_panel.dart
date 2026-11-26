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

  /// Base URL подключения без хвостовых слэшей.
  String get _base => widget.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  /// Ключ подключения без префикса 'Bearer '.
  String get _key => widget.apiKey
      .trim()
      .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');

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

  /// Выбор модели принадлежит активному пресету: панель не пишет
  /// settings.model в обход PresetStore. Подключение (адрес/ключ)
  /// обновляется в глобальных настройках, чтобы системный дефолтный
  /// пресет использовал именно эту панель.
  Future<void> _pickModel(String v) async {
    final base = _base;
    final key = _key;
    if (base.isEmpty || key.isEmpty) return;
    settings.setConnection(url: base, key: key);
    await presets.updateActivePresetModel(v);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[settings, presets]),
      builder: (context, _) {
        final p = settings.palette;
        final current = settings.currentModelId.trim();
        final dropdownValue = _models.contains(current) ? current : null;
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

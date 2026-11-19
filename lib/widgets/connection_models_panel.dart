// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../app_state.dart';
import '../core/catalog/provider_catalog_service.dart';

/// Панель моделей внутри карточки подключения: кнопка «Загрузить модели»
/// и выпадающий список загруженных моделей.
///
/// Показывается ТОЛЬКО после успешного OAuth-входа соответствующего
/// провайдера (родитель рендерит панель в ветке authenticated).
/// После успешной загрузки список моделей сохраняется в состоянии
/// виджета и НЕ исчезает; фоновый Timer.periodic обновляет список
/// каждые 2 часа (таймер отменяется в dispose), кнопка — ручное
/// обновление.
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
  /// Интервал фонового автообновления списка моделей.
  static const Duration _autoRefreshInterval = Duration(hours: 2);

  static const Duration _requestTimeout = Duration(seconds: 30);

  bool _loading = false;
  String? _error;

  /// Загруженные модели (сохраняются в состоянии — список не исчезает).
  List<String> _models = const <String>[];

  Timer? _autoRefreshTimer;

  @override
  void initState() {
    super.initState();
    // Автообновление моделей активного подключения каждые 2 часа;
    // таймер отменяется в dispose.
    _autoRefreshTimer = Timer.periodic(
      _autoRefreshInterval,
      (_) => _loadModels(),
    );
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    super.dispose();
  }

  Future<void> _loadModels() async {
    if (_loading) return;
    final base = widget.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final key = widget.apiKey.trim();
    if (base.isEmpty || key.isEmpty) return;
    setState(() => _loading = true);
    // Параллельно обновляем каталог возможностей/цен этого подключения.
    unawaited(providerCatalog.sync(
      CatalogConnection(id: widget.connectionId, baseUrl: base, apiKey: key),
      force: true,
    ));
    try {
      final resp = await http
          .get(
            Uri.parse('$base/models'),
            headers: <String, String>{'Authorization': 'Bearer $key'},
          )
          .timeout(_requestTimeout);
      if (!mounted) return;
      if (resp.statusCode != 200) {
        setState(() {
          _loading = false;
          _error = 'Ошибка ${resp.statusCode}. Проверьте ключ и адрес.';
        });
        return;
      }
      final ids = _parseModelIds(resp.body);
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (ids.isNotEmpty) {
          _models = ids;
          _error = null;
        } else {
          // Пустой ответ: прежний список сохраняем, не исчезает.
          _error = 'Сервер не вернул ни одной модели.';
        }
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Сервер не ответил за 30 секунд.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить модели: проверьте сеть.';
      });
    }
  }

  /// Идентификаторы моделей из поля data ответа /models.
  static List<String> _parseModelIds(String body) {
    final ids = <String>{};
    try {
      final j = jsonDecode(body);
      if (j is Map && j['data'] is List) {
        for (final e in (j['data'] as List)) {
          String? id;
          if (e is Map) {
            final v = e['id'] ?? e['name'];
            if (v is String && v.trim().isNotEmpty) id = v.trim();
          } else if (e is String && e.trim().isNotEmpty) {
            id = e.trim();
          }
          if (id != null) ids.add(id);
        }
      }
    } catch (_) {}
    final list = ids.toList()..sort();
    return list;
  }

  /// Выбор модели: сохраняется в настройки (PresetStore синхронизируется
  /// внутри setConnection); подключение (адрес/ключ) не меняется.
  void _pickModel(String v) {
    settings.setConnection(mdl: v);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final current = settings.model.trim();
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
            ],
          ],
        );
      },
    );
  }
}


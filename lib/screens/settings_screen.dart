// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/storage.dart';
import '../models.dart';
import '../services/tts_service.dart';
import 'preset_edit_screen.dart';
import '../theme.dart';
import '../ui/screens/mcp_screen.dart';
import '../ui/screens/tools_screen.dart';
import '../widgets/message_view.dart';

const String _sampleMd = '''
## Пример ответа

Так будет выглядеть текст ответа модели: **жирный**, *курсив* и `инлайн-код`.

- Первый пункт списка
- Второй пункт списка

```dart
void main() {
  print("Привет, мир!");
}
```
''';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Экспорт: все пресеты из Storage -> JSON без API-ключей -> буфер обмена.
  Future<void> _exportPresets() async {
    final list = await storage.getPresets();
    if (!mounted) return;
    if (list.isEmpty) {
      _snack('Пресетов пока нет');
      return;
    }
    final data = <Map<String, dynamic>>[];
    for (final pr in list) {
      final j = pr.toJson();
      j['apiKey'] = ''; // ключи не покидают устройство
      data.add(j);
    }
    final payload = jsonEncode(<String, dynamic>{
      'app': 'GenTech Chat',
      'type': 'presets',
      'version': 1,
      'presets': data,
    });
    await Clipboard.setData(ClipboardData(text: payload));
    if (!mounted) return;
    _snack('Скопировано пресетов: ${list.length} (без API-ключей)');
  }

  /// Импорт: JSON из буфера обмена -> новые пресеты в Storage.
  Future<void> _importPresets() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = (clip?.text ?? '').trim();
    if (text.isEmpty) {
      _snack('Буфер обмена пуст');
      return;
    }
    try {
      final decoded = jsonDecode(text);
      final List<dynamic> list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map && decoded['presets'] is List) {
        list = decoded['presets'] as List;
      } else {
        throw const FormatException('no presets');
      }
      var added = 0;
      for (final item in list) {
        if (item is! Map) continue;
        final src = Preset.fromJson(Map<String, dynamic>.from(item));
        await presets.upsert(Preset(
          id: newId(),
          name: src.name.trim().isEmpty ? 'Импортированный пресет' : src.name,
          providerId: src.providerId,
          baseUrl: src.baseUrl,
          apiKey: '', // ключи не переносятся
          model: src.model,
          stream: src.stream,
          temperature: src.temperature,
          systemPrompt: src.systemPrompt,
        ));
        added++;
      }
      if (!mounted) return;
      setState(() {});
      _snack(
        added > 0 ? 'Импортировано пресетов: $added' : 'В JSON нет пресетов',
      );
    } catch (_) {
      _snack('Не удалось импортировать: неверный формат JSON');
    }
  }

  Future<void> _openPresetEditor(Preset? existing) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PresetEditScreen(existing: existing)),
    );
  }

  Future<void> _pickFont({
    required String title,
    required List<String> fonts,
    required String current,
    required String sample,
    required void Function(String) onPick,
  }) async {
    final p = settings.palette;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: p.surface,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (ctx, scroll) => ListView.builder(
          controller: scroll,
          itemCount: fonts.length + 1,
          itemBuilder: (ctx, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
              );
            }
            final f = fonts[i - 1];
            return ListTile(
              selected: f == current,
              title: Text(f, style: fontStyle(f, size: 18, color: p.text)),
              subtitle: Text(sample, style: fontStyle(f, size: 14, color: p.muted)),
              trailing: f == current ? Icon(Icons.check, color: p.accent) : null,
              onTap: () {
                onPick(f);
                Navigator.pop(ctx);
              },
            );
          },
        ),
      ),
    );
  }

  Widget _section(Palette p, String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 10),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: p.accent,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[settings, settings.fontSizeN]),
      builder: (context, _) {
        final p = settings.palette;
        return Scaffold(
          appBar: AppBar(title: const Text('Настройки')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              _section(p, 'ОФОРМЛЕНИЕ'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final x in palettes)
                    ChoiceChip(
                      label: Text(x.name),
                      selected: x.id == settings.paletteId,
                      avatar: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: x.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      onSelected: (_) => settings.setPalette(x.id),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Шрифт текста'),
                subtitle: Text(
                  settings.bodyFont,
                  style: fontStyle(settings.bodyFont, size: 16, color: p.muted),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pickFont(
                  title: 'Шрифт текста',
                  fonts: bodyFonts,
                  current: settings.bodyFont,
                  sample: 'Съешь ещё этих мягких французских булок',
                  onPick: settings.setBodyFont,
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Шрифт кода'),
                subtitle: Text(
                  settings.codeFont,
                  style: fontStyle(settings.codeFont, size: 15, color: p.muted),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pickFont(
                  title: 'Шрифт кода',
                  fonts: codeFonts,
                  current: settings.codeFont,
                  sample: 'final x = 42; // 0O 1lI',
                  onPick: settings.setCodeFont,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Размер текста: ${settings.fontSizeN.value.toStringAsFixed(0)}',
                style: TextStyle(color: p.text),
              ),
              Slider(
                value: settings.fontSizeN.value.clamp(12.0, 30.0).toDouble(),
                min: 12,
                max: 30,
                divisions: 36,
                activeColor: p.accent,
                onChanged: settings.setFontSize,
                onChangeEnd: (_) => settings.saveNow(),
              ),
              Text(
                'Межстрочный интервал: ${settings.lineHeight.toStringAsFixed(2)}',
                style: TextStyle(color: p.text),
              ),
              Slider(
                value: settings.lineHeight.clamp(1.2, 2.0).toDouble(),
                min: 1.2,
                max: 2.0,
                divisions: 16,
                activeColor: p.accent,
                onChanged: settings.setLineHeight,
                onChangeEnd: (_) => settings.saveNow(),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: p.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: p.border),
                ),
                child: const RichMarkdown(_sampleMd),
              ),
              const SizedBox(height: 12),
              Text(
                'Размер текста также меняется щипком двумя пальцами прямо в чате.',
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
              _section(p, 'ОЗВУЧКА'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Автоозвучка ответов'),
                subtitle: Text(
                  'Новые ответы модели озвучиваются автоматически',
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
                value: settings.autoTts,
                onChanged: (v) {
                  settings.setAutoTts(v);
                  if (!v) ttsService.stop();
                },
              ),
              Text(
                'Озвучить конкретный ответ можно кнопкой динамика рядом с кнопкой копирования. Повторное нажатие останавливает чтение.',
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
              _section(p, 'ИНСТРУМЕНТЫ И API'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.build_outlined, color: p.accent),
                title: const Text('Инструменты'),
                subtitle: Text(
                  'Внешние инструменты, которые модель сможет вызывать',
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ToolsScreen()),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.dns_outlined, color: p.accent),
                title: const Text('Коннекторы'),
                subtitle: Text(
                  'Подключение MCP-серверов и внешних источников данных',
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const McpScreen()),
                ),
              ),
              _section(p, 'МОДЕЛИ И ПРОФИЛИ'),
              Text(
                'Нажмите на пресет, чтобы сделать его активным — он будет '
                'использоваться для всех запросов в чате.',
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
              ListenableBuilder(
                listenable: presets,
                builder: (context, _) {
                  final active = presets.active;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.tune_rounded, color: p.muted),
                        title: const Text('Без пресета'),
                        subtitle: Text(
                          'Подключение по умолчанию, без профиля',
                          style: TextStyle(color: p.muted, fontSize: 12),
                        ),
                        trailing: active == null
                            ? Icon(Icons.check, color: p.accent)
                            : null,
                        onTap: () => presets.clearActive(),
                      ),
                      for (final pr in presets.items)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.auto_awesome, color: p.accent),
                          title: Text(
                            pr.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            pr.model.trim().isEmpty
                                ? 'Модель не задана'
                                : pr.model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: p.muted, fontSize: 12),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (active?.id == pr.id)
                                Icon(Icons.check, color: p.accent),
                              IconButton(
                                tooltip: 'Изменить',
                                icon: const Icon(Icons.edit_outlined, size: 20),
                                onPressed: () => _openPresetEditor(pr),
                              ),
                            ],
                          ),
                          onTap: () => presets.setActive(pr.id),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 4),
              OutlinedButton.icon(
                onPressed: () => _openPresetEditor(null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Создать пресет'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _exportPresets,
                icon: const Icon(Icons.upload_outlined, size: 18),
                label: const Text('Экспорт пресетов'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _importPresets,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Импорт пресетов'),
              ),
              const SizedBox(height: 8),
              Text(
                'Экспорт копирует JSON всех пресетов в буфер обмена без API-ключей. Импорт добавляет пресеты из JSON в буфере обмена.',
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
            ],
          ),
        );
      },
    );
  }
}

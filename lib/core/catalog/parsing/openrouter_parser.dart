// Copyright (c) 2026 Minkail. All rights reserved.

import '../catalog_entry.dart';
import 'reasoning_levels.dart';

/// Разбирает одну модель из ответа OpenRouter API (`GET /api/v1/models`).
/// Возвращает `null`, если у записи отсутствует валидный непустой `id`.
CatalogEntry? parseOpenRouterModel(Map<String, dynamic> m) {
  final id = _str(m['id']);
  if (id == null || id.isEmpty) return null;

  final name = _str(m['name']) ?? id;
  final contextLength = _int(m['context_length']);

  final topProvider = _map(m['top_provider']);
  final maxCompletionTokens = _int(topProvider?['max_completion_tokens']) ??
      _int(m['max_completion_tokens']);

  // Модальности и тип модели из architecture.
  final arch = _map(m['architecture']);
  final inputMods = _stringList(arch?['input_modalities']);
  final outputMods = _stringList(arch?['output_modalities']);
  final modStr = _str(arch?['modality'])?.toLowerCase() ?? '';

  final modalities = <String>{...inputMods, ...outputMods};
  if (modalities.isEmpty && modStr.isNotEmpty) {
    for (final part in modStr.split(RegExp(r'[\+>\-\s,/]+'))) {
      final token = part.trim();
      if (token.isNotEmpty) modalities.add(token);
    }
  }

  final type = _resolveType(outputMods, modStr);

  // Поддерживаемые параметры и инструменты.
  final supportedParams = _stringList(m['supported_parameters']);
  final hasSupportedParamsKey = m.containsKey('supported_parameters') &&
      m['supported_parameters'] is List;
  final bool? supportsTools = hasSupportedParamsKey
      ? (supportedParams.contains('tools') ||
          supportedParams.contains('tool_choice') ||
          supportedParams.contains('functions'))
      : null;

  // Размышления (reasoning).
  final reasoningMap = _map(m['reasoning']);
  final efforts = _stringList(reasoningMap?['supported_efforts']);
  final defaultEffort = _str(reasoningMap?['default_effort']) ??
      _str(reasoningMap?['effort']) ??
      '';
  final mandatory = reasoningMap?['mandatory'] == true ||
      reasoningMap?['required'] == true;

  CatalogReasoning? reasoning;
  List<String>? reasoningLevels;
  bool? reasoningCapabilityKnown;
  bool reasoningUnknown = false;

  if (efforts.isNotEmpty) {
    reasoningLevels = normalizeReasoningLevels(efforts, mandatory: mandatory);
    reasoning = CatalogReasoning(
      levels: reasoningLevels,
      defaultEffort: normalizeReasoningEffort(defaultEffort),
      mandatory: mandatory,
    );
    reasoningCapabilityKnown = true;
  } else if (supportedParams.contains('reasoning') ||
      supportedParams.contains('include_reasoning')) {
    reasoningCapabilityKnown = true;
    reasoningLevels = null;
  } else {
    reasoningCapabilityKnown = null;
    reasoningLevels = null;
    reasoningUnknown = true;
  }

  // Цены: в OpenRouter указаны в USD за 1 токен -> умножаем на 1 000 000.
  final pricing = _map(m['pricing']);
  final rawPromptPrice = _double(pricing?['prompt']);
  final rawCompletionPrice = _double(pricing?['completion']);

  final double? priceIn =
      (rawPromptPrice != null && rawPromptPrice >= 0)
          ? rawPromptPrice * 1000000.0
          : null;
  final double? priceOut =
      (rawCompletionPrice != null && rawCompletionPrice >= 0)
          ? rawCompletionPrice * 1000000.0
          : null;
  final hasPrice = priceIn != null || priceOut != null;

  // mediaParams хранит только флаги supported_parameters.
  final mediaParams = <String, dynamic>{
    for (final param in supportedParams) param: true,
  };

  return CatalogEntry(
    id: id,
    name: name,
    type: type,
    modalities: modalities.toList(growable: false),
    contextLength: contextLength,
    maxCompletionTokens: maxCompletionTokens,
    reasoning: reasoning,
    reasoningLevels: reasoningLevels,
    reasoningCapabilityKnown: reasoningCapabilityKnown,
    reasoningUnknown: reasoningUnknown,
    supportedParams: supportedParams,
    supportsTools: supportsTools,
    priceIn: priceIn,
    priceOut: priceOut,
    currency: hasPrice ? 'USD' : '',
    pricingUnit: null,
    mediaPrice: null,
    mediaParams: mediaParams,
    capabilitiesSource: CatalogSources.openrouter,
    priceSource: hasPrice ? CatalogSources.connection : null,
  );
}

String _resolveType(List<String> outputMods, String modStr) {
  final lowerOut = outputMods.map((e) => e.toLowerCase()).toSet();
  if (lowerOut.contains('image')) return 'image';
  if (lowerOut.contains('video')) return 'video';
  if (lowerOut.contains('audio') || lowerOut.contains('speech')) return 'tts';
  if (lowerOut.contains('embedding') || lowerOut.contains('embeddings')) {
    return 'embedding';
  }
  if (lowerOut.contains('text')) return 'chat';

  if (modStr.endsWith('->image')) return 'image';
  if (modStr.endsWith('->video')) return 'video';
  if (modStr.endsWith('->audio')) return 'tts';
  if (modStr.contains('embedding')) return 'embedding';
  if (modStr.endsWith('->text')) return 'chat';
  return 'chat';
}

String? _str(Object? v) {
  if (v is String) {
    final s = v.trim();
    return s.isEmpty ? null : s;
  }
  return null;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? _double(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) {
    return double.tryParse(v.trim().replaceAll(',', '.'));
  }
  return null;
}

Map<String, dynamic>? _map(Object? v) {
  if (v is! Map) return null;
  return <String, dynamic>{
    for (final e in v.entries)
      if (e.key != null) e.key.toString(): e.value,
  };
}

List<String> _stringList(Object? v) {
  if (v is! List) return const <String>[];
  final out = <String>[];
  for (final item in v) {
    if (item == null || item is Map || item is List) continue;
    final s = item.toString().trim();
    if (s.isNotEmpty) out.add(s);
  }
  return out;
}

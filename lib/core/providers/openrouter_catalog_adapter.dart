// Copyright (c) 2026 Minkail. All rights reserved.

import '../models/model_info.dart';
import 'model_catalog_adapter.dart';

/// Адаптер каталога OpenRouter (GET https://openrouter.ai/api/v1/models).
///
/// Формат ответа:
/// {"data": [{
///   "id": "vendor/model",
///   "name": "Vendor: Model",
///   "context_length": 128000,
///   "pricing": {"prompt": "0.0000015", "completion": "0.000002"},
///   "architecture": {"modality": "text->text",
///                    "input_modalities": ["text", "image"],
///                    "output_modalities": ["text"]},
///   "supported_parameters": ["tools", "reasoning", ...]
/// }]}
/// Цены приходят за один токен строками — переводятся в цену за миллион.
class OpenRouterCatalogAdapter extends ModelCatalogAdapter {
  const OpenRouterCatalogAdapter();

  @override
  String get providerId => 'openrouter';

  @override
  List<ModelInfo> parseCatalog(Map<String, dynamic> responseBody) {
    final data = responseBody['data'];
    if (data is! List) return const <ModelInfo>[];
    final out = <ModelInfo>[];
    final seen = <String>{};
    for (final e in data) {
      final map = ModelCatalogAdapter.asMap(e);
      if (map == null) continue;
      final info = parseModelEntry(map);
      if (info != null && seen.add(info.id)) out.add(info);
    }
    return out;
  }

  @override
  ModelInfo? parseModelEntry(Map<String, dynamic> entry) {
    final id = ((entry['id'] as String?) ?? '').trim();
    if (id.isEmpty) return null;

    final arch = ModelCatalogAdapter.asMap(entry['architecture']);
    final input =
        ModelCatalogAdapter.parseModalities(arch?['input_modalities']);
    final output =
        ModelCatalogAdapter.parseModalities(arch?['output_modalities']);

    // Если каталог не перечислил модальности списком — разбираем
    // устаревшее поле modality вида "text->image".
    final legacy = ((arch?['modality'] as String?) ?? '').trim();
    final arrow = legacy.indexOf('->');
    if (arrow > 0) {
      final inM = Modality.fromName(legacy.substring(0, arrow).trim());
      final outM = Modality.fromName(legacy.substring(arrow + 2).trim());
      if (input.isEmpty && inM != null) input.add(inM);
      if (output.isEmpty && outM != null) output.add(outM);
    }
    // Последний предохранитель: текстовые модальности по умолчанию.
    if (input.isEmpty) input.add(Modality.text);
    if (output.isEmpty) output.add(Modality.text);

    final params = ModelCatalogAdapter.asStringList(entry['supported_parameters']);
    final name = ((entry['name'] as String?) ?? '').trim();

    return ModelInfo(
      id: id,
      displayName: name.isEmpty ? null : name,
      providerId: providerId,
      inputModalities: input,
      outputModalities: output,
      route: GenerationRoute.chatCompletions,
      supportsStreaming: true,
      supportsTools: params.contains('tools'),
      supportsReasoning: params.contains('reasoning'),
      contextLength: ModelCatalogAdapter.asInt(entry['context_length']),
      pricing: ModelCatalogAdapter.parsePricing(entry),
      source: CapabilitySource.providerCatalog,
    );
  }
}

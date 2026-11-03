// Copyright (c) 2026 Minkail. All rights reserved.

import '../models/model_info.dart';
import 'heuristic_rules.dart';
import 'model_catalog_adapter.dart';

/// Универсальный адаптер каталога моделей (GET {baseUrl}/models).
///
/// Разбирает наиболее употребительные форматы OpenAI-совместимых
/// каталогов и извлекает:
///  - architecture.modality ('text->image'), architecture.input_modalities,
///    architecture.output_modalities — формат OpenRouter;
///  - type, capabilities, modalities — формат Polza / RouterAI;
///  - pricing (prompt/completion либо input/output) и context_length.
///
/// Поля, которых в записи каталога нет, добираются эвристикой по
/// идентификатору модели ([HeuristicRules]); итог помечается источником
/// [CapabilitySource.providerCatalog].
class UniversalCatalogAdapter extends ModelCatalogAdapter {
  @override
  final String providerId;

  /// Идентификатор провайдера задаётся снаружи ('routerai', ...);
  /// по умолчанию — нейтральный 'universal'.
  const UniversalCatalogAdapter([this.providerId = 'universal']);

  @override
  List<ModelInfo> parseCatalog(Map<String, dynamic> responseBody) {
    final data = responseBody['data'] ?? responseBody['models'];
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
    final id = _idFrom(entry);
    if (id == null || id.isEmpty) return null;
    final name = ((entry['name'] as String?) ?? '').trim();
    final base = HeuristicRules.build(
      id,
      displayName: name.isEmpty ? null : name,
      providerId: providerId,
    );

    // --- модальности из architecture (формат OpenRouter) ---
    final arch = ModelCatalogAdapter.asMap(entry['architecture']);
    var input = ModelCatalogAdapter.parseModalities(arch?['input_modalities']);
    var output =
        ModelCatalogAdapter.parseModalities(arch?['output_modalities']);
    final legacy = ((arch?['modality'] as String?) ?? '').trim();
    final arrow = legacy.indexOf('->');
    if (arrow > 0) {
      final inM = Modality.fromName(legacy.substring(0, arrow).trim());
      final outM = Modality.fromName(legacy.substring(arrow + 2).trim());
      if (input.isEmpty && inM != null) input = <Modality>{inM};
      if (output.isEmpty && outM != null) output = <Modality>{outM};
    }

    // Модальности на верхнем уровне записи (часть каталогов не кладёт
    // их в architecture).
    if (input.isEmpty) {
      input = ModelCatalogAdapter.parseModalities(entry['input_modalities']);
    }
    if (output.isEmpty) {
      output = ModelCatalogAdapter.parseModalities(entry['output_modalities']);
    }

    // --- модальности из поля modalities (Polza, RouterAI) ---
    if (input.isEmpty && output.isEmpty) {
      final pair = _modalitiesField(entry['modalities']);
      input = pair.$1;
      output = pair.$2;
    }

    // --- маршрут из type / capabilities ---
    final caps = _capabilities(entry);
    final route = _routeFromType(entry['type']) ??
        _routeFromCapabilities(caps) ??
        base.route;

    // Выходные модальности из маршрута каталога, если списков не было.
    if (output.isEmpty) {
      output = switch (route) {
        GenerationRoute.imageGeneration => const <Modality>{Modality.image},
        GenerationRoute.asyncJob => const <Modality>{Modality.video},
        GenerationRoute.textToSpeech ||
        GenerationRoute.liveRealtime =>
          const <Modality>{Modality.audio, Modality.text},
        _ => base.outputModalities,
      };
    }
    if (input.isEmpty) input = base.inputModalities;

    final ctx = ModelCatalogAdapter.asInt(entry['context_length']) ??
        ModelCatalogAdapter.asInt(entry['contextLength']) ??
        ModelCatalogAdapter.asInt(entry['context_window']);

    return base.copyWith(
      inputModalities: input,
      outputModalities: output,
      route: route,
      supportsTools: caps.contains('tools') || caps.contains('function_calling')
          ? true
          : base.supportsTools,
      supportsReasoning:
          caps.contains('reasoning') || caps.contains('thinking')
              ? true
              : base.supportsReasoning,
      contextLength: ctx ?? base.contextLength,
      pricing: ModelCatalogAdapter.parsePricing(entry) ?? base.pricing,
      source: CapabilitySource.providerCatalog,
    );
  }

  /// Идентификатор модели: id, затем name/model (терпимо к каталогам).
  static String? _idFrom(Map<String, dynamic> entry) {
    for (final key in const <String>['id', 'name', 'model']) {
      final v = entry[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  /// Поле modalities: объект {'input': [...], 'output': [...]} либо
  /// плоский список (считается и входом, и выходом одновременно).
  static (Set<Modality>, Set<Modality>) _modalitiesField(Object? raw) {
    if (raw is Map) {
      final m = Map<String, dynamic>.from(raw);
      final input = ModelCatalogAdapter.parseModalities(
        m['input'] ?? m['in'] ?? m['input_modalities'] ?? m['inputs'],
      );
      final output = ModelCatalogAdapter.parseModalities(
        m['output'] ?? m['out'] ?? m['output_modalities'] ?? m['outputs'],
      );
      return (input, output);
    }
    if (raw is List) {
      final both = ModelCatalogAdapter.parseModalities(raw);
      if (both.isEmpty) return (const <Modality>{}, const <Modality>{});
      return (both, both);
    }
    return (const <Modality>{}, const <Modality>{});
  }

  /// capabilities: список строк, объект (ключи со значением true) либо
  /// одиночная строка — всё приводится к множеству в нижнем регистре.
  static Set<String> _capabilities(Map<String, dynamic> entry) {
    final raw = entry['capabilities'];
    final out = <String>{};
    if (raw is List) {
      for (final e in raw) {
        if (e != null) out.add(e.toString().trim().toLowerCase());
      }
    } else if (raw is Map) {
      raw.forEach((k, v) {
        if (v == true || v is Map || v is List) {
          out.add(k.toString().trim().toLowerCase());
        }
      });
    } else if (raw is String) {
      final s = raw.trim().toLowerCase();
      if (s.isNotEmpty) out.add(s);
    }
    return out;
  }

  /// Маршрут из строки типа ('image', 'video', 'chat' ...).
  static GenerationRoute? _routeFromType(Object? raw) {
    if (raw is! String) return null;
    return _routeFromToken(raw);
  }

  /// Маршрут из набора capabilities: сначала ищем точные генеративные
  /// маркеры, и только затем нейтральные ('chat', 'text') — иначе
  /// capability 'chat' перебивала бы 'image_generation'.
  static GenerationRoute? _routeFromCapabilities(Set<String> caps) {
    for (final c in caps) {
      final r = _routeFromToken(c);
      if (r != null && r != GenerationRoute.chatCompletions) return r;
    }
    for (final c in caps) {
      final r = _routeFromToken(c);
      if (r != null) return r;
    }
    return null;
  }

  /// Маршрут по одному токену; null — токен не распознан.
  static GenerationRoute? _routeFromToken(String raw) {
    final t = raw.trim().toLowerCase();
    if (t.isEmpty) return null;
    if (t.contains('image_generation') ||
        t.contains('text-to-image') ||
        t.contains('image_output') ||
        t == 'image' ||
        t == 'images') {
      return GenerationRoute.imageGeneration;
    }
    if (t.contains('video_generation') ||
        t.contains('text-to-video') ||
        t.contains('video_output') ||
        t == 'video' ||
        t.contains('async')) {
      return GenerationRoute.asyncJob;
    }
    if (t.contains('embed') || t.contains('rerank')) {
      return GenerationRoute.embeddings;
    }
    if (t.contains('transcri') ||
        t == 'stt' ||
        t == 'asr' ||
        t.contains('speech-to-text')) {
      return GenerationRoute.audioTranscription;
    }
    if (t.contains('tts') ||
        t.contains('text-to-speech') ||
        t.contains('speech')) {
      return GenerationRoute.textToSpeech;
    }
    if (t.contains('realtime') || t == 'live') {
      return GenerationRoute.liveRealtime;
    }
    if (t == 'chat' ||
        t == 'text' ||
        t.contains('text-generation') ||
        t.contains('language')) {
      return GenerationRoute.chatCompletions;
    }
    return null;
  }
}

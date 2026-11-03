// Copyright (c) 2026 Minkail. All rights reserved.

import '../models/model_info.dart';

/// Эвристики определения возможностей модели по её идентификатору.
/// Применяются, когда каталог провайдера не дал данных или его нет:
/// по ключевым словам в id выводим маршрут, модальности и флаги.
/// Это не источник истины, а разумная догадка — при появлении данных
/// из каталога они имеют приоритет (см. [ModelInfoResolver]).
abstract final class HeuristicRules {
  // --- семейства моделей генерации изображений ---
  static const List<String> _imageGenHints = <String>[
    'dall-e', 'dalle', 'flux', 'stable-diffusion', 'stablediffusion',
    'sdxl', 'sd3', 'imagen', 'recraft', 'ideogram', 'kolors', 'cogview',
    'seedream', 'hidream', 'qwen-image', 'gpt-image', 'grok-2-image',
    'midjourney',
    // wanx — генератор изображений Ali: без этой подсказки подстрока 'wan'
    // из видео-списка ошибочно утащила бы его в видео.
    'wanx',
  ];

  // --- генераторы видео (асинхронная задача, результат приходит позже) ---
  static const List<String> _videoGenHints = <String>[
    'kling', 'wan', 'sora', 'veo', 'runway', 'gen-3', 'luma', 'ray-2',
    'minimax-video', 'hailuo', 'hunyuan-video', 'seedance', 'cogvideo',
    'mochi', 'pika',
  ];

  // --- голосовые realtime-модели (двусторонний аудиочат) ---
  static const List<String> _liveVoiceHints = <String>[
    'realtime', 'native-audio', 'live',
  ];

  // --- озвучка (text-to-speech) ---
  static const List<String> _ttsHints = <String>[
    'tts', 'speak', 'speech-1', 'voice',
  ];

  // --- распознавание речи (speech-to-text) ---
  static const List<String> _transcriptionHints = <String>[
    'whisper', 'transcribe', 'transcription', 'asr',
  ];

  // --- эмбеддинги и реранкинг ---
  static const List<String> _embeddingHints = <String>[
    'embedding', 'embed', 'rerank', 'bge-', 'e5-', 'nomic',
  ];

  // --- приём изображений на вход (vision) ---
  static const List<String> _visionHints = <String>[
    'vision', 'omni', '-vl', 'vl-', 'llava', 'pixtral', 'internvl',
    'molmo', 'minicpm-v', 'glm-4v', 'qvq', 'qwen-vl', 'grok-vision',
    'grok-2-vision', 'deepseek-vl',
    'gpt-4o', 'gpt-4.1', 'gpt-4-turbo', 'gpt-5', 'gemini', 'claude-3',
    'claude-4', 'phi-3-vision', 'phi-4-multimodal', 'gemma-3',
  ];

  // --- приём аудио/видео на вход ---
  static const List<String> _audioInputHints = <String>[
    'omni', 'audio-in', 'native-audio', 'realtime',
  ];
  static const List<String> _videoInputHints = <String>[
    'omni', 'video-in', 'gemini-2', 'gemini-3',
  ];

  // --- «размышляющие» модели: длинные, но однозначные подстроки ---
  static const List<String> _reasoningHints = <String>[
    'thinking', 'think', 'reasoner', 'reasoning', 'deepseek-r',
    'gpt-5', 'qwq', 'magistral', 'gemini-2.5', 'gemini-3',
  ];

  // --- короткие токены размышлений, проверяются по границам слова ---
  static const List<String> _reasoningTokens = <String>[
    'o1', 'o3', 'o4', 'r1',
  ];

  /// Нормализация идентификатора: нижний регистр, снятие префикса 'models/'
  /// и суффикса '@provider=...' (используется в быстрой настройке).
  static String normalize(String rawId) {
    var s = rawId.trim().toLowerCase();
    if (s.startsWith('models/')) s = s.substring(7);
    final at = s.indexOf('@provider=');
    if (at >= 0) s = s.substring(0, at);
    return s.trim();
  }

  /// Содержит ли [id] хоть одну подстроку из [hints].
  static bool containsAny(String id, List<String> hints) {
    for (final h in hints) {
      if (id.contains(h)) return true;
    }
    return false;
  }

  /// Токен в границах не-буквенно-цифровых символов:
  /// 'o1' найдётся в 'gpt-o1-mini', но не в 'gpt-4o1'.
  static bool hasToken(String id, String token) {
    final escaped = RegExp.escape(token);
    return RegExp('(^|[^a-z0-9])$escaped(\$|[^a-z0-9])').hasMatch(id);
  }

  /// Маршрут генерации по семейству модели.
  static GenerationRoute inferRoute(String id) {
    if (containsAny(id, _imageGenHints)) {
      return GenerationRoute.imageGeneration;
    }
    // Видео проверяется ПОСЛЕ изображений: 'gen-3' входит в 'imagen-3',
    // и без этого порядка картинка misклассифицировалась бы как видео.
    if (containsAny(id, _videoGenHints)) {
      return GenerationRoute.asyncJob;
    }
    if (containsAny(id, _embeddingHints)) return GenerationRoute.embeddings;
    if (containsAny(id, _liveVoiceHints)) return GenerationRoute.liveRealtime;
    if (containsAny(id, _ttsHints)) return GenerationRoute.textToSpeech;
    if (containsAny(id, _transcriptionHints)) {
      return GenerationRoute.audioTranscription;
    }
    return GenerationRoute.chatCompletions;
  }

  /// Модальности входа: текст всегда, остальное — по семейству и флагам.
  static Set<Modality> inferInputModalities(
    String id, {
    GenerationRoute? route,
  }) {
    final r = route ?? inferRoute(id);
    switch (r) {
      case GenerationRoute.audioTranscription:
        return const <Modality>{Modality.audio};
      case GenerationRoute.embeddings:
      case GenerationRoute.textToSpeech:
      case GenerationRoute.imageGeneration:
      case GenerationRoute.asyncJob:
        return const <Modality>{Modality.text};
      case GenerationRoute.liveRealtime:
        final out = <Modality>{Modality.text, Modality.audio};
        if (containsAny(id, _visionHints)) out.add(Modality.image);
        return out;
      case GenerationRoute.chatCompletions:
      case GenerationRoute.responsesApi:
        final out = <Modality>{Modality.text};
        if (containsAny(id, _visionHints)) out.add(Modality.image);
        if (containsAny(id, _audioInputHints)) out.add(Modality.audio);
        if (containsAny(id, _videoInputHints)) out.add(Modality.video);
        return out;
    }
  }

  /// Модальности выхода по маршруту и семейству.
  static Set<Modality> inferOutputModalities(
    String id, {
    GenerationRoute? route,
  }) {
    final r = route ?? inferRoute(id);
    switch (r) {
      case GenerationRoute.imageGeneration:
        return const <Modality>{Modality.image};
      case GenerationRoute.asyncJob:
        return const <Modality>{Modality.video};
      case GenerationRoute.textToSpeech:
      case GenerationRoute.liveRealtime:
        return const <Modality>{Modality.audio, Modality.text};
      case GenerationRoute.audioTranscription:
        return const <Modality>{Modality.text};
      case GenerationRoute.embeddings:
        return const <Modality>{};
      case GenerationRoute.chatCompletions:
      case GenerationRoute.responsesApi:
        return const <Modality>{Modality.text};
    }
  }

  /// Поддержка function calling: только обычные чат-маршруты.
  static bool inferSupportsTools(String id, {GenerationRoute? route}) {
    final r = route ?? inferRoute(id);
    return r.isChat;
  }

  /// Поддержка «размышлений»: длинные подстроки + короткие токены
  /// по границам слова (o1, o3, r1 ...).
  static bool inferSupportsReasoning(String id) {
    if (containsAny(id, _reasoningHints)) return true;
    for (final t in _reasoningTokens) {
      if (hasToken(id, t)) return true;
    }
    return false;
  }

  /// Контекстное окно из суффикса вида '-128k', '-32k', '-1m'.
  /// Возвращаем последний найденный суффикс; null — если не распознан.
  static int? inferContextLength(String id) {
    final matches =
        RegExp(r'-(\d+(?:\.\d+)?)([km])(?![a-z0-9])').allMatches(id);
    if (matches.isEmpty) return null;
    final m = matches.last;
    final num = double.tryParse(m.group(1)!);
    if (num == null) return null;
    final unit = m.group(2);
    final value = unit == 'm' ? num * 1000000 : num * 1000;
    return value.round();
  }

  /// Полная догадка о модели по идентификатору. Используется
  /// резолвером, когда каталог провайдера ничего не сообщил.
  static ModelInfo build(
    String rawId, {
    String? displayName,
    String providerId = '',
  }) {
    final id = normalize(rawId);
    final route = inferRoute(id);
    final isChat = route.isChat;
    return ModelInfo(
      id: rawId.trim(),
      displayName: displayName,
      providerId: providerId,
      inputModalities: inferInputModalities(id, route: route),
      outputModalities: inferOutputModalities(id, route: route),
      route: route,
      supportsStreaming: isChat,
      supportsTools: inferSupportsTools(id, route: route),
      supportsReasoning: isChat && inferSupportsReasoning(id),
      contextLength: inferContextLength(id),
      source: CapabilitySource.heuristic,
    );
  }
}

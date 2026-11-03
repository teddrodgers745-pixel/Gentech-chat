// Copyright (c) 2026 Minkail. All rights reserved.

/// Схема параметров генерации: описание того, какие параметры запроса
/// (пропорции, размер, длительность, качество, референсное изображение)
/// поддерживает модель, как их показывает интерфейс и как собирает
/// payload запроса к провайдеру. Данные нейтральны: значения и подписи
/// приходят из каталога/настроек, в коде ничего не зашито.
library;

/// Стандартные ключи параметров генерации в payload запроса и в
/// сохранённых значениях интерфейса.
abstract final class ParamKeys {
  /// Пропорция изображения/видео ('1:1', '16:9', ...).
  static const String aspectRatio = 'aspect_ratio';

  /// Размер холста ('1024x1024', '1792x1024', ...).
  static const String size = 'size';

  /// Длительность видео в секундах ('5', '10', ...).
  static const String duration = 'duration';

  /// Разрешение вывода ('720p', '1080p', ...).
  static const String resolution = 'resolution';

  /// Качество генерации ('standard', 'hd', ...).
  static const String quality = 'quality';

  /// Референсное изображение (путь либо ссылка на файл).
  static const String referenceImage = 'reference_image';
}

/// Тип параметра: как его показывает интерфейс и как проверяется значение.
enum ParamType {
  /// Выбор из фиксированного списка строковых вариантов.
  enumChoice,

  /// Выбор из списка числовых значений (длительность, разрешение и т.п.).
  intChoice,

  /// Переключатель включено/выключено.
  boolean,

  /// Референсное изображение (локальный путь либо ссылка).
  referenceImage,
}

/// Стиль сборки payload запроса к провайдеру.
enum PayloadStyle {
  /// Плоские поля рядом с model/prompt — большинство OpenAI-совместимых
  /// провайдеров (aspect_ratio, size и т.п. на верхнем уровне).
  standardFlat,

  /// Передаётся только поле size (провайдеры, не понимающие aspect_ratio).
  sizeOnly,

  /// OpenAI Sora: параметры вложены в собственный блок запроса.
  openAiSora,

  /// OpenRouter chat/completions: конфиг уходит внутри сообщения.
  openRouterChatConfig,
}

/// Один вариант выбора параметра: машинное значение, подпись для
/// интерфейса и необязательный отображённый размер холста.
class ParamOption {
  final String value;
  final String label;

  /// Размер холста, в который превращается вариант ('16:9' -> '1792x1024');
  /// null — отображение не требуется.
  final String? mappedSize;

  const ParamOption({
    required this.value,
    required this.label,
    this.mappedSize,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'value': value,
        'label': label,
        if (mappedSize != null) 'mappedSize': mappedSize,
      };

  factory ParamOption.fromJson(Map<String, dynamic> j) => ParamOption(
        value: (j['value'] as String?) ?? '',
        label: (j['label'] as String?) ?? '',
        mappedSize: j['mappedSize'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ParamOption && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ParamOption($value)';
}

/// Описание одного параметра генерации: ключ в payload, подпись,
/// тип, допустимые варианты и значение по умолчанию.
class ParamSpec {
  final String key;
  final String label;
  final ParamType type;
  final List<ParamOption> options;

  /// Значение по умолчанию в строковом виде; для boolean используется
  /// 'true'/'false', для числовых — строковое число.
  final String defaultValue;

  /// Скрытый параметр: участвует в payload запроса, но не показывается
  /// в интерфейсе (например, фиксированная длительность у части моделей).
  final bool hidden;

  const ParamSpec({
    required this.key,
    required this.label,
    required this.type,
    this.options = const <ParamOption>[],
    this.defaultValue = '',
    this.hidden = false,
  });

  /// Значение по умолчанию, приведённое к типу параметра:
  /// boolean -> bool, intChoice -> int (если разбирается), иначе строка.
  dynamic get typedDefault => switch (type) {
        ParamType.boolean => defaultValue.trim().toLowerCase() == 'true',
        ParamType.intChoice =>
          int.tryParse(defaultValue.trim()) ?? defaultValue,
        _ => defaultValue,
      };

  /// Проверка значения на допустимость для этого параметра.
  /// Неверный тип либо вариант вне списка -> false.
  bool isValidValue(Object? value) {
    switch (type) {
      case ParamType.enumChoice:
        return value is String && options.any((o) => o.value == value);
      case ParamType.intChoice:
        String? asString;
        if (value is String) {
          asString = value;
        } else if (value is num && value == value.roundToDouble()) {
          asString = value.round().toString();
        }
        if (asString == null) return false;
        return options.any((o) => o.value == asString);
      case ParamType.boolean:
        return value is bool;
      case ParamType.referenceImage:
        return value is String && value.trim().isNotEmpty;
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'label': label,
        'type': type.name,
        'options': <Map<String, dynamic>>[
          for (final o in options) o.toJson(),
        ],
        'defaultValue': defaultValue,
        if (hidden) 'hidden': true,
      };

  factory ParamSpec.fromJson(Map<String, dynamic> j) {
    final rawOptions = j['options'];
    final options = <ParamOption>[];
    if (rawOptions is List) {
      for (final e in rawOptions) {
        if (e is Map) {
          try {
            options.add(
              ParamOption.fromJson(Map<String, dynamic>.from(e)),
            );
          } catch (_) {
            // Битый вариант пропускается.
          }
        }
      }
    }
    return ParamSpec(
      key: (j['key'] as String?) ?? '',
      label: (j['label'] as String?) ?? '',
      type: _typeFromName(j['type'] as String?),
      options: options,
      defaultValue: (j['defaultValue'] as String?) ?? '',
      hidden: j['hidden'] == true,
    );
  }

  /// Разбор имени типа с безопасным откатом на enumChoice
  /// (старые кеши и неизвестные значения не роняют разбор).
  static ParamType _typeFromName(String? raw) {
    for (final t in ParamType.values) {
      if (t.name == raw) return t;
    }
    return ParamType.enumChoice;
  }

  @override
  String toString() => 'ParamSpec($key, $type)';
}

/// Схема параметров генерации модели: стиль payload и список параметров.
class GenerationSchema {
  final PayloadStyle payloadStyle;
  final List<ParamSpec> specs;

  const GenerationSchema({
    required this.payloadStyle,
    this.specs = const <ParamSpec>[],
  });

  /// Значения по умолчанию по ключам параметров (типизированные).
  Map<String, dynamic> get defaultValues => <String, dynamic>{
        for (final s in specs) s.key: s.typedDefault,
      };

  /// Заменяет отсутствующие либо невалидные значения [current] на
  /// значения по умолчанию. Возвращает новую карту, исходная не меняется.
  Map<String, dynamic> sanitize(Map<String, dynamic> current) {
    final out = Map<String, dynamic>.of(current);
    for (final s in specs) {
      if (!s.isValidValue(out[s.key])) {
        out[s.key] = s.typedDefault;
      }
    }
    return out;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'payloadStyle': payloadStyle.name,
        'specs': <Map<String, dynamic>>[
          for (final s in specs) s.toJson(),
        ],
      };

  factory GenerationSchema.fromJson(Map<String, dynamic> j) {
    final rawSpecs = j['specs'];
    final specs = <ParamSpec>[];
    if (rawSpecs is List) {
      for (final e in rawSpecs) {
        if (e is Map) {
          try {
            specs.add(ParamSpec.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {
            // Битая спецификация пропускается.
          }
        }
      }
    }
    return GenerationSchema(
      payloadStyle: _styleFromName(j['payloadStyle'] as String?),
      specs: specs,
    );
  }

  /// Разбор имени стиля с безопасным откатом на standardFlat.
  static PayloadStyle _styleFromName(String? raw) {
    for (final s in PayloadStyle.values) {
      if (s.name == raw) return s;
    }
    return PayloadStyle.standardFlat;
  }

  @override
  String toString() =>
      'GenerationSchema(${payloadStyle.name}, specs: ${specs.length})';
}

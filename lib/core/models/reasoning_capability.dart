// Copyright (c) 2026 Minkail. All rights reserved.

/// Уровни размышлений (Reasoning Effort), поддерживаемые моделью,
/// по данным каталога провайдера (OpenRouter: reasoning.supported_efforts).
class ReasoningCapability {
  /// Поддерживаемые уровни ('max', 'high', 'low', 'none' ...).
  final List<String> supportedEfforts;

  /// Уровень по умолчанию ('medium' и т.п.); '' — не сообщён.
  final String defaultEffort;

  /// true — уровень 'none' модели запрещён (размышления обязательны).
  final bool mandatory;

  const ReasoningCapability({
    this.supportedEfforts = const <String>[],
    this.defaultEffort = 'medium',
    this.mandatory = false,
  });

  /// Разрешён ли уровень 'none' (выключенные размышления).
  bool get allowsNone => supportedEfforts.contains('none');

  /// Поддерживает ли модель размышления вообще (есть хоть один уровень).
  bool get hasEfforts => supportedEfforts.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'supportedEfforts': <String>[...supportedEfforts],
        'defaultEffort': defaultEffort,
        'mandatory': mandatory,
      };

  /// Терпимый разбор: битые элементы пропускаются, разбор не роняет код.
  factory ReasoningCapability.fromJson(Map<String, dynamic> j) {
    final raw = j['supportedEfforts'];
    final efforts = <String>[
      if (raw is List)
        for (final e in raw)
          if (e != null && e.toString().trim().isNotEmpty)
            e.toString().trim(),
    ];
    final def = j['defaultEffort'];
    return ReasoningCapability(
      supportedEfforts: efforts,
      defaultEffort: def is String ? def.trim() : 'medium',
      mandatory: j['mandatory'] == true,
    );
  }

  /// Fallback для моделей без данных в кэше: базовые уровни,
  /// 'none' разрешён (mandatory: false).
  static const ReasoningCapability standard = ReasoningCapability(
    supportedEfforts: <String>['off', 'medium', 'high'],
    defaultEffort: 'medium',
    mandatory: false,
  );

  @override
  String toString() =>
      'ReasoningCapability($supportedEfforts, def: $defaultEffort, '
      'mandatory: $mandatory)';
}

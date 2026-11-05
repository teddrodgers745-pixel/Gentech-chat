// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';
// ignore: unused_import
import 'package:flutter_svg/flutter_svg.dart';

/// Единый селектор Reasoning Effort: уровни размышлений, их подписи
/// и перевод в поля API провайдера.
///
/// Уровни образуют полный цикл из шести позиций:
/// off -> low -> medium -> high -> xhigh -> max -> off
/// (метод [ReasoningLevel.next]). Индекс enum используется как позиция
/// слайдера в интерфейсе.
enum ReasoningLevel {
  off,
  low,
  medium,
  high,
  xhigh,
  max;

  /// Следующий уровень по циклу low -> medium -> high -> xhigh -> max
  /// -> off (от off — на low).
  ReasoningLevel next() => switch (this) {
        ReasoningLevel.off => ReasoningLevel.low,
        ReasoningLevel.low => ReasoningLevel.medium,
        ReasoningLevel.medium => ReasoningLevel.high,
        ReasoningLevel.high => ReasoningLevel.xhigh,
        ReasoningLevel.xhigh => ReasoningLevel.max,
        ReasoningLevel.max => ReasoningLevel.off,
      };
}

/// Подписи, иконки и цвета уровня для интерфейса.
extension ReasoningLevelX on ReasoningLevel {
  /// Стабильный строковый идентификатор (совпадает с именем enum).
  String get id => name;

  /// Короткая подпись для капсулы «Мышление» и слайдера.
  String get label => switch (this) {
        ReasoningLevel.off => 'Off',
        ReasoningLevel.low => 'Low',
        ReasoningLevel.medium => 'Medium',
        ReasoningLevel.high => 'High',
        ReasoningLevel.xhigh => 'X-High',
        ReasoningLevel.max => 'Max',
      };

  /// Иконка уровня: у каждого уровня своя.
  IconData get icon => switch (this) {
        ReasoningLevel.off => Icons.power_settings_new,
        ReasoningLevel.low => Icons.bolt,
        ReasoningLevel.medium => Icons.balance,
        ReasoningLevel.high => Icons.local_fire_department,
        ReasoningLevel.xhigh => Icons.whatshot,
        ReasoningLevel.max => Icons.all_inclusive,
      };

  /// Виджет-иконка уровня для капсулы: размер 20 — заметнее, при этом
  /// подпись «Medium» гарантированно влезает в капсулу (minWidth 112).
  Widget get iconWidget => Icon(icon, size: 20, color: color);

  /// Цвет уровня для иконки капсулы.
  Color get color => switch (this) {
        ReasoningLevel.off => Colors.grey,
        ReasoningLevel.low => Colors.lightBlue,
        ReasoningLevel.medium => Colors.green,
        ReasoningLevel.high => Colors.deepOrange,
        ReasoningLevel.xhigh => Colors.redAccent,
        ReasoningLevel.max => Colors.indigo,
      };
}

/// Перевод уровня размышлений в payload запроса к провайдеру.
abstract final class ReasoningMapper {
  /// Уровень по строковому идентификатору; неизвестное значение — off
  /// (в том числе старые сохранённые уровни 'minimal').
  static ReasoningLevel fromId(String id) {
    final s = id.trim().toLowerCase();
    for (final l in ReasoningLevel.values) {
      if (l.name == s) return l;
    }
    return ReasoningLevel.off;
  }

  /// Известен ли идентификатор уровня (валидация сохранённых настроек).
  static bool isKnownId(String id) {
    final s = id.trim().toLowerCase();
    for (final l in ReasoningLevel.values) {
      if (l.name == s) return true;
    }
    return false;
  }

  /// Уровни из списка строк каталога модели: дубликаты убираются,
  /// порядок — от off к максимуму (порядок слайдера).
  static List<ReasoningLevel> levelsFromNames(List<String> names) {
    final out = <ReasoningLevel>[];
    for (final n in names) {
      final l = fromId(n);
      if (!out.contains(l)) out.add(l);
    }
    out.sort((a, b) => a.index.compareTo(b.index));
    return out;
  }

  /// Payload уровня размышлений для тела запроса /chat/completions:
  ///  - [ReasoningLevel.off] — пустая карта (поле не отправляется);
  ///  - идентификатор с префиксом владельца ('vendor/model', формат
  ///    каталогов-агрегаторов) — поле reasoning: {effort: ...};
  ///  - остальные (прямые OpenAI-совместимые провайдеры) —
  ///    reasoning_effort: '...'.
  static Map<String, dynamic> mapToApi(
    ReasoningLevel level,
    String modelId,
  ) {
    if (level == ReasoningLevel.off) return const <String, dynamic>{};
    final id = modelId.trim().toLowerCase();
    if (id.contains('/')) {
      return <String, dynamic>{
        'reasoning': <String, dynamic>{'effort': level.name},
      };
    }
    return <String, dynamic>{'reasoning_effort': level.name};
  }
}

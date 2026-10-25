// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/foundation.dart';

/// Одна запись в списке моделей, введённых пользователем.
/// Содержит только нейтральные данные: идентификатор модели,
/// необязательное понятное имя, размер контекста и настройки.
@immutable
class ModelEntry {
  const ModelEntry({
    required this.id,
    this.displayName,
    this.contextLength,
    this.supportsStreaming = true,
    this.isFavorite = false,
  });

  /// Полный идентификатор модели, как его вернул endpoint
  /// (например "vendor/model-name"). Вводится/загружается пользователем.
  final String id;

  /// Понятное отображаемое имя; если не задано — вычисляется из [id].
  final String? displayName;

  /// Заявленный размер контекстного окна в токенах, если известен.
  final int? contextLength;

  /// Поддерживает ли модель потоковую генерацию (SSE).
  final bool supportsStreaming;

  /// Отмечена ли модель пользователем как избранная.
  final bool isFavorite;

  /// Короткое имя без префикса владельца: "vendor/name" -> "name".
  /// Если префикса нет, возвращается [id] целиком.
  String get label {
    final custom = displayName;
    if (custom != null && custom.trim().isNotEmpty) {
      return custom.trim();
    }
    final idx = id.lastIndexOf('/');
    if (idx >= 0 && idx < id.length - 1) {
      return id.substring(idx + 1);
    }
    return id;
  }

  /// Подпись под названием: контекст и режим стриминга.
  String get subtitle {
    final parts = <String>[];
    final ctx = contextLength;
    if (ctx != null && ctx > 0) {
      parts.add('контекст: ${_formatTokens(ctx)}');
    }
    parts.add(supportsStreaming ? 'стриминг' : 'без стриминга');
    return parts.join(' · ');
  }

  static String _formatTokens(int count) {
    if (count >= 1000000) {
      final m = count / 1000000;
      return m == m.roundToDouble()
          ? '${m.round()}M'
          : '${m.toStringAsFixed(1)}M';
    }
    if (count >= 1000) {
      final k = count / 1000;
      return k == k.roundToDouble()
          ? '${k.round()}K'
          : '${k.toStringAsFixed(1)}K';
    }
    return '$count';
  }

  /// Копия с изменёнными полями. Поля со значением-маркером sentinel
  /// остаются прежними (позволяет обнулять nullable-поля через null).
  ModelEntry copyWith({
    String? id,
    String? displayName,
    int? contextLength,
    bool? supportsStreaming,
    bool? isFavorite,
  }) {
    return ModelEntry(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      contextLength: contextLength ?? this.contextLength,
      supportsStreaming: supportsStreaming ?? this.supportsStreaming,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  /// Терпимый к данным парсер: id может лежать в "id", "name" или "model".
  factory ModelEntry.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'] ?? json['name'] ?? json['model'];
    final id = rawId is String ? rawId.trim() : '';
    if (id.isEmpty) {
      throw const FormatException('ModelEntry: пустой идентификатор');
    }

    int? contextLength;
    final rawCtx = json['contextLength'] ?? json['context_length'];
    if (rawCtx is int) {
      contextLength = rawCtx;
    } else if (rawCtx is num) {
      contextLength = rawCtx.toInt();
    } else if (rawCtx is String) {
      contextLength = int.tryParse(rawCtx.trim());
    }

    final rawName = json['displayName'] ?? json['display_name'];
    final display = rawName is String && rawName.trim().isNotEmpty
        ? rawName.trim()
        : null;

    final rawStream = json['supportsStreaming'];
    final supportsStreaming = rawStream is bool ? rawStream : true;

    final rawFav = json['isFavorite'];
    final isFavorite = rawFav is bool ? rawFav : false;

    return ModelEntry(
      id: id,
      displayName: display,
      contextLength: contextLength,
      supportsStreaming: supportsStreaming,
      isFavorite: isFavorite,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      if (displayName != null) 'displayName': displayName,
      if (contextLength != null) 'contextLength': contextLength,
      'supportsStreaming': supportsStreaming,
      'isFavorite': isFavorite,
    };
  }

  /// Безопасный разбор списка моделей: битые элементы пропускаются,
  /// дубликаты по id отбрасываются, порядок сохраняется.
  static List<ModelEntry> listFromJson(List<dynamic>? raw) {
    if (raw == null) return const <ModelEntry>[];
    final result = <ModelEntry>[];
    final seen = <String>{};
    for (final item in raw) {
      ModelEntry entry;
      if (item is ModelEntry) {
        entry = item;
      } else if (item is Map) {
        try {
          entry = ModelEntry.fromJson(item.cast<String, dynamic>());
        } on FormatException {
          continue;
        }
      } else if (item is String && item.trim().isNotEmpty) {
        entry = ModelEntry(id: item.trim());
      } else {
        continue;
      }
      if (entry.id.isEmpty || !seen.add(entry.id)) continue;
      result.add(entry);
    }
    return result;
  }

  static List<Map<String, dynamic>> listToJson(List<ModelEntry> models) {
    return models.map((m) => m.toJson()).toList(growable: false);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ModelEntry &&
        other.id == id &&
        other.displayName == displayName &&
        other.contextLength == contextLength &&
        other.supportsStreaming == supportsStreaming &&
        other.isFavorite == isFavorite;
  }

  @override
  int get hashCode =>
      Object.hash(id, displayName, contextLength, supportsStreaming, isFavorite);

  @override
  String toString() => 'ModelEntry($id)';
}

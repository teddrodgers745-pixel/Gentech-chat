// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Плавный вывод текста модели («эффект печатной машинки»).
///
/// Куски стрима добавляются в буфер через [add]; Ticker (~60 кадров
/// в секунду) каждый кадр вызывает [tick], который выдаёт очередную
/// порцию (2–3 символа; при большом backlog — больше, чтобы анимация
/// догоняла поток). Полный показанный текст доступен интерфейсу через
/// [displayed] — ValueNotifier<String>, на который подписывается UI.
/// При завершении потока [flush] возвращает остаток буфера целиком.
class StreamPacer {
  /// Буфер ещё не показанных символов.
  final StringBuffer _buffer = StringBuffer();

  /// Полный текст, уже показанный пользователю.
  final StringBuffer _shown = StringBuffer();

  /// Полный показанный текст: UI подписывается на этот нотификатор.
  final ValueNotifier<String> displayed = ValueNotifier<String>('');

  /// Колбэк очередной порции (вызывается из tick, когда порция выдана).
  void Function(String portion)? onTick;

  Ticker? _ticker;
  Timer? _fallbackTimer;

  /// Сколько символов ждёт показа.
  int get pendingLength => _buffer.length;

  /// Есть ли непоказанный текст.
  bool get hasPending => _buffer.isNotEmpty;

  /// Полный показанный к текущему моменту текст.
  String get shown => _shown.toString();

  /// Добавляет чанк потока в буфер.
  void add(String chunk) {
    if (chunk.isNotEmpty) _buffer.write(chunk);
  }

  /// Выдаёт очередную порцию для отображения; null — буфер пуст.
  ///
  /// Базовая порция — 3 символа на кадр (60 fps ≈ 180 символов/с);
  /// при backlog больше ~90 символов порция растёт пропорционально,
  /// чтобы показ догонял поток и хвост не тянулся десятками секунд.
  String? tick() {
    final n = _buffer.length;
    if (n == 0) return null;
    var take = n ~/ 90;
    if (take < 3) take = 3;
    if (take > n) take = n;
    final all = _buffer.toString();
    final portion = all.substring(0, take);
    _buffer.clear();
    if (take < n) _buffer.write(all.substring(take));
    _shown.write(portion);
    displayed.value = _shown.toString();
    return portion;
  }

  /// Возвращает остаток буфера целиком (вызывается при завершении потока).
  String flush() {
    final rest = _buffer.toString();
    if (rest.isEmpty) return '';
    _buffer.clear();
    _shown.write(rest);
    displayed.value = _shown.toString();
    return rest;
  }

  /// Запускает Ticker (60 fps): каждый кадр вызывает [tick]. Если Ticker
  /// недоступен (binding ещё не создан, тесты) — резервный Timer.periodic
  /// с тем же интервалом ~16 мс.
  void start() {
    if (_ticker != null || _fallbackTimer != null) return;
    try {
      final t = Ticker(_onFrame);
      t.start();
      _ticker = t;
    } catch (_) {
      _fallbackTimer = Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _onFrame(Duration.zero),
      );
    }
  }

  void _onFrame(Duration elapsed) {
    final portion = tick();
    if (portion != null && portion.isNotEmpty) onTick?.call(portion);
  }

  /// Останавливает Ticker. [displayed] не освобождается: на него может
  /// быть подписан интерфейс, и он переживёт пейсер как обычный нотификатор.
  void stop() {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
  }
}

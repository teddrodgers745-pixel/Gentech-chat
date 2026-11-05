// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/attachment_draft.dart';
import '../theme.dart';

/// Горизонтальная лента превью вложений над полем ввода.
///
/// Статусы вложений ([AttachmentStatus]):
///  - picking/processing — затемняющая плёнка и CircularProgressIndicator
///    поверх миниатюры;
///  - ready — зелёная галочка в углу, показывается 1 секунду;
///  - tooLarge/failed — красная обводка карточки.
/// Кнопка удаления доступна на любой карточке (вложение можно снять
/// и во время обработки: цикл обработки это корректно переживает).
class AttachmentStrip extends StatefulWidget {
  final List<AttachmentDraft> attachments;

  /// Удаление вложения по индексу.
  final void Function(int index) onRemove;

  const AttachmentStrip({
    super.key,
    required this.attachments,
    required this.onRemove,
  });

  @override
  State<AttachmentStrip> createState() => _AttachmentStripState();
}

class _AttachmentStripState extends State<AttachmentStrip> {
  static const Duration _checkDuration = Duration(seconds: 1);
  static const Color _red = Color(0xFFB3261E);
  static const Color _green = Color(0xFF2E7D32);

  static const Set<String> _imageExt = <String>{
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic', 'heif',
  };

  /// Момент, когда вложение впервые стало ready (для зелёной галочки).
  final Map<AttachmentDraft, DateTime> _readyAt =
      <AttachmentDraft, DateTime>{};
  Timer? _checkTimer;

  @override
  void dispose() {
    _checkTimer?.cancel();
    super.dispose();
  }

  /// Синхронизирует отметки времени готовности: убирает записи удалённых
  /// вложений, ставит отметки новым ready и планирует перерисовку, когда
  /// галочка должна исчезнуть (через 1 секунду после готовности).
  void _syncReadyMarks() {
    final now = DateTime.now();
    _readyAt.removeWhere(
      (draft, _) => !widget.attachments.contains(draft),
    );
    var visible = false;
    var soonest = now.add(_checkDuration);
    for (final a in widget.attachments) {
      if (a.status != AttachmentStatus.ready) continue;
      final t = _readyAt.putIfAbsent(a, () => now);
      final end = t.add(_checkDuration);
      if (end.isAfter(now)) {
        visible = true;
        if (end.isBefore(soonest)) soonest = end;
      }
    }
    if (visible) {
      _checkTimer?.cancel();
      _checkTimer = Timer(soonest.difference(now), () {
        if (mounted) setState(() {});
      });
    } else if (_checkTimer != null) {
      _checkTimer?.cancel();
      _checkTimer = null;
    }
  }

  bool _isImage(AttachmentDraft a) =>
      _imageExt.contains(attachmentExtension(a.file.path));

  @override
  Widget build(BuildContext context) {
    if (widget.attachments.isEmpty) return const SizedBox.shrink();
    final p = settings.palette;
    _syncReadyMarks();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: SizedBox(
        height: 76,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: widget.attachments.length,
          itemBuilder: (context, i) => _tile(widget.attachments[i], i, p),
        ),
      ),
    );
  }

  Widget _tile(AttachmentDraft a, int index, Palette p) {
    final failed = a.status == AttachmentStatus.failed ||
        a.status == AttachmentStatus.tooLarge;
    final busy = a.isBusy;
    final ready = a.status == AttachmentStatus.ready;
    final marked = _readyAt[a];
    final showCheck = ready &&
        marked != null &&
        marked.add(_checkDuration).isAfter(DateTime.now());
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: SizedBox(
        width: 68,
        height: 68,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                decoration: BoxDecoration(
                  color: p.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: failed ? _red : p.border,
                    width: failed ? 2 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: _thumb(a, p),
              ),
            ),
            if (busy)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x73000000),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            if (showCheck) _badge(Icons.check_rounded, _green),
            _deleteButton(index, failed, p),
          ],
        ),
      ),
    );
  }

  /// Круглый бейдж в левом верхнем углу (зелёная галочка готовности).
  Widget _badge(IconData icon, Color color) {
    return Positioned(
      left: -4,
      top: -4,
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
        ),
        child: Icon(icon, size: 14, color: Colors.white),
      ),
    );
  }

  /// Кнопка удаления вложения в правом верхнем углу. У карточек
  /// tooLarge/failed — красная, у остальных — в тёплой гамме темы.
  Widget _deleteButton(int index, bool failed, Palette p) {
    return Positioned(
      right: -4,
      top: -4,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => widget.onRemove(index),
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: failed ? _red : p.card,
              border: Border.all(color: failed ? _red : p.border),
            ),
            child: Icon(
              Icons.close_rounded,
              size: 14,
              color: failed ? Colors.white : p.muted,
            ),
          ),
        ),
      ),
    );
  }

  /// Миниатюра вложения: картинка — уменьшенный Image.file,
  /// прочие файлы — нейтральная иконка документа.
  Widget _thumb(AttachmentDraft a, Palette p) {
    if (_isImage(a)) {
      return Image.file(
        a.file,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: 136,
        errorBuilder: (_, __, ___) => _fileIcon(p),
      );
    }
    return _fileIcon(p);
  }

  Widget _fileIcon(Palette p) {
    return Center(
      child: Icon(
        Icons.insert_drive_file_outlined,
        size: 26,
        color: p.muted,
      ),
    );
  }
}

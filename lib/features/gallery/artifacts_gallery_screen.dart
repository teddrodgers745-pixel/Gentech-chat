// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/generation/artifact_repository.dart';
import '../../core/models/artifact.dart';
import '../../theme.dart';
import '../../widgets/theme_toggle_action.dart';
import 'artifact_viewer.dart';

/// Фильтр галереи.
enum _GalleryFilter { all, image, video }

/// Галерея артефактов: сетка превью всех сгенерированных изображений
/// и видео из JSON-индекса [ArtifactRepository], панель фильтров
/// (Все / Изображения / Видео) и модальный просмотр.
class ArtifactsGalleryScreen extends StatefulWidget {
  const ArtifactsGalleryScreen({super.key});

  @override
  State<ArtifactsGalleryScreen> createState() =>
      _ArtifactsGalleryScreenState();
}

class _ArtifactsGalleryScreenState extends State<ArtifactsGalleryScreen> {
  _GalleryFilter _filter = _GalleryFilter.all;

  @override
  void initState() {
    super.initState();
    // Индекс догружается один раз; register() сам догружает при записи.
    ArtifactRepository.instance.load();
  }

  List<Artifact> _items() {
    final repo = ArtifactRepository.instance;
    switch (_filter) {
      case _GalleryFilter.all:
        return repo.items;
      case _GalleryFilter.image:
        return repo.byKind(Artifact.kindImage);
      case _GalleryFilter.video:
        return repo.byKind(Artifact.kindVideo);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ArtifactRepository.instance,
      builder: (context, _) {
        final p = settings.palette;
        final items = _items();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Галерея'),
            actions: const [ThemeToggleAction()],
          ),
          body: SafeArea(
            child: Column(
              children: [
                _filters(p),
                Expanded(child: _body(items, p)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _filters(Palette p) {
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          _chip(
            'Все',
            _filter == _GalleryFilter.all,
            p,
            () => setState(() => _filter = _GalleryFilter.all),
          ),
          _chip(
            'Изображения',
            _filter == _GalleryFilter.image,
            p,
            () => setState(() => _filter = _GalleryFilter.image),
          ),
          _chip(
            'Видео',
            _filter == _GalleryFilter.video,
            p,
            () => setState(() => _filter = _GalleryFilter.video),
          ),
        ],
      ),
    );
  }

  /// Чип фильтра в общем стиле приложения (как пропорции у генерации).
  Widget _chip(String label, bool selected, Palette p, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? p.accent.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? p.accent : p.border,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Icon(Icons.check_rounded, size: 15, color: p.accent),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? p.accent : p.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(List<Artifact> items, Palette p) {
    final repo = ArtifactRepository.instance;
    if (!repo.isLoaded) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (items.isEmpty) return _empty(p);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final a = items[i];
        return _ArtifactCell(
          key: ValueKey(a.id),
          artifact: a,
          p: p,
          onTap: () => _openViewer(a),
        );
      },
    );
  }

  void _openViewer(Artifact a) {
    showDialog<void>(
      context: context,
      builder: (_) => ArtifactViewer(artifact: a),
    );
  }

  Widget _empty(Palette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined, size: 36, color: p.accent),
            const SizedBox(height: 16),
            Text(
              'Пока пусто',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Сгенерированные изображения и видео появятся здесь автоматически.',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ячейка сетки: превью артефакта в тёплой карточке с рамкой.
class _ArtifactCell extends StatelessWidget {
  final Artifact artifact;
  final Palette p;
  final VoidCallback onTap;

  const _ArtifactCell({
    super.key,
    required this.artifact,
    required this.p,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: artifactMedia(artifact, p),
      ),
    );
  }
}

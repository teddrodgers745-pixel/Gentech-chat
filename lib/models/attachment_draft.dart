// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Статус вложения на пути от выбора файла до отправки в чат.
enum AttachmentStatus {
  /// Файл выбран, обработка ещё не началась.
  picking,

  /// Файл обрабатывается: чтение и сжатие изображения в изоляте.
  processing,

  /// Готов к отправке.
  ready,

  /// Файл слишком большой даже после сжатия.
  tooLarge,

  /// Обработка не удалась (ошибка чтения/записи).
  failed,
}

/// Черновик вложения: файл, выбранный пользователем, и состояние его
/// обработки. Пока статус «занят» ([isBusy]), вложение показывается в чате
/// с индикатором; после обработки (сжатие изображения в изоляте) статус
/// становится ready, tooLarge либо failed. Для сжатых изображений [file]
/// заменяется на временный файл сжатой копии — исходный не изменяется.
class AttachmentDraft {
  /// Файл вложения (после сжатия — сжатая копия во временном каталоге).
  final File file;

  AttachmentStatus status;

  /// Прогресс обработки 0..1.
  double progress;

  /// Понятное описание проблемы для failed/tooLarge; null — ошибки нет.
  String? error;

  AttachmentDraft({
    required this.file,
    this.status = AttachmentStatus.picking,
    this.progress = 0,
    this.error,
  });

  bool get isReady => status == AttachmentStatus.ready;

  bool get isBusy =>
      status == AttachmentStatus.picking ||
      status == AttachmentStatus.processing;
}

/// Предел размера вложения (совпадает с лимитом чтения в ChatService).
const int kAttachmentMaxBytes = 8 * 1024 * 1024;

/// Порог, начиная с которого изображение сжимается.
const int _compressThresholdBytes = 1 * 1024 * 1024;

const Set<String> _imageExtensions = <String>{
  'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic', 'heif',
};

/// G2-media-references: типы файлов, допустимые в качестве референсов
/// медиа-модели (input.images POST /v1/media).
const Set<String> kMediaReferenceExtensions = <String>{
  'jpg', 'jpeg', 'png', 'webp',
};

/// Расширение файла в нижнем регистре ('' — расширения нет).
String attachmentExtension(String path) {
  final clean = path.replaceAll('\\', '/');
  final dot = clean.lastIndexOf('.');
  final slash = clean.lastIndexOf('/');
  if (dot < 0 || dot < slash) return '';
  return clean.substring(dot + 1).toLowerCase();
}

/// Имя файла без пути.
String attachmentName(String path) {
  final clean = path.replaceAll('\\', '/');
  final slash = clean.lastIndexOf('/');
  return slash >= 0 && slash + 1 < clean.length
      ? clean.substring(slash + 1)
      : clean;
}

/// G2-media-references: результат отбора референсных изображений
/// медиа-модели из выбранных пользователем файлов.
///
/// Правила — только из каталога Polza Media API:
///  - типы: только jpg/jpeg/png/webp ([kMediaReferenceExtensions]);
///  - лимит: не более [maxReferenceImages] референсов на запрос,
///    уже прикреплённые учитываются в [MediaReferenceSelection].
class MediaReferenceSelection {
  /// Отобранные пути (в исходном порядке, не более свободного лимита).
  final List<String> accepted;

  /// Сколько файлов отброшено по типу (не изображение-референс).
  final int rejectedWrongType;

  /// Сколько допустимых по типу файлов не влезло в лимит.
  final int rejectedOverLimit;

  /// true — лимит исчерпан ещё ДО отбора (свободного места нет):
  /// ничего добавить нельзя, UI показывает сообщение о лимите.
  final bool limitAlreadyReached;

  const MediaReferenceSelection({
    required this.accepted,
    this.rejectedWrongType = 0,
    this.rejectedOverLimit = 0,
    this.limitAlreadyReached = false,
  });
}

/// Отбирает референсы медиа-модели из [paths]:
///  - фильтрует по типу (jpg/jpeg/png/webp);
///  - не пускает больше (maxReferenceImages - currentCount) файлов;
///  - при maxReferenceImages <= 0 или исчерпанном лимите ничего
///    не добавляет ([MediaReferenceSelection.limitAlreadyReached]).
MediaReferenceSelection selectMediaReferenceFiles({
  required List<String> paths,
  int currentCount = 0,
  int? maxReferenceImages,
}) {
  final byType = <String>[
    for (final p in paths)
      if (kMediaReferenceExtensions.contains(attachmentExtension(p))) p,
  ];
  final wrong = paths.length - byType.length;
  final max = maxReferenceImages ?? 0;
  final room = max - currentCount;
  if (max <= 0 || room <= 0) {
    return MediaReferenceSelection(
      accepted: const <String>[],
      rejectedWrongType: wrong,
      rejectedOverLimit: byType.length,
      limitAlreadyReached: true,
    );
  }
  final take = byType.length < room ? byType.length : room;
  return MediaReferenceSelection(
    accepted: List<String>.of(byType.take(take)),
    rejectedWrongType: wrong,
    rejectedOverLimit: byType.length - take,
    limitAlreadyReached: false,
  );
}

/// G2-media-references: MIME-тип референсного изображения по расширению;
/// '' — файл не является референсом (поддерживаются только форматы
/// input.images Polza Media API: jpeg/png/webp).
String mediaReferenceMime(String path) {
  switch (attachmentExtension(path)) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    default:
      return '';
  }
}

/// Кодирует файл референса в data-URI `data:<mime>;base64,<...>` —
/// формат входных изображений POST /v1/media (input.images). null —
/// файл не изображение поддерживаемого типа либо не читается.
Future<String?> mediaReferenceDataUri(File file) async {
  final mime = mediaReferenceMime(file.path);
  if (mime.isEmpty) return null;
  try {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return 'data:$mime;base64,${base64Encode(bytes)}';
  } catch (_) {
    return null;
  }
}

/// Обрабатывает вложение: изображения (jpg/jpeg/png/webp) сжимаются
/// в изоляте ([Isolate.run]) — понижение разрешения до 2048 по длинной
/// стороне и перекодирование с подбором качества; GIF/HEIC и прочие
/// файлы только проверяются на размер. Возвращает НОВЫЙ [AttachmentDraft]
/// со статусом ready/tooLarge/failed. Исходный файл не изменяется.
Future<AttachmentDraft> processAttachment(AttachmentDraft draft) async {
  final file = draft.file;
  try {
    final ext = attachmentExtension(file.path);
    final len = await file.length();

    if (!_imageExtensions.contains(ext)) {
      if (len > kAttachmentMaxBytes) {
        return _result(draft, AttachmentStatus.tooLarge, 'Файл больше 8 МБ');
      }
      return _result(draft, AttachmentStatus.ready);
    }

    // GIF (анимация) и HEIC/HEIF не перекодируем: только проверка размера.
    if (ext == 'gif' || ext == 'heic' || ext == 'heif') {
      if (len > kAttachmentMaxBytes) {
        return _result(
          draft,
          AttachmentStatus.tooLarge,
          'Изображение больше 8 МБ',
        );
      }
      return _result(draft, AttachmentStatus.ready);
    }

    if (len <= _compressThresholdBytes) {
      return _result(draft, AttachmentStatus.ready);
    }

    final bytes = await file.readAsBytes();
    final List<int>? compressed =
        await Isolate.run<List<int>?>(() => _compressBytes(bytes, ext));
    if (compressed == null) {
      // Декодировать не удалось: отправляем оригинал, если он допустим.
      if (len > kAttachmentMaxBytes) {
        return _result(
          draft,
          AttachmentStatus.tooLarge,
          'Изображение не удалось сжать (больше 8 МБ)',
        );
      }
      return _result(draft, AttachmentStatus.ready);
    }
    final out = await _writeTemp(compressed, attachmentName(file.path), ext);
    return _result(draft, AttachmentStatus.ready, null, out);
  } catch (_) {
    return _result(
      draft,
      AttachmentStatus.failed,
      'Не удалось обработать файл',
    );
  }
}

AttachmentDraft _result(
  AttachmentDraft src,
  AttachmentStatus status, [
  String? error,
  File? file,
]) =>
    AttachmentDraft(
      file: file ?? src.file,
      status: status,
      progress: 1,
      error: error,
    );

/// Записывает сжатую копию во временный файл, сохраняя исходное имя
/// (с суффиксом и меткой времени против коллизий).
Future<File> _writeTemp(List<int> bytes, String name, String ext) async {
  final dir = await getTemporaryDirectory();
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final safe = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final outExt = ext == 'png' ? 'png' : 'jpg';
  final file = File(
    '${dir.path}/${safe}_g${DateTime.now().millisecondsSinceEpoch}.$outExt',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

/// Сжатие изображения (выполняется в изоляте через Isolate.run):
/// длинная сторона не более 2048, JPEG с подбором качества до лимита;
/// PNG перекодируется в PNG (с сохранением прозрачности), при слишком
/// большом результате — в JPEG. null — декодировать не удалось.
List<int>? _compressBytes(Uint8List bytes, String ext) {
  img.Image? image;
  try {
    image = img.decodeImage(bytes);
  } catch (_) {
    image = null;
  }
  if (image == null) return null;

  const maxSide = 2048;
  final w = image.width;
  final h = image.height;
  final longSide = w > h ? w : h;
  if (longSide > maxSide) {
    final scale = maxSide / longSide;
    image = img.copyResize(
      image,
      width: (w * scale).round(),
      height: (h * scale).round(),
      interpolation: img.Interpolation.average,
    );
  }

  if (ext == 'png') {
    final out = img.encodePng(image);
    if (out.lengthInBytes <= kAttachmentMaxBytes) return out;
  }
  var quality = 85;
  var out = img.encodeJpg(image, quality: quality);
  while (out.lengthInBytes > kAttachmentMaxBytes && quality > 40) {
    quality -= 15;
    out = img.encodeJpg(image, quality: quality);
  }
  return out;
}

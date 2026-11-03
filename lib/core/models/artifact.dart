// Copyright (c) 2026 Minkail. All rights reserved.

/// Результат генерации, сохранённый как отдельный артефакт:
/// изображение или видео, полученное от модели (либо ещё только
/// запрошенное). Ссылается на локальный файл и/или удалённый URL.
/// Пока никем не подключён — фундамент для следующих этапов.
class Artifact {
  /// Виды артефактов.
  static const String kindImage = 'image';
  static const String kindVideo = 'video';

  /// Уникальный идентификатор артефакта.
  final String id;

  /// Вид артефакта: 'image' либо 'video' ([kindImage] / [kindVideo]).
  final String kind;

  /// Путь к файлу на устройстве; '' — файл ещё не сохранён.
  final String localPath;

  /// Ссылка на ресурс у провайдера; '' — ссылки нет.
  final String remoteUrl;

  /// Промпт, по которому артефакт был сгенерирован.
  final String prompt;

  /// Идентификатор модели, создавшей артефакт.
  final String modelId;

  const Artifact({
    required this.id,
    this.kind = kindImage,
    this.localPath = '',
    this.remoteUrl = '',
    this.prompt = '',
    this.modelId = '',
  });

  /// Есть ли локальная копия файла.
  bool get hasLocalFile => localPath.trim().isNotEmpty;

  /// Есть ли удалённая ссылка.
  bool get hasRemoteUrl => remoteUrl.trim().isNotEmpty;

  /// Чем можно открыть артефакт прямо сейчас.
  bool get isViewable => hasLocalFile || hasRemoteUrl;

  /// Человекочитаемая подпись вида артефакта.
  String get kindLabel => kind == kindVideo ? 'видео' : 'изображение';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind,
        'localPath': localPath,
        'remoteUrl': remoteUrl,
        'prompt': prompt,
        'modelId': modelId,
      };

  factory Artifact.fromJson(Map<String, dynamic> j) => Artifact(
        id: (j['id'] as String?) ?? '',
        kind: (j['kind'] as String?) == kindVideo ? kindVideo : kindImage,
        localPath: (j['localPath'] as String?) ?? '',
        remoteUrl: (j['remoteUrl'] as String?) ?? '',
        prompt: (j['prompt'] as String?) ?? '',
        modelId: (j['modelId'] as String?) ?? '',
      );

  /// Копия с заменой отдельных полей.
  Artifact copyWith({
    String? kind,
    String? localPath,
    String? remoteUrl,
    String? prompt,
    String? modelId,
  }) {
    return Artifact(
      id: id,
      kind: kind ?? this.kind,
      localPath: localPath ?? this.localPath,
      remoteUrl: remoteUrl ?? this.remoteUrl,
      prompt: prompt ?? this.prompt,
      modelId: modelId ?? this.modelId,
    );
  }

  @override
  bool operator ==(Object other) => identical(this, other) ||
      (other is Artifact && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Artifact($id, $kind)';
}

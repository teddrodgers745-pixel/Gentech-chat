// Copyright (c) 2026 Minkail. All rights reserved.
//
// F5-gallery-image-load: галерея наполняется сгенерированным медиа
// из истории чатов (выбранное решение — источник правды ChatStore).
//
// F5-T-GALLERY-IMAGE-AND-VIDEO: ImagePart (локальный), markdown-ссылка
// на file:// (как отдаёт ImagesApiExecutor) и VideoPart попадают в
// галерею; текст, источники и PendingPart медиа не считаются,
// пользовательские сообщения не сканируются.
// F5-T-GALLERY-DEDUP: один и тот же URL в галерее единожды.
// F5-T-GALLERY-NEWEST-FIRST: медиа свежего чата выше.

import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/app_state.dart';
import 'package:gentech_chat/core/models/message_part.dart';
import 'package:gentech_chat/features/gallery/generated_media_collector.dart';
import 'package:gentech_chat/models/chat_message.dart';

void main() {
  tearDown(() {
    // Не оставляем тестовые чаты в глобальном хранилище.
    store.chats.clear();
    store.current = null;
  });

  test(
    'F5-T-GALLERY-IMAGE-AND-VIDEO: картинки и видео из чатов '
    'попадают в галерею',
    () {
      final chat = store.createChat();
      chat.title = 'Медиа';
      chat.messages.add(ChatMessage(
        id: 'm1',
        role: 'assistant',
        parts: <MessagePart>[
          const ImagePart.fromPath('/storage/emulated/0/GenTech/img_a.png'),
        ],
      ));
      // Markdown-ссылка на материализованный файл — путь ImagesApiExecutor.
      chat.messages.add(ChatMessage(
        id: 'm2',
        role: 'assistant',
        content: '![изображение](file:///data/user/0/app/files/img_b.png)',
      ));
      chat.messages.add(ChatMessage(
        id: 'm3',
        role: 'assistant',
        parts: <MessagePart>[
          const VideoPart.fromUrl('https://cdn.example.com/v.mp4'),
        ],
      ));
      // НЕ медиа: текст, источники, ожидающая задача, сообщение пользователя.
      chat.messages.add(ChatMessage(
        id: 'm4',
        role: 'assistant',
        content: 'Обычный текст',
        parts: <MessagePart>[
          const TextPart('', sources: <String>['https://example.com']),
          const PendingPart(name: 'Генерация видео', jobId: 'job-1'),
        ],
      ));
      chat.messages.add(ChatMessage(
        id: 'm5',
        role: 'user',
        content: '![подделка](https://evil.example.com/x.png)',
      ));

      final items = GeneratedMediaCollector.collect(store.chats);

      expect(items, hasLength(3));
      // Свежие сообщения — первыми (m3 -> m2 -> m1).
      expect(items[0].isVideo, isTrue);
      expect(items[0].path, 'https://cdn.example.com/v.mp4');
      expect(items[0].isLocal, isFalse);
      expect(items[1].isVideo, isFalse);
      expect(items[1].path, '/data/user/0/app/files/img_b.png');
      expect(items[1].isLocal, isTrue);
      expect(items[2].path, '/storage/emulated/0/GenTech/img_a.png');
      expect(items[2].isLocal, isTrue);
    },
  );

  test(
    'F5-T-GALLERY-DEDUP: один и тот же URL не дублируется в галерее',
    () {
      final chat = store.createChat();
      chat.messages.add(ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: '![x](https://cdn.example.com/i.png)',
      ));
      chat.messages.add(ChatMessage(
        id: 'a2',
        role: 'assistant',
        parts: <MessagePart>[
          const ImagePart.fromUrl('https://cdn.example.com/i.png'),
        ],
      ));
      chat.messages.add(ChatMessage(
        id: 'a3',
        role: 'assistant',
        content: '![x](https://cdn.example.com/i.png)',
      ));

      final items = GeneratedMediaCollector.collect(store.chats);

      expect(items, hasLength(1));
      expect(items.single.path, 'https://cdn.example.com/i.png');
    },
  );

  test(
    'F5-T-GALLERY-NEWEST-FIRST: медиа свежего чата выше старого',
    () {
      final older = store.createChat();
      older.updatedAt = DateTime.now().subtract(const Duration(hours: 2));
      older.messages.add(ChatMessage(
        id: 'o1',
        role: 'assistant',
        parts: <MessagePart>[
          const ImagePart.fromUrl('https://cdn.example.com/old.png'),
        ],
      ));
      final newer = store.createChat();
      newer.updatedAt = DateTime.now();
      newer.messages.add(ChatMessage(
        id: 'n1',
        role: 'assistant',
        parts: <MessagePart>[
          const ImagePart.fromUrl('https://cdn.example.com/new.png'),
        ],
      ));

      final items = GeneratedMediaCollector.collect(store.chats);

      expect(items.first.path, 'https://cdn.example.com/new.png');
      expect(items.last.path, 'https://cdn.example.com/old.png');
    },
  );
}

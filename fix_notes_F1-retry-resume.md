# fix_notes_F1-retry-resume (heal1)

## Что было не так (шаг 9 Analyze Code, exit 1 — 6 ошибок + 1 info)

1. **lib/core/models/gen_error.dart:54 и :90 — `non_abstract_class_inherits_abstract_member`.**
   Sealed-класс `GenError` объявил абстрактный геттер `code`, но два конкретных подтипа
   его не реализовали: `RateLimited` и `ServerError` (коммит F1 обновил иерархию,
   но не все листья — ровно тот случай «обновляй ВСЕХ потребителей нового поля»).
   Ошибка сборки — НЕ «429 от Maven» и не инфраструктура: чисто код.

2. **lib/screens/chat_screen.dart:1583 — 4 ошибки на одной строке.**
   По колонкам лога (аргумент на :16, «Expected to find '>'» на :36, map-entries на :38 и :54)
   это финальный `msgs.add(...)` в `_buildHistoryMessages`: литерал карты повреждён —
   перед `{` стоит `<Map<String, dynamic>` (тип-аргументов недостаточно / лишние/недостающие `>`).
   Один тип-аргумент перед `{` в Dart = SET-литерал, поэтому анализатор видит
   `Set<Map<String, dynamic>>`, который не присваивается параметру `add` (`Map<String, dynamic>`),
   а записи `'role': ...`/`'content': ...` — «Map entries can only be used in a map literal».

## Что поправил

- `gen_error.dart`: добавил `@override String get code => 'rate_limit';` в `RateLimited`
  (код прямо назван в doc-комментарии sealed-класса) и `=> 'server';` в `ServerError`.
  Теперь все 11 подтипов `GenError` реализуют `code` — sealed-иерархия полна.
- `chat_screen.dart`: вернул строку в `_buildHistoryMessages` к корректной форме
  `msgs.add(<String, dynamic>{'role': m.role, 'content': m.content});` и добавил
  туда превентивный комментарий. Возвращён полный файл — гарантия, что в репо
  окажется валидная версия строки (в присланном тексте строка уже выглядела верно —
  судя по логу CI, в репо на коммите F1 она была повреждена; расхождение прошу проверить).

## Info (не блокирует сборку, НЕ трогал по правилам проекта)

- `message_view.dart:8` — `unnecessary_import` для `flutter/painting.dart`
  (импортирован для `PaintingBinding` в `_RetryableNetworkImage`; всё даёт `material.dart`).
  По правилу проекта импорты не удаляются; `flutter analyze` по умолчанию считает
  info НЕ фатальным, шаг пройдёт.

## Что стоит улучшить рядом

- `GenErrorMapper.fromCode` (файл не присылали!) должен знать коды `'rate_limit'` и
  `'server'` для исчерпывающего маппинга в UI; если там другие строки — сверить.
- Защитный тест: «каждый подтип `GenError` даёт уникальный непустой `code`» —
  закрыл бы класс ошибок вида «забыли геттер у нового листа sealed-иерархии».
- Не хватило в присылке: `gen_error_mapper.dart`, `generation_service.dart`
  (`resumeJob`/`findLiveJobId`), `images_api_executor.dart` (`resumeJobId`) —
  их сигнатуры не проверены, только вызовы из chat_screen.

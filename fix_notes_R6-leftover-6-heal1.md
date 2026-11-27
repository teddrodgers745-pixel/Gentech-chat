# R6-leftover-6-heal1 — причина и правки

## Что было не так (причина, а не симптом)
Коммит R6-leftover-6 обновил ПОТРЕБИТЕЛЕЙ (chat_message.dart, chat_screen.dart, events),
но не обновил саму модель: в lib/core/models/message_part.dart у PendingPart не было поля
`indeterminate` и класса `UnknownPart` не существовало вовсе (MessagePart — sealed, поэтому
UnknownPart обязан лежать в той же библиотеке). Плюс в ActiveModelController.updateSelectedMediaParams
блок quality ссылался на не объявленную `clean` (полуготовый edit: у aspectRatio/resolution
`clean` есть, у quality — нет). Отсюда все 10 ошибок analyze.

## Что поправлено
1. lib/core/models/message_part.dart: PendingPart + `final bool indeterminate` (const, default false);
   добавлен UnknownPart(kind, raw).
2. lib/core/generation/active_model_controller.dart: объявлен `final clean = quality?.trim();`.
3. lib/models/chat_message.dart: ветка `is UnknownPart` в _encodePart перенесена ПЕРЕД `is TextPart`
   (см. ниже, почему это обязательно).

## Почему UnknownPart наследует TextPart (важно!)
MessagePart объявлен sealed. Добавление НОВОГО прямого листа ломает исчерпывающие switch по
частям — прежде всего MessageView._partsWidgets (lib/widgets/message_view.dart: ветки
ImagePart/VideoPart/PendingPart/ErrorPart/TextPart без default). Этот файл НЕ был прислан,
а полный текст его восстановить надёжно нельзя — поэтому UnknownPart сделан подтипом TextPart
с пустым текстом: он покрывается существующей веткой `case TextPart(): break;` (UI рисует
«ничего», как и раньше для нераспознанных частей), sealed-гарантии сохранены, build зелёный.
kind/raw при этом полноценно сериализуются/восстанавливаются (R6, п.7 не регрессирует),
для чего ветка кодирования перенесена до проверки is TextPart.

## Чего не хватило / что улучшить рядом
- Не был прислан lib/core/models/message_part.dart — восстановлен из репозитория по HEAD; сверить diff.
- Правильная эволюция: сделать UnknownPart ОТДЕЛЬНЫМ листом sealed-иерархии и добавить ветку
  `case UnknownPart(): break;` (или тихую заглушку) в MessageView._partsWidgets, а также
  показывать indeterminate-индикацию в _PartPending вместо процента (R6, п.8, UI-этап).
  До этого файла дотянуться не смог — помечено как следующий шаг.
- PendingPart.== намеренно не тронут (сравнение по name/localPath/jobId): сравнение частей
  нигде не используется как ключевое, а смена семантики равенства — отдельное решение.

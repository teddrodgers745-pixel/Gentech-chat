НЕДОСТАЮЩИЕ ФАЙЛЫ: нет

G1-fix-tests-heal1 (CI 46118065258): шаг «Run tests» — 73 passed, 6 failed,
все 6 — тесты test/g1_video_player_test.dart. Правка 7dc7669 (флаг
GoogleFonts.config.allowRuntimeFetching = false в main() теста) НЕ устранила
источник необработанных исключений, а лишь сменила сообщение: в google_fonts
6.2.x при запрещённой runtime-догрузке и отсутствии шрифта в assets
loadFontIfNecessary кидает Exception («allowRuntimeFetching is false but font
JetBrainsMono-Regular was not found in the application assets») — по-прежнему
из fire-and-forget future (`loadFontIfNecessary(...).then(...)` без onError,
google_fonts_base.dart:112 -> :179). Необработанное async-исключение
атрибутируется выполняющемуся тесту (в т.ч. «after the test had completed»)
и роняет тест — это видно по стеку в логе для каждого из 6 падений
(PLAY-PAUSE, DOWNLOAD, SHARE, GALLERY-OPENS-PLAYER и остальные).

Исправление (lib/theme.dart, только метод fontStyle): при запрещённой
runtime-догрузке шрифтов (GoogleFonts.config.allowRuntimeFetching == false)
fontStyle больше не вызывает GoogleFonts.getFont и возвращает обычный
TextStyle. Без вызова getFont не планируется loadFontIfNecessary —
необработанного исключения не возникает вовсе. Это семантически корректно:
если runtime-догрузка запрещена и шрифт не бандлен, единственный безопасный
результат — fallback-стиль. В проде флаг не меняется (true по умолчанию),
ветка google_fonts в fontStyle работает как раньше; ничего кроме fontStyle
не изменено.

test/g1_video_player_test.dart не менялся: настройка флага в main() остаётся
(она корректна и теперь ещё и достаточна), фикстуры DOWNLOAD из 7dc7669
(мок getDownloadsPath, синхронная «отмена» канала file_picker, окна runAsync
в цикле прокачки) сохранены. В этом прогоне единственной видимой причиной
падений были исключения google_fonts (стек loadFontIfNecessary), а не логика
плеера/скачивания — f1_retry_resume_test.dart зелёный (+73 в счётчике).

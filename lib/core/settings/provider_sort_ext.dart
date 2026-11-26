// Copyright (c) 2026 Minkail. All rights reserved.

import '../../app_state.dart';

/// TEMP-SHIM (heal1): геттер `providerSort`, который использует коммит R5
/// в `ImagesApiExecutor._providerSelectionBody` и
/// `ChatService.providerSelectionPayload` (тело `provider: {sort: …}`
/// для Polza: провайдер НЕ захардкожен, из настроек берётся только
/// критерий сортировки; по правилам проекта по умолчанию — самый дешёвый).
///
/// Причина: `app_state.dart` не был прислан, а по логу CI у `AppSettings`
/// нет поля `providerSort` (undefined_getter). Пока поле не появится в
/// `AppSettings` (persist-настройка), геттер возвращает документированный
/// дефолт 'price' — сортировка по цене, самый дешёвый провайдер Polza.
/// Экземпляр метод перекроет расширение без ошибок, так что добавление
/// настоящего поля безопасно; после него это расширение удалить.
extension AppSettingsProviderSort on AppSettings {
  String get providerSort => 'price';
}

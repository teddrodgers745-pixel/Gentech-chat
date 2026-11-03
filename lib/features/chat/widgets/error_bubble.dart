// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../../core/models/gen_error.dart';
import '../../../core/models/gen_error_mapper.dart';
import '../../../screens/settings_screen.dart';

/// Контекстное действие карточки ошибки. Ровно одно на карточку.
enum _ErrorAction { retry, changeModel, settings }

/// Карточка ошибки генерации в стиле приложения: иконка в тёплом круге,
/// заголовок, текст ошибки и ОДНА контекстная кнопка:
///  - AuthError / InsufficientFunds -> «Настройки»;
///  - ModelNotFoundError -> «Сменить модель»;
///  - остальные -> «Повторить».
/// Действия можно переопределить колбэками; без колбэка «Настройки»
/// открывает экран настроек сама.
class ErrorBubble extends StatelessWidget {
  final GenError error;

  /// Исходный промпт, на который не удалось получить ответ.
  final String originalPrompt;

  final VoidCallback? onRetry;
  final VoidCallback? onChangeModel;
  final VoidCallback? onOpenSettings;

  const ErrorBubble({
    super.key,
    required this.error,
    this.originalPrompt = '',
    this.onRetry,
    this.onChangeModel,
    this.onOpenSettings,
  });

  _ErrorAction get _action => switch (error) {
        AuthError() => _ErrorAction.settings,
        InsufficientFunds() => _ErrorAction.settings,
        ModelNotFoundError() => _ErrorAction.changeModel,
        RateLimited() => _ErrorAction.retry,
        ServerError() => _ErrorAction.retry,
        NetworkError() => _ErrorAction.retry,
        JobTimeout() => _ErrorAction.retry,
        ContentFiltered() => _ErrorAction.retry,
        BadRequestError() => _ErrorAction.retry,
        UnknownGenError() => _ErrorAction.retry,
      };

  String get _title => switch (error) {
        AuthError() => 'Ошибка авторизации',
        InsufficientFunds() => 'Недостаточно средств',
        RateLimited() => 'Слишком много запросов',
        ModelNotFoundError() => 'Модель недоступна',
        ServerError() => 'Сервер недоступен',
        NetworkError() => 'Проблема с сетью',
        ContentFiltered() => 'Запрос отклонён фильтром',
        JobTimeout() => 'Истекло время ожидания',
        BadRequestError() => 'Некорректный запрос',
        UnknownGenError() => 'Ошибка генерации',
      };

  IconData get _icon => switch (error) {
        AuthError() => Icons.key_off_rounded,
        InsufficientFunds() => Icons.account_balance_wallet_outlined,
        RateLimited() => Icons.schedule_rounded,
        ModelNotFoundError() => Icons.search_off_rounded,
        ServerError() => Icons.cloud_off_rounded,
        NetworkError() => Icons.wifi_off_rounded,
        ContentFiltered() => Icons.shield_outlined,
        JobTimeout() => Icons.hourglass_bottom_rounded,
        BadRequestError() => Icons.warning_amber_rounded,
        UnknownGenError() => Icons.error_outline_rounded,
      };

  String get _actionLabel => switch (_action) {
        _ErrorAction.retry => 'Повторить',
        _ErrorAction.changeModel => 'Сменить модель',
        _ErrorAction.settings => 'Настройки',
      };

  void _run(BuildContext context) {
    switch (_action) {
      case _ErrorAction.retry:
        onRetry?.call();
      case _ErrorAction.changeModel:
        final cb = onChangeModel ?? onOpenSettings;
        if (cb != null) {
          cb();
        } else {
          _openSettings(context);
        }
      case _ErrorAction.settings:
        final cb = onOpenSettings;
        if (cb != null) {
          cb();
        } else {
          _openSettings(context);
        }
    }
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final details = GenErrorMapper.detailsOf(error);
    final bodyText =
        details.trim().isEmpty ? 'Не удалось получить ответ от модели.' : details;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(_icon, size: 20, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      bodyText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        height: 1.4,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (originalPrompt.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              originalPrompt,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                height: 1.35,
                fontStyle: FontStyle.italic,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _run(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.primary,
                side: BorderSide(color: cs.primary, width: 1.4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                minimumSize: const Size(0, 40),
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              icon: Icon(
                switch (_action) {
                  _ErrorAction.retry => Icons.refresh_rounded,
                  _ErrorAction.changeModel => Icons.swap_horiz_rounded,
                  _ErrorAction.settings => Icons.tune_rounded,
                },
                size: 18,
              ),
              label: Text(_actionLabel),
            ),
          ),
        ],
      ),
    );
  }
}

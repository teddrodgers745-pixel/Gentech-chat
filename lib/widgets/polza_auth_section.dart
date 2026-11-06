// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../core/auth/polza_auth_service.dart';
import '../theme.dart';

/// Карточка аккаунта Polza AI (OAuth 2.0 PKCE) — первая секция настроек.
///
/// До входа: кнопка «Войти через Polza» (системный браузер + локальный
/// loopback-перехват редиректа), состояние ожидания и ручной ввод
/// кода/ключа. После входа: статус, email/имя, маскированный токен,
/// баланс с обновлением, лимиты с прогресс-баром, «Пополнить» и «Выйти».
class PolzaAuthSection extends StatelessWidget {
  const PolzaAuthSection({super.key});

  static const Color _ok = Color(0xFF2E7D32);
  static const Color _bad = Color(0xFFB3261E);

  Future<void> _manualCodeDialog(BuildContext context) async {
    final controller = TextEditingController();
    final submitted = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Завершение входа Polza AI'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Если браузер не вернул вас автоматически, вставьте код '
              'авторизации либо API-ключ Polza AI:',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Код авторизации или ключ',
                hintText: 'sk-...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Подключить'),
          ),
        ],
      ),
    );
    if (submitted != null && submitted.isNotEmpty) {
      await polzaAuth.completeWithCodeOrKey(submitted);
    }
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из Polza AI?'),
        content: const Text(
          'Токен доступа будет удалён с устройства. Войти снова можно '
          'в любой момент одной кнопкой.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (ok == true) await polzaAuth.logout();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[polzaAuth, settings]),
        builder: (context, _) {
          final p = settings.palette;
          final authed = polzaAuth.isAuthenticated;
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: authed ? p.accent.withValues(alpha: 0.55) : p.border,
                width: authed ? 1.4 : 1.0,
              ),
            ),
            child: authed ? _buildAuthed(context, p) : _buildUnsigned(context, p),
          );
        },
      ),
    );
  }

  Widget _iconBox(Palette p, IconData icon, Color color) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: color, size: 23),
    );
  }

  Widget _badge(String text, Color color, Palette p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _buildUnsigned(BuildContext context, Palette p) {
    final busy = polzaAuth.isAuthenticating;
    final err = polzaAuth.errorMessage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _iconBox(p, Icons.bolt_rounded, p.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          'Polza AI',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: p.text,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _badge('OAuth 2.0 PKCE', p.accent, p),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Вход в один клик без ручного копирования ключей',
                    style: TextStyle(fontSize: 12.5, color: p.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (err != null && err.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _bad.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _bad.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded, size: 18, color: _bad),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    err,
                    style: TextStyle(fontSize: 12.5, color: p.text),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        if (!busy)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: polzaAuth.startOAuthPkceFlow,
              icon: const Icon(Icons.login_rounded, size: 19),
              label: const Text(
                'Войти через Polza',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          )
        else ...[
          Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: p.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Ожидание подтверждения входа в браузере…',
                  style: TextStyle(fontSize: 13, color: p.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _manualCodeDialog(context),
                icon: const Icon(Icons.key_rounded, size: 17),
                label: const Text('Ввести код / ключ'),
              ),
              TextButton(
                onPressed: polzaAuth.cancelAuthFlow,
                child: const Text('Отмена'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildAuthed(BuildContext context, Palette p) {
    final acc = polzaAuth.account;
    final balance = acc?.balance;
    final currency = acc?.currency ?? settings.currency;
    final limit = acc?.creditLimit;
    final used = acc?.usedCredits;
    final rpm = acc?.rateLimitRpm;
    final isPolzaActive =
        settings.baseUrl.trim() == PolzaAuthService.polzaBaseUrl;

    final String balanceText;
    if (balance != null) {
      final sym = switch (currency) {
        'RUB' => '₽',
        'USD' => r'$',
        _ => currency,
      };
      balanceText = '${balance.toStringAsFixed(2)} $sym';
    } else {
      balanceText = 'Доступен';
    }

    String limitText = 'Без ограничений';
    double? limitProgress;
    if (limit != null && limit > 0) {
      final u = used ?? 0.0;
      limitProgress = (u / limit).clamp(0.0, 1.0);
      limitText = '${u.toStringAsFixed(1)} / ${limit.toStringAsFixed(1)}';
    } else if (rpm != null && rpm > 0) {
      limitText = '$rpm запр./мин';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _iconBox(p, Icons.verified_user_rounded, _ok),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          (acc?.label.isNotEmpty == true) ? acc!.label : 'Polza AI',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: p.text,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _badge('Подключено', _ok, p),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    (acc?.email.isNotEmpty == true)
                        ? '${acc!.email} • ${polzaAuth.maskedToken}'
                        : 'Токен: ${polzaAuth.maskedToken}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: p.muted),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Обновить баланс и лимиты',
              onPressed: polzaAuth.isLoadingBalance
                  ? null
                  : polzaAuth.refreshAccountStatus,
              icon: polzaAuth.isLoadingBalance
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: p.accent,
                      ),
                    )
                  : Icon(Icons.refresh_rounded, color: p.accent),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(child: _infoBox(p, 'Баланс', balanceText)),
            const SizedBox(width: 10),
            Expanded(
              child: _infoBox(
                p,
                'Лимиты и квота',
                limitText,
                progress: limitProgress,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!isPolzaActive)
              FilledButton.tonalIcon(
                onPressed: polzaAuth.applyToSettings,
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: const Text('Использовать в чате'),
              ),
            OutlinedButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(PolzaAuthService.polzaBillingUrl),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
              label: const Text('Пополнить'),
            ),
            OutlinedButton.icon(
              onPressed: () => _confirmLogout(context),
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('Выйти'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _infoBox(
    Palette p,
    String label,
    String value, {
    double? progress,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.bg.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11.5, color: p.muted)),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          if (progress != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                color: p.accent,
                backgroundColor: p.border,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/auth/routerai_auth_service.dart';
import '../core/storage.dart';
import '../theme.dart';

/// Карточка аккаунта RouterAI (OAuth 2.0 PKCE) — вторая секция настроек,
/// размещается ниже карточки Polza AI.
///
/// До входа: кнопка «Войти через RouterAI» (системный браузер и локальный
/// loopback-перехват редиректа), состояние ожидания и ручной ввод кода
/// или ключа. После входа: статус, маскированный ключ (sk-...) и выход.
///
/// OAuth Debug: сырой ответ обмена кода и распарсенный ключ выводятся
/// мелким моноширинным шрифтом под карточкой; крестик очищает лог.
class RouterAiAuthSection extends StatefulWidget {
  const RouterAiAuthSection({super.key});

  @override
  State<RouterAiAuthSection> createState() => _RouterAiAuthSectionState();

  static const Color _ok = Color(0xFF2E7D32);
  static const Color _bad = Color(0xFFB3261E);
}

class _RouterAiAuthSectionState extends State<RouterAiAuthSection> {
  String _debugRaw = '';
  String _debugParsed = '';
  String _debugError = '';

  @override
  void initState() {
    super.initState();
    routerAiAuth.addListener(_loadDebug);
    _loadDebug();
  }

  @override
  void dispose() {
    routerAiAuth.removeListener(_loadDebug);
    super.dispose();
  }

  Future<void> _loadDebug() async {
    final raw =
        (await storage.getString(RouterAiAuthService.debugRawKey)) ?? '';
    final parsed =
        (await storage.getString(RouterAiAuthService.debugParsedKey)) ?? '';
    final err =
        (await storage.getString(RouterAiAuthService.debugErrorKey)) ?? '';
    if (!mounted) return;
    setState(() {
      _debugRaw = raw;
      _debugParsed = parsed;
      _debugError = err;
    });
  }

  Future<void> _clearDebug() async {
    await storage.setString(RouterAiAuthService.debugRawKey, '');
    await storage.setString(RouterAiAuthService.debugParsedKey, '');
    await storage.setString(RouterAiAuthService.debugErrorKey, '');
    if (!mounted) return;
    setState(() {
      _debugRaw = '';
      _debugParsed = '';
      _debugError = '';
    });
  }

  Future<void> _manualCodeDialog(BuildContext context) async {
    final controller = TextEditingController();
    final submitted = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Завершение входа RouterAI'),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Код авторизации или ключ',
            hintText: 'sk-...',
          ),
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
      await routerAiAuth.completeWithCodeOrKey(submitted);
    }
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из RouterAI?'),
        content: const Text(
          'Ключ доступа будет удалён с устройства. Войти снова можно '
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
    if (ok == true) await routerAiAuth.logout();
  }

  /// Первые 8 символов ключа для диагностики; пустой ключ — прочерк.
  static String _prefix8(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '-';
    return s.length <= 8 ? s : s.substring(0, 8);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[routerAiAuth, settings]),
        builder: (context, _) {
          final p = settings.palette;
          final authed = routerAiAuth.isAuthenticated;
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                authed
                    ? _buildAuthed(context, p)
                    : _buildUnsigned(context, p),
                _debugBlock(p),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _debugBlock(Palette p) {
    final raw = _debugRaw;
    final showKeys =
        routerAiAuth.isAuthenticated || _debugParsed.trim().isNotEmpty;
    if (raw.trim().isEmpty && !showKeys) return const SizedBox.shrink();
    final rawShort = raw.length > 200 ? raw.substring(0, 200) : raw;
    final key = _debugParsed.trim().isEmpty ? 'null' : _debugParsed;
    final err = _debugError.trim();
    final text = raw.trim().isEmpty
        ? 'DEBUG: raw=—'
        : 'DEBUG: key=$key | raw=$rawShort'
            '${err.isEmpty ? '' : ' | error=$err'}';
    final keysLine =
        'DEBUG KEYS: routerAiAuth=${_prefix8(routerAiAuth.accessToken)}'
        ' | settings=${_prefix8(settings.apiKey)}'
        ' | preset=${_prefix8(presets.active?.apiKey ?? '')}';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(10, 4, 4, 10),
        decoration: BoxDecoration(
          color: p.bg.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'OAuth Debug',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: p.muted,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Очистить лог',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.close_rounded, size: 16, color: p.muted),
                  onPressed: _clearDebug,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: SelectableText(
                text,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.4,
                  color: p.muted,
                  fontFamily: 'JetBrains Mono',
                  fontFamilyFallback: const ['monospace'],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: SelectableText(
                keysLine,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.4,
                  color: p.text,
                  fontFamily: 'JetBrains Mono',
                  fontFamilyFallback: const ['monospace'],
                ),
              ),
            ),
          ],
        ),
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
    final busy = routerAiAuth.isAuthenticating;
    final err = routerAiAuth.errorMessage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _iconBox(p, Icons.hub_outlined, p.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          'RouterAI',
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
              color: RouterAiAuthSection._bad.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: RouterAiAuthSection._bad.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: RouterAiAuthSection._bad,
                ),
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
              onPressed: routerAiAuth.startOAuthPkceFlow,
              icon: const Icon(Icons.login_rounded, size: 19),
              label: const Text(
                'Войти через RouterAI',
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
                onPressed: routerAiAuth.cancelAuthFlow,
                child: const Text('Отмена'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildAuthed(BuildContext context, Palette p) {
    final acc = routerAiAuth.account;
    final isActive = settings.baseUrl.trim() ==
        RouterAiAuthService.routeraiBaseUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _iconBox(
              p,
              Icons.verified_user_rounded,
              RouterAiAuthSection._ok,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          (acc?.label.isNotEmpty == true)
                              ? acc!.label
                              : 'RouterAI',
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
                      _badge('Подключено', RouterAiAuthSection._ok, p),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Ключ: ${routerAiAuth.maskedToken}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: p.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!isActive)
              FilledButton.tonalIcon(
                onPressed: routerAiAuth.applyToSettings,
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: const Text('Использовать в чате'),
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
}

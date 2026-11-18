// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_state.dart';
import '../storage.dart';

/// Глобальный экземпляр сервиса авторизации Polza AI.
final PolzaAuthService polzaAuth = PolzaAuthService();

/// Состояния процесса авторизации Polza AI.
enum PolzaAuthStatus { unauthenticated, authenticating, authenticated, error }

/// Профиль, баланс и лимиты авторизованного пользователя Polza AI.
class PolzaAccountInfo {
  final String userId;
  final String email;
  final String label;
  final double? balance;
  final String currency;
  final double? creditLimit;
  final double? usedCredits;
  final int? rateLimitRpm;
  final DateTime updatedAt;

  const PolzaAccountInfo({
    this.userId = '',
    this.email = '',
    this.label = 'Polza AI Аккаунт',
    this.balance,
    this.currency = 'RUB',
    this.creditLimit,
    this.usedCredits,
    this.rateLimitRpm,
    required this.updatedAt,
  });

  double? get remainingLimit {
    final limit = creditLimit;
    final used = usedCredits;
    if (limit == null) return null;
    if (used == null) return limit;
    return (limit - used).clamp(0.0, double.infinity);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'userId': userId,
        'email': email,
        'label': label,
        'balance': balance,
        'currency': currency,
        'creditLimit': creditLimit,
        'usedCredits': usedCredits,
        'rateLimitRpm': rateLimitRpm,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory PolzaAccountInfo.fromJson(Map<String, dynamic> json) {
    return PolzaAccountInfo(
      userId: (json['userId'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      label: (json['label'] ?? 'Polza AI Аккаунт').toString(),
      balance: _toDouble(json['balance']),
      currency: (json['currency'] ?? 'RUB').toString(),
      creditLimit: _toDouble(json['creditLimit']),
      usedCredits: _toDouble(json['usedCredits']),
      rateLimitRpm: _toInt(json['rateLimitRpm']),
      updatedAt: DateTime.tryParse((json['updatedAt'] ?? '').toString()) ??
          DateTime.now(),
    );
  }

  static double? _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim().replaceAll(',', '.'));
    return null;
  }

  static int? _toInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }
}

/// Параметры рукопожатия OAuth 2.0 PKCE (RFC 7636).
class PkcePair {
  final String codeVerifier;
  final String codeChallenge;
  final String state;

  const PkcePair({
    required this.codeVerifier,
    required this.codeChallenge,
    required this.state,
  });

  /// code_verifier: 64 случайных байта -> base64url без паддинга (86
  /// символов [A-Za-z0-9-_], допустимо 43-128). state: 16 случайных
  /// байта. code_challenge: BASE64URL(SHA256(verifier)) — пакет crypto,
  /// метод S256.
  static PkcePair generate() {
    final rnd = Random.secure();
    final verifierBytes = List<int>.generate(64, (_) => rnd.nextInt(256));
    final stateBytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    final verifier = _b64u(verifierBytes);
    final state = _b64u(stateBytes);
    final digest = sha256.convert(utf8.encode(verifier)).bytes;
    return PkcePair(
      codeVerifier: verifier,
      codeChallenge: _b64u(digest),
      state: state,
    );
  }

  static String _b64u(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}

/// Хранилище OAuth-ключа Polza AI и кэша профиля. Ключ — долгоживущий
/// API-ключ формата pza_...; старые запечатанные значения ('v1:...')
/// игнорируются и затираются.
class SecureTokenStore {
  static const String _kAccessKey = 'polza_secure_access_token_v1';
  static const String _kAccountKey = 'polza_account_info_v1';

  Future<void> saveTokens({required String accessToken}) =>
      storage.setString(_kAccessKey, accessToken);

  Future<String?> readAccessToken() async {
    final raw = await storage.getString(_kAccessKey);
    if (raw == null || raw.isEmpty) return null;
    if (!raw.startsWith('pza_')) {
      await storage.setString(_kAccessKey, '');
      return null;
    }
    return raw;
  }

  Future<void> saveAccount(PolzaAccountInfo info) =>
      storage.setString(_kAccountKey, jsonEncode(info.toJson()));

  Future<PolzaAccountInfo?> readAccount() async {
    final raw = await storage.getString(_kAccountKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return PolzaAccountInfo.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    await storage.setString(_kAccessKey, '');
    await storage.setString(_kAccountKey, '');
  }
}

/// Сервис авторизации через Polza AI по OAuth 2.0 PKCE.
///
/// ФИНАЛЬНЫЙ ФИКС обмена кода (главная причина ошибки
/// «Не удалось обменять код авторизации...»):
///  1. callback_url генерируется ОДИН РАЗ при старте потока входа и
///     хранится в переменной класса [_pendingRedirectUri]. Один и тот же
///     URL отправляется и в /auth/authorize (параметр callback_url),
///     и в POST /auth/token (поле callback_url) — строгое совпадение,
///     которого требует сервер Polza.
///  2. Ответ /auth/token читается как СЫРАЯ СТРОКА при любом статусе
///     (validateStatus: (_) => true): тело 4xx доступно и показывается
///     пользователю в формате 'HTTP 400: <сырой JSON>'.
///  3. Ключ принимается только с префиксом 'pza_'.
///  4. Перед отправкой в лог выводится callback_url и длина
///     code_verifier.
class PolzaAuthService extends ChangeNotifier {
  static const String polzaBaseUrl = 'https://polza.ai/api/v1';
  static const String polzaAuthEndpoint = 'https://polza.ai/api/auth/authorize';
  static const String polzaTokenEndpoint = 'https://polza.ai/api/auth/token';
  static const String polzaBillingUrl = 'https://polza.ai/dashboard/billing';
  static const String defaultModel = 'deepseek/deepseek-chat';

  /// Имя приложения, которое Polza ожидает в параметре app_name.
  static const String appName = 'GenTech Chat';

  /// Ключи OAuth-отладки; их читает секция PolzaAuthSection.
  static const String debugRawKey = 'polza_oauth_debug_raw';
  static const String debugParsedKey = 'polza_oauth_debug_parsed';
  static const String debugErrorKey = 'polza_oauth_debug_error';

  final SecureTokenStore _tokenStore = SecureTokenStore();
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  PolzaAuthStatus _status = PolzaAuthStatus.unauthenticated;
  String? _accessToken;
  PolzaAccountInfo? _account;
  String? _errorMessage;
  bool _loadingBalance = false;

  PkcePair? _pendingPkce;

  /// ЕДИНЫЙ callback_url текущего потока входа: генерируется один раз
  /// и отправляется и в authorize, и в token.
  String? _pendingRedirectUri;
  HttpServer? _loopbackServer;
  Timer? _timeoutTimer;

  PolzaAuthStatus get status => _status;

  String get accessToken => _accessToken ?? '';

  bool get isAuthenticated =>
      _status == PolzaAuthStatus.authenticated &&
      (_accessToken != null && _accessToken!.isNotEmpty);
  bool get isAuthenticating => _status == PolzaAuthStatus.authenticating;
  bool get isLoadingBalance => _loadingBalance;
  PolzaAccountInfo? get account => _account;
  String? get errorMessage => _errorMessage;

  /// Маскированное представление токена для показа в UI.
  String get maskedToken {
    final t = _accessToken ?? '';
    if (t.isEmpty) return '';
    if (t.length <= 10) return '••••••••';
    final prefix = t.substring(0, min(7, t.length));
    final suffix = t.substring(t.length - 4);
    return '$prefix••••$suffix';
  }

  /// Алиас: запуск входа в один клик.
  Future<void> login() => startOAuthPkceFlow();

  /// Восстановление сессии при старте приложения.
  Future<void> load() async {
    try {
      _accessToken = await _tokenStore.readAccessToken();
      _account = await _tokenStore.readAccount();
      if (_accessToken != null && _accessToken!.isNotEmpty) {
        _status = PolzaAuthStatus.authenticated;
        if (settings.apiKey.trim().isEmpty) applyToSettings();
        notifyListeners();
        unawaited(refreshAccountStatus());
      }
    } catch (_) {
      _status = PolzaAuthStatus.unauthenticated;
    }
  }

  /// Запуск входа в один клик. Если ключ уже сохранён — сессия
  /// восстанавливается без браузера.
  Future<void> startOAuthPkceFlow() async {
    if (_accessToken != null && _accessToken!.isNotEmpty) {
      _status = PolzaAuthStatus.authenticated;
      _errorMessage = null;
      notifyListeners();
      return;
    }
    await _stopLoopbackServer();
    _errorMessage = null;
    _status = PolzaAuthStatus.authenticating;
    notifyListeners();

    final pkce = PkcePair.generate();
    _pendingPkce = pkce;

    // callback_url генерируется ОДИН РАЗ и сохраняется в переменной
    // класса: этот же URL уйдёт и в authorize, и в POST /auth/token.
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } catch (_) {
      cancelAuthFlow(
        error: 'Не удалось запустить локальный callback-сервер. '
            'Проверьте сеть и повторите.',
      );
      return;
    }
    _loopbackServer = server;
    final redirectUri = 'http://127.0.0.1:${server.port}/auth/polza/callback';
    _pendingRedirectUri = redirectUri;
    unawaited(_listenLoopback(server));

    // Таймаут ожидания подтверждения в браузере — 5 минут.
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(minutes: 5), () {
      if (_status == PolzaAuthStatus.authenticating) {
        cancelAuthFlow(
          error: 'Время ожидания входа в браузере истекло. Попробуйте снова.',
        );
      }
    });

    final authUri = Uri.parse(polzaAuthEndpoint).replace(
      queryParameters: <String, String>{
        'response_type': 'code',
        'callback_url': redirectUri,
        'code_challenge': pkce.codeChallenge,
        'code_challenge_method': 'S256',
        'state': pkce.state,
        'app_name': appName,
      },
    );

    try {
      final launched = await launchUrl(
        authUri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        cancelAuthFlow(error: 'Не удалось открыть браузер для входа.');
      }
    } catch (_) {
      cancelAuthFlow(error: 'Ошибка запуска браузера. Проверьте его наличие.');
    }
  }

  Future<void> _listenLoopback(HttpServer server) async {
    try {
      await for (final HttpRequest request in server) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        request.response.write(_callbackHtml);
        await request.response.close();
        final uri = request.uri;
        if (uri.path.contains('callback') ||
            uri.queryParameters.containsKey('code') ||
            uri.queryParameters.containsKey('key')) {
          await handleCallbackUri(uri);
          break;
        }
      }
    } catch (_) {
      // Сервер закрыт либо соединение оборвано — не критично.
    } finally {
      await _stopLoopbackServer();
    }
  }

  static const String _callbackHtml = '''
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>GenTech Chat — Polza AI</title>
  <style>
    body { background:#1B1A19; color:#F5F2EB; font-family:system-ui,sans-serif;
           display:flex; align-items:center; justify-content:center;
           height:100vh; margin:0; text-align:center; }
    .card { background:#262422; padding:32px; border-radius:24px;
            border:1px solid #3D3935; max-width:380px; }
    h2 { color:#D99A6C; margin-top:0; }
    p { color:#A8A096; line-height:1.5; }
  </style>
</head>
<body>
  <div class="card">
    <h2>Вход выполнен!</h2>
    <p>Аккаунт Polza AI подключён к GenTech Chat. Можно закрыть вкладку
       и вернуться в приложение.</p>
  </div>
</body>
</html>
''';

  /// Обрабатывает редирект от провайдера.
  Future<bool> handleCallbackUri(Uri uri) async {
    final params = uri.queryParameters;
    if (params.containsKey('error')) {
      final desc = params['error_description'] ?? params['error'] ?? 'Отказ';
      cancelAuthFlow(error: 'Авторизация отклонена: $desc');
      return false;
    }

    final expectedState = _pendingPkce?.state;
    final incomingState = params['state'];
    if (expectedState != null &&
        incomingState != null &&
        incomingState.isNotEmpty &&
        incomingState != expectedState) {
      cancelAuthFlow(
        error: 'Ошибка безопасности OAuth (несовпадение параметра state).',
      );
      return false;
    }

    // Провайдер мог вернуть готовый ключ прямо в callback.
    final directKey = params['key'] ?? params['api_key'];
    if (directKey != null && directKey.trim().startsWith('pza_')) {
      return _finalizeLogin(accessToken: directKey.trim());
    }

    final code = params['code']?.trim() ?? '';
    if (code.isEmpty) {
      cancelAuthFlow(error: 'В ответе провайдера отсутствует код авторизации.');
      return false;
    }
    return _exchangeCodeForToken(code);
  }

  /// Обмен authorization_code + code_verifier (PKCE) на ключ Polza.
  Future<bool> _exchangeCodeForToken(String code) async {
    final pkce = _pendingPkce;
    // Один и тот же callback_url, что был отправлен на /auth/authorize.
    final callbackUrl = _pendingRedirectUri ?? '';
    final codeVerifier = pkce?.codeVerifier ?? '';
    debugPrint(
      'Exchanging code. callback_url: $callbackUrl, '
      'code_verifier length: ${codeVerifier.length}',
    );
    if (callbackUrl.isEmpty || codeVerifier.isEmpty) {
      cancelAuthFlow(error: 'PKCE-сессия истекла. Запустите вход заново.');
      return false;
    }
    try {
      final response = await _dio.post<String>(
        polzaTokenEndpoint,
        data: <String, dynamic>{
          'grant_type': 'authorization_code',
          'code': code,
          'code_verifier': codeVerifier,
          'callback_url': callbackUrl,
        },
        options: Options(
          headers: const <String, String>{
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          // Сырое тело при ЛЮБОМ статусе — 4xx не теряется.
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      final body = response.data ?? '';
      final status = response.statusCode ?? 0;
      debugPrint('[auth] /auth/token -> HTTP $status: '
          '${body.length > 500 ? '${body.substring(0, 500)}…' : body}');

      if (status >= 200 && status < 300) {
        Map<String, dynamic> data = <String, dynamic>{};
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map) {
            data = Map<String, dynamic>.from(decoded);
          }
        } catch (_) {}
        final key = (data['key'] ?? '').toString().trim();
        final userId = (data['user_id'] ?? '').toString().trim();
        if (key.startsWith('pza_')) {
          await _saveDebug(raw: body, parsed: key, error: '');
          return _finalizeLogin(accessToken: key, userId: userId);
        }
        // 200, но ключ не pza_: показываем сырой ответ.
        await _saveDebug(raw: body, parsed: key, error: 'HTTP $status');
        cancelAuthFlow(
          error: 'Сервер Polza вернул ответ без ключа pza_. '
              'HTTP $status: ${_clip(body)}',
        );
        return false;
      }

      // Ошибка обмена (400 и т.п.): выводим СЫРОЙ ответ на экран.
      await _saveDebug(raw: body, parsed: '', error: 'HTTP $status');
      cancelAuthFlow(
        error: 'Не удалось обменять код авторизации на токен Polza AI. '
            'HTTP $status: ${_clip(body)}',
      );
      return false;
    } catch (e) {
      await _saveDebug(raw: e.toString(), parsed: '', error: 'network');
      cancelAuthFlow(
        error: 'Сетевая ошибка при обмене кода PKCE на токен Polza AI: $e',
      );
      return false;
    }
  }

  /// Обрезка сырого тела для сообщения об ошибке (читаемость в UI).
  static String _clip(String raw) {
    final t = raw.replaceAll('\n', ' ').trim();
    return t.length > 800 ? '${t.substring(0, 800)}…' : t;
  }

  /// Запись OAuth-отладки в хранилище (её читает PolzaAuthSection);
  /// сбой записи не влияет на поток входа.
  Future<void> _saveDebug({
    required String raw,
    required String parsed,
    required String error,
  }) async {
    try {
      await storage.setString(debugRawKey, raw);
      await storage.setString(debugParsedKey, parsed);
      await storage.setString(debugErrorKey, error);
    } catch (_) {}
  }

  /// Ручное завершение входа: ссылка редиректа, код либо ключ.
  Future<bool> completeWithCodeOrKey(String rawInput) async {
    final input = rawInput.trim();
    if (input.isEmpty) return false;
    _errorMessage = null;
    _status = PolzaAuthStatus.authenticating;
    notifyListeners();

    if (input.startsWith('http://') ||
        input.startsWith('https://') ||
        input.startsWith('gentech://')) {
      final uri = Uri.tryParse(input);
      if (uri != null) return handleCallbackUri(uri);
    }
    if (_pendingPkce != null) {
      return _exchangeCodeForToken(input);
    }
    if (!input.startsWith('pza_')) {
      cancelAuthFlow(error: 'Ключ Polza должен начинаться с pza_.');
      return false;
    }
    return _finalizeLogin(accessToken: input);
  }

  /// Финал входа: сохранение ключа, статус authenticated, уведомление
  /// слушателей и применение к настройкам.
  Future<bool> _finalizeLogin({
    required String accessToken,
    String userId = '',
  }) async {
    _timeoutTimer?.cancel();
    _pendingPkce = null;
    _pendingRedirectUri = null;
    await _stopLoopbackServer();

    _accessToken = accessToken;
    _status = PolzaAuthStatus.authenticated;
    _errorMessage = null;

    final prev = _account;
    _account = PolzaAccountInfo(
      userId: userId.isNotEmpty ? userId : (prev?.userId ?? ''),
      email: prev?.email ?? '',
      label: prev?.label ?? 'Polza AI Аккаунт',
      balance: prev?.balance,
      currency: prev?.currency ?? 'RUB',
      creditLimit: prev?.creditLimit,
      usedCredits: prev?.usedCredits,
      rateLimitRpm: prev?.rateLimitRpm,
      updatedAt: DateTime.now(),
    );

    await _tokenStore.saveTokens(accessToken: accessToken);
    await _tokenStore.saveAccount(_account!);
    // Свежий ключ pza_... применяется безусловно: settings.setConnection
    // перезаписывает settings.apiKey и settings.baseUrl, а активный
    // Polza-пресет обновляется тем же токеном.
    applyToSettings();
    await _updateActivePreset(accessToken);
    notifyListeners();
    unawaited(refreshAccountStatus());
    return true;
  }

  /// Обновляет активный пресет свежим OAuth-токеном Polza AI; пресеты
  /// других провайдеров (RouterAI и т.п.) не затрагиваются.
  Future<void> _updateActivePreset(String token) async {
    try {
      final pr = presets.active;
      if (pr == null) return;
      if (!pr.baseUrl.trim().toLowerCase().contains('polza.ai')) return;
      pr.apiKey = token;
      pr.baseUrl = polzaBaseUrl;
      await presets.upsert(pr);
    } catch (_) {}
  }

  /// Прописывает URL, ключ Polza AI и модель в активные настройки.
  void applyToSettings() {
    final token = _accessToken;
    if (token == null || token.isEmpty) return;
    final currentModel = settings.model.trim();
    settings.setConnection(
      url: polzaBaseUrl,
      key: token,
      mdl: currentModel.isEmpty ? defaultModel : currentModel,
    );
  }

  /// Запрашивает актуальный баланс и лимиты аккаунта из API Polza.
  Future<void> refreshAccountStatus() async {
    final token = _accessToken;
    if (token == null || token.isEmpty) return;

    _loadingBalance = true;
    notifyListeners();

    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
    };

    double? balance;
    var currency = settings.currency;
    double? creditLimit;
    double? usedCredits;
    int? rateLimitRpm;
    var email = _account?.email ?? '';
    var label = _account?.label ?? 'Polza AI Аккаунт';
    var userId = _account?.userId ?? '';

    for (final path in const <String>[
      '/auth/key',
      '/credits',
      '/billing/balance',
      '/me',
    ]) {
      try {
        final res = await _dio.get<dynamic>(
          '$polzaBaseUrl$path',
          options: Options(
            headers: headers,
            validateStatus: (s) => s != null && s < 500,
          ),
        );
        if (res.statusCode == 200 && res.data is Map) {
          final map = Map<String, dynamic>.from(res.data as Map);
          final root = map['data'] is Map
              ? Map<String, dynamic>.from(map['data'] as Map)
              : map;

          balance ??= _extractDouble(root, const <String>[
            'balance', 'credits', 'remaining_credits', 'available_balance',
          ]);
          final totalCredits = _extractDouble(root, const <String>[
            'total_credits', 'limit', 'credit_limit',
          ]);
          final totalUsage = _extractDouble(root, const <String>[
            'total_usage', 'usage', 'used_credits', 'used',
          ]);
          if (balance == null && totalCredits != null && totalUsage != null) {
            balance = (totalCredits - totalUsage).clamp(0.0, double.infinity);
          }
          creditLimit ??= totalCredits;
          usedCredits ??= totalUsage;

          if (root['currency'] is String &&
              (root['currency'] as String).trim().isNotEmpty) {
            currency = (root['currency'] as String).trim().toUpperCase();
          }
          if (root['email'] is String &&
              (root['email'] as String).trim().isNotEmpty) {
            email = (root['email'] as String).trim();
          }
          if (root['label'] is String &&
              (root['label'] as String).trim().isNotEmpty) {
            label = (root['label'] as String).trim();
          } else if (root['name'] is String &&
              (root['name'] as String).trim().isNotEmpty) {
            label = (root['name'] as String).trim();
          }
          if (root['id'] != null) userId = root['id'].toString();
          if (root['rate_limit'] is Map) {
            final rl = Map<String, dynamic>.from(root['rate_limit'] as Map);
            rateLimitRpm ??= PolzaAccountInfo._toInt(
              rl['requests'] ?? rl['rpm'] ?? rl['limit'],
            );
          } else {
            rateLimitRpm ??= PolzaAccountInfo._toInt(
              root['rate_limit_rpm'] ?? root['rpm'],
            );
          }
        }
      } catch (_) {
        // Пробуем следующий эндпоинт.
      }
    }

    final updated = PolzaAccountInfo(
      userId: userId,
      email: email,
      label: label,
      balance: balance ?? _account?.balance,
      currency: currency,
      creditLimit: creditLimit ?? _account?.creditLimit,
      usedCredits: usedCredits ?? _account?.usedCredits,
      rateLimitRpm: rateLimitRpm ?? _account?.rateLimitRpm,
      updatedAt: DateTime.now(),
    );
    _account = updated;
    _loadingBalance = false;
    await _tokenStore.saveAccount(updated);
    notifyListeners();
  }

  static double? _extractDouble(Map<String, dynamic> map, List<String> keys) {
    for (final k in keys) {
      final v = PolzaAccountInfo._toDouble(map[k]);
      if (v != null) return v;
    }
    return null;
  }

  /// Отмена текущего ожидания авторизации.
  void cancelAuthFlow({String? error}) {
    _timeoutTimer?.cancel();
    _pendingPkce = null;
    _pendingRedirectUri = null;
    unawaited(_stopLoopbackServer());
    _errorMessage = error;
    _status = error != null
        ? PolzaAuthStatus.error
        : (_accessToken != null && _accessToken!.isNotEmpty
            ? PolzaAuthStatus.authenticated
            : PolzaAuthStatus.unauthenticated);
    notifyListeners();
  }

  /// Выход из аккаунта Polza AI с очисткой хранилища.
  Future<void> logout() async {
    _timeoutTimer?.cancel();
    _pendingPkce = null;
    _pendingRedirectUri = null;
    await _stopLoopbackServer();
    final oldToken = _accessToken;
    _accessToken = null;
    _account = null;
    _errorMessage = null;
    _status = PolzaAuthStatus.unauthenticated;
    await _tokenStore.clear();

    if (oldToken != null &&
        oldToken.isNotEmpty &&
        settings.apiKey.trim() == oldToken.trim()) {
      settings.setConnection(key: '');
    }
    notifyListeners();
  }

  Future<void> _stopLoopbackServer() async {
    final s = _loopbackServer;
    _loopbackServer = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }
}

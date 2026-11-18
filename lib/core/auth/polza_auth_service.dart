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
/// Живут исключительно в оперативной памяти на время сессии входа.
class PkcePair {
  final String codeVerifier;
  final String codeChallenge;
  final String state;

  const PkcePair({
    required this.codeVerifier,
    required this.codeChallenge,
    required this.state,
  });

  /// code_verifier: 64 случайных байта -> base64url без паддинга
  /// (86 символов из [A-Za-z0-9-_], внутри допустимых 43-128).
  /// state: 16 случайных байта. code_challenge: BASE64URL(SHA256(verifier))
  /// без '=' на конце — стандартный пакет crypto (метод S256).
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

/// Хранилище OAuth-ключа Polza AI и кэша профиля. Токен хранится в
/// обычном SharedPreferences БЕЗ самописного шифрования: pza_... — это
/// долгоживущий API-ключ, а не краткоживущий access-токен. Старые
/// запечатанные значения ('v1:...') игнорируются и затираются.
class SecureTokenStore {
  static const String _kAccessKey = 'polza_secure_access_token_v1';
  static const String _kAccountKey = 'polza_account_info_v1';

  Future<void> saveTokens({required String accessToken}) =>
      storage.setString(_kAccessKey, accessToken);

  Future<String?> readAccessToken() async {
    final raw = await storage.getString(_kAccessKey);
    if (raw == null || raw.isEmpty) return null;
    // Ключ Polza всегда начинается с 'pza_' — прочее (в т.ч. старое
    // 'v1:...') невалидно и затирается.
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

/// Сервис авторизации через Polza AI по протоколу OAuth 2.0 PKCE
/// (официальная схема Polza):
///  1. code_verifier — случайная строка 43-128 символов [A-Za-z0-9-._~];
///  2. code_challenge = BASE64URL(SHA256(code_verifier)) без '=';
///  3. системный браузер открывается на /api/auth/authorize с параметрами
///     response_type=code, callback_url, code_challenge,
///     code_challenge_method=S256, state, app_name;
///  4. callback ловится локальным loopback-сервером (RFC 8252);
///  5. код обменивается на POST /api/auth/token с JSON-телом
///     {grant_type: 'authorization_code', code, code_verifier, callback_url};
///  6. ответ {key: 'pza_...', user_id: 'usr_...'}: ключ сохраняется,
///     статус становится authenticated, слушатели уведомляются.
/// Refresh-токены Polza не выдаёт — их здесь нет вовсе.
class PolzaAuthService extends ChangeNotifier {
  static const String polzaBaseUrl = 'https://polza.ai/api/v1';
  static const String polzaAuthEndpoint = 'https://polza.ai/api/auth/authorize';
  static const String polzaTokenEndpoint = 'https://polza.ai/api/auth/token';
  static const String polzaBillingUrl = 'https://polza.ai/dashboard/billing';
  static const String defaultModel = 'deepseek/deepseek-chat';

  /// Имя приложения, которое Polza ожидает в параметре app_name.
  static const String appName = 'GenTech Chat';

  final SecureTokenStore _tokenStore = SecureTokenStore();
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 12),
    ),
  );

  PolzaAuthStatus _status = PolzaAuthStatus.unauthenticated;
  String? _accessToken;
  PolzaAccountInfo? _account;
  String? _errorMessage;
  bool _loadingBalance = false;

  PkcePair? _pendingPkce;
  String? _pendingRedirectUri;
  HttpServer? _loopbackServer;
  Timer? _timeoutTimer;

  PolzaAuthStatus get status => _status;

  /// Ключ доступа: используется EffectiveConfig и секциями настроек
  /// как ключ по умолчанию при активной сессии Polza AI.
  String get accessToken => _accessToken ?? '';

  bool get isAuthenticated =>
      _status == PolzaAuthStatus.authenticated &&
      (_accessToken != null && _accessToken!.isNotEmpty);
  bool get isAuthenticating => _status == PolzaAuthStatus.authenticating;
  bool get isLoadingBalance => _loadingBalance;
  PolzaAccountInfo? get account => _account;
  String? get errorMessage => _errorMessage;

  /// Маскированное представление токена для безопасного показа в UI.
  String get maskedToken {
    final t = _accessToken ?? '';
    if (t.isEmpty) return '';
    if (t.length <= 10) return '••••••••';
    final prefix = t.substring(0, min(7, t.length));
    final suffix = t.substring(t.length - 4);
    return '$prefix••••$suffix';
  }

  /// Алиас по заданию: запуск входа в один клик.
  Future<void> login() => startOAuthPkceFlow();

  /// Инициализация при старте приложения: восстановление сохранённой
  /// сессии. Ошибка чтения не роняет запуск.
  Future<void> load() async {
    try {
      _accessToken = await _tokenStore.readAccessToken();
      _account = await _tokenStore.readAccount();
      if (_accessToken != null && _accessToken!.isNotEmpty) {
        _status = PolzaAuthStatus.authenticated;
        // Если глобальный ключ ещё не задан, подставляем Polza автоматически.
        if (settings.apiKey.trim().isEmpty) applyToSettings();
        notifyListeners();
        unawaited(refreshAccountStatus());
      }
    } catch (_) {
      _status = PolzaAuthStatus.unauthenticated;
    }
  }

  /// Запуск входа в один клик по OAuth 2.0 PKCE. Если сохранённый ключ
  /// уже есть — сессия просто восстанавливается без браузера.
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

    // Loopback-сервер (RFC 8252) для перехвата редиректа; при недоступности
    // порта используется custom scheme gentech://auth/polza/callback.
    var redirectUri = 'gentech://auth/polza/callback';
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _loopbackServer = server;
      redirectUri = 'http://127.0.0.1:${server.port}/auth/polza/callback';
      unawaited(_listenLoopback(server));
    } catch (_) {}
    _pendingRedirectUri = redirectUri;

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
        final uri = request.uri;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        request.response.write(_callbackHtml);
        await request.response.close();
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

  /// Обрабатывает редирект от провайдера OAuth 2.0 PKCE.
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

    // Провайдер мог вернуть готовый ключ прямо в callback — принимаем.
    final directKey = params['key'] ?? params['api_key'];
    if (directKey != null && directKey.trim().isNotEmpty) {
      return _finalizeLogin(accessToken: directKey.trim());
    }

    final code = params['code']?.trim() ?? '';
    if (code.isEmpty) {
      cancelAuthFlow(error: 'В ответе провайдера отсутствует код авторизации.');
      return false;
    }
    return _exchangeCodeForToken(code);
  }

  /// Обмен `authorization_code` + `code_verifier` (PKCE) на ключ Polza.
  Future<bool> _exchangeCodeForToken(String code) async {
    final pkce = _pendingPkce;
    final redirectUri = _pendingRedirectUri ?? 'gentech://auth/polza/callback';
    try {
      final response = await _dio.post<dynamic>(
        polzaTokenEndpoint,
        data: <String, dynamic>{
          'grant_type': 'authorization_code',
          'code': code,
          'code_verifier': pkce?.codeVerifier ?? '',
          'callback_url': redirectUri,
        },
        options: Options(
          headers: const <String, String>{
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final Object? rawBody = response.data;
      final String responseBody =
          rawBody is String ? rawBody : (rawBody?.toString() ?? '');
      Map<String, dynamic> data = <String, dynamic>{};
      try {
        final Object? decoded = jsonDecode(responseBody);
        if (decoded is Map) {
          data = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
      // Официальный ответ Polza: {"key": "pza_...", "user_id": "usr_..."}.
      final String key = (data['key'] ?? '').toString().trim();
      final String userId = (data['user_id'] ?? '').toString().trim();
      if (response.statusCode == 200 && key.isNotEmpty) {
        return _finalizeLogin(accessToken: key, userId: userId);
      }
      cancelAuthFlow(
        error: 'Не удалось обменять код авторизации на токен Polza AI.',
      );
      return false;
    } catch (_) {
      cancelAuthFlow(
        error: 'Сетевая ошибка при обмене кода PKCE на токен Polza AI.',
      );
      return false;
    }
  }

  /// Ручное завершение входа: ссылка редиректа, код авторизации либо ключ.
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
    if (_pendingPkce != null && !input.startsWith('sk-')) {
      return _exchangeCodeForToken(input);
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
    // Новый ключ pza_... применяется безусловно: settings.setConnection
    // перезаписывает settings.apiKey и settings.baseUrl свежими значениями,
    // а активный Polza-пресет обновляется тем же токеном.
    applyToSettings();
    await _updateActivePreset(accessToken);
    notifyListeners();
    unawaited(refreshAccountStatus());
    return true;
  }

  /// Обновляет активный пресет свежим OAuth-токеном Polza AI. Пресет
  /// считается «Polza-пресетом», если его baseUrl указывает на polza.ai;
  /// пресеты других провайдеров (RouterAI и т.п.) не затрагиваются.
  Future<void> _updateActivePreset(String token) async {
    try {
      final pr = presets.active;
      if (pr == null) return;
      if (!pr.baseUrl.trim().toLowerCase().contains('polza.ai')) return;
      pr.apiKey = token;
      pr.baseUrl = polzaBaseUrl;
      await presets.upsert(pr);
    } catch (_) {
      // Сбой хранилища не роняет вход: токен уже сохранён и применён.
    }
  }

  /// Жёстко прописывает URL, ключ Polza AI и дефолтную модель
  /// в активные настройки.
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

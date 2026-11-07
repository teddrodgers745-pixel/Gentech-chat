// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

  /// Криптостойкий `code_verifier` (48 случайных байта), `state` (16 байт)
  /// и `code_challenge = BASE64URL(SHA256(verifier))` (метод S256).
  static PkcePair generate() {
    final rnd = Random.secure();
    final verifierBytes = Uint8List.fromList(
      List<int>.generate(48, (_) => rnd.nextInt(256)),
    );
    final stateBytes = Uint8List.fromList(
      List<int>.generate(16, (_) => rnd.nextInt(256)),
    );
    final verifier = _b64u(verifierBytes);
    final state = _b64u(stateBytes);
    final challenge = _b64u(_Sha256.convert(ascii.encode(verifier)));
    return PkcePair(
      codeVerifier: verifier,
      codeChallenge: challenge,
      state: state,
    );
  }

  static String _b64u(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}

/// Защищённое хранилище OAuth-токенов Polza AI.
/// Токены хранятся отдельно от пресетов в обфусцированном конверте
/// с уникальной солью устройства и никогда не попадают в экспорт.
class SecureTokenStore {
  static const String _kAccessKey = 'polza_secure_access_token_v1';
  static const String _kRefreshKey = 'polza_secure_refresh_token_v1';
  static const String _kSaltKey = 'polza_secure_device_salt_v1';
  static const String _kAccountKey = 'polza_account_info_v1';

  Future<List<int>> _getOrCreateSalt() async {
    final existing = await storage.getString(_kSaltKey);
    if (existing != null && existing.isNotEmpty) {
      try {
        return base64.decode(existing);
      } catch (_) {}
    }
    final rnd = Random.secure();
    final salt = List<int>.generate(32, (_) => rnd.nextInt(256));
    await storage.setString(_kSaltKey, base64Encode(salt));
    return salt;
  }

  Future<String> _seal(String plain) async {
    if (plain.isEmpty) return '';
    final salt = await _getOrCreateSalt();
    final bytes = utf8.encode(plain);
    final out = Uint8List(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      out[i] = bytes[i] ^ salt[i % salt.length] ^ ((i * 31) & 0xFF);
    }
    return 'v1:${base64Url.encode(out)}';
  }

  Future<String?> _unseal(String? sealed) async {
    if (sealed == null || sealed.isEmpty) return null;
    if (!sealed.startsWith('v1:')) return null;
    try {
      final salt = await _getOrCreateSalt();
      final data = base64Url.decode(sealed.substring(3));
      final out = Uint8List(data.length);
      for (var i = 0; i < data.length; i++) {
        out[i] = data[i] ^ salt[i % salt.length] ^ ((i * 31) & 0xFF);
      }
      return utf8.decode(out);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveTokens({
    required String accessToken,
    String? refreshToken,
  }) async {
    await storage.setString(_kAccessKey, await _seal(accessToken));
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await storage.setString(_kRefreshKey, await _seal(refreshToken));
    }
  }

  Future<String?> readAccessToken() async =>
      _unseal(await storage.getString(_kAccessKey));

  Future<String?> readRefreshToken() async =>
      _unseal(await storage.getString(_kRefreshKey));

  Future<void> saveAccount(PolzaAccountInfo info) async {
    await storage.setString(_kAccountKey, jsonEncode(info.toJson()));
  }

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
    await storage.setString(_kRefreshKey, '');
    await storage.setString(_kAccountKey, '');
  }
}

/// Сервис авторизации через Polza AI по протоколу OAuth 2.0 PKCE.
///
/// Поток: генерация PKCE-пары -> локальный Loopback HTTP-сервер
/// (RFC 8252, 127.0.0.1:<порт>; фоллбэк — custom scheme) -> системный
/// браузер через url_launcher -> проверка state -> обмен кода на токен
/// -> сохранение в SecureTokenStore и применение к настройкам чата.
class PolzaAuthService extends ChangeNotifier {
  static const String polzaBaseUrl = 'https://api.polza.ai/api/v1';
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
  String? _refreshToken;
  PolzaAccountInfo? _account;
  String? _errorMessage;
  bool _loadingBalance = false;

  PkcePair? _pendingPkce;
  String? _pendingRedirectUri;
  HttpServer? _loopbackServer;
  Timer? _timeoutTimer;

  PolzaAuthStatus get status => _status;

  /// Токен доступа: используется EffectiveConfig и секциями настроек
  /// как ключ по умолчанию при активной сессии Polza AI.
  String get accessToken => _accessToken ?? '';

  bool get isAuthenticated =>
      _status == PolzaAuthStatus.authenticated &&
      (_accessToken != null && _accessToken!.isNotEmpty);
  bool get isAuthenticating => _status == PolzaAuthStatus.authenticating;
  bool get isLoadingBalance => _loadingBalance;
  PolzaAccountInfo? get account => _account;
  String? get errorMessage => _errorMessage;

  /// Refresh-токен: хранится для последующего обновления access-токена.
  String? get refreshToken => _refreshToken;

  /// Маскированное представление токена для безопасного показа в UI.
  String get maskedToken {
    final t = _accessToken ?? '';
    if (t.isEmpty) return '';
    if (t.length <= 10) return '••••••••';
    final prefix = t.substring(0, min(7, t.length));
    final suffix = t.substring(t.length - 4);
    return '$prefix••••$suffix';
  }

  /// Инициализация при старте приложения: токен и кэш профиля.
  Future<void> load() async {
    try {
      _accessToken = await _tokenStore.readAccessToken();
      _refreshToken = await _tokenStore.readRefreshToken();
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

  /// Запуск входа в один клик по OAuth 2.0 PKCE.
  Future<void> startOAuthPkceFlow() async {
    await _stopLoopbackServer();
    _errorMessage = null;
    _status = PolzaAuthStatus.authenticating;
    notifyListeners();

    final pkce = PkcePair.generate();
    _pendingPkce = pkce;

    // Loopback-сервер (RFC 8252) для перехвата редиректа; при недоступности
    // порта используем custom scheme gentech://auth/polza/callback.
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
        'app_name': appName,
        'response_type': 'code',
        'code_challenge': pkce.codeChallenge,
        'code_challenge_method': 'S256',
        'state': pkce.state,
        'callback_url': redirectUri,
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
            uri.queryParameters.containsKey('key') ||
            uri.queryParameters.containsKey('api_key')) {
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

    // Некоторые провайдеры возвращают готовый API-ключ прямо в callback.
    final directKey = params['key'] ?? params['api_key'] ?? params['token'];
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

  /// Обмен `authorization_code` + `code_verifier` (PKCE) на токен доступа.
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
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final data = response.data;
      if (response.statusCode == 200 && data is Map) {
        final token = (data['key'] ??
                data['access_token'] ??
                data['api_key'] ??
                data['token'] ??
                '')
            .toString()
            .trim();
        final refresh = (data['refresh_token'] ?? '').toString().trim();
        if (token.isNotEmpty) {
          final ok = await _finalizeLogin(
            accessToken: token,
            refreshToken: refresh.isEmpty ? null : refresh,
          );
          return ok;
        }
      }
      // Пользователь мог вставить непосредственно ключ вида sk-...
      if (code.startsWith('sk-') || code.length >= 28) {
        final ok = await _finalizeLogin(accessToken: code);
        return ok;
      }
      cancelAuthFlow(
        error: 'Не удалось обменять код авторизации на токен Polza AI.',
      );
      return false;
    } catch (_) {
      if (code.startsWith('sk-') || code.length >= 28) {
        return _finalizeLogin(accessToken: code);
      }
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

  Future<bool> _finalizeLogin({
    required String accessToken,
    String? refreshToken,
  }) async {
    _timeoutTimer?.cancel();
    _pendingPkce = null;
    await _stopLoopbackServer();

    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _status = PolzaAuthStatus.authenticated;
    _errorMessage = null;

    await _tokenStore.saveTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    applyToSettings();
    notifyListeners();
    await refreshAccountStatus();
    return true;
  }

  /// Применяет URL, ключ и дефолтную модель Polza AI к активным настройкам.
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

  /// Выход из аккаунта Polza AI с очисткой защищённого хранилища.
  Future<void> logout() async {
    _timeoutTimer?.cancel();
    _pendingPkce = null;
    await _stopLoopbackServer();
    final oldToken = _accessToken;
    _accessToken = null;
    _refreshToken = null;
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

/// Чистая Dart-реализация SHA-256 (FIPS 180-4) для `code_challenge`
/// метода S256 в PKCE — без внешних нативных зависимостей.
abstract final class _Sha256 {
  static const List<int> _k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0xab1c5ed5, 0x923f82a4,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  static int _rotr(int x, int n) =>
      (x >>> n) | ((x << (32 - n)) & 0xFFFFFFFF);

  static Uint8List convert(List<int> data) {
    var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
    var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;

    final bitLen = data.length * 8;
    final padded = <int>[...data, 0x80];
    while (padded.length % 64 != 56) {
      padded.add(0);
    }
    for (var i = 7; i >= 0; i--) {
      padded.add((bitLen >> (i * 8)) & 0xFF);
    }

    final w = List<int>.filled(64, 0);
    for (var chunk = 0; chunk < padded.length; chunk += 64) {
      for (var i = 0; i < 16; i++) {
        final j = chunk + i * 4;
        w[i] = ((padded[j] << 24) |
                (padded[j + 1] << 16) |
                (padded[j + 2] << 8) |
                padded[j + 3]) &
            0xFFFFFFFF;
      }
      for (var i = 16; i < 64; i++) {
        final m15 = w[i - 15];
        final s0 = _rotr(m15, 7) ^ _rotr(m15, 18) ^ (m15 >>> 3);
        final m2 = w[i - 2];
        final s1 = _rotr(m2, 17) ^ _rotr(m2, 19) ^ (m2 >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
      }

      var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
      for (var i = 0; i < 64; i++) {
        final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch = (e & f) ^ (~e & g);
        final temp1 = (h + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
        final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (s0 + maj) & 0xFFFFFFFF;
        h = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xFFFFFFFF;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xFFFFFFFF;
      }
      h0 = (h0 + a) & 0xFFFFFFFF;
      h1 = (h1 + b) & 0xFFFFFFFF;
      h2 = (h2 + c) & 0xFFFFFFFF;
      h3 = (h3 + d) & 0xFFFFFFFF;
      h4 = (h4 + e) & 0xFFFFFFFF;
      h5 = (h5 + f) & 0xFFFFFFFF;
      h6 = (h6 + g) & 0xFFFFFFFF;
      h7 = (h7 + h) & 0xFFFFFFFF;
    }

    final out = Uint8List(32);
    final words = <int>[h0, h1, h2, h3, h4, h5, h6, h7];
    for (var i = 0; i < 8; i++) {
      out[i * 4] = (words[i] >> 24) & 0xFF;
      out[i * 4 + 1] = (words[i] >> 16) & 0xFF;
      out[i * 4 + 2] = (words[i] >> 8) & 0xFF;
      out[i * 4 + 3] = words[i] & 0xFF;
    }
    return out;
  }
}

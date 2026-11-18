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
    // Стандартный SHA-256 (пакет crypto): BASE64URL(SHA256(verifier)),
    // паддинг '=' удаляется (RFC 7636, метод S256).
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes).bytes;
    final codeChallenge = base64Url.encode(digest).replaceAll('=', '');
    return PkcePair(
      codeVerifier: verifier,
      codeChallenge: codeChallenge,
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
  // Фикс 401: правильный хост — polza.ai (без 'api.' поддомена).
  // api.polza.ai отвечает редиректом на polza.ai, а dart:io HttpClient
  // при редиректе на другой хост автоматически вырезает заголовок
  // Authorization — запрос приходил без ключа и падал с 401.
  static const String polzaBaseUrl = 'https://polza.ai/api/v1';
  static const String polzaAuthEndpoint = 'https://polza.ai/api/auth/authorize';
  static const String polzaTokenEndpoint = 'https://polza.ai/api/auth/token';
  static const String polzaBillingUrl = 'https://polza.ai/dashboard/billing';
  static const String defaultModel = 'deepseek/deepseek-chat';

  /// Имя приложения, которое Polza ожидает в параметре app_name.
  static const String appName = 'GenTech Chat';

  /// PKCE (RFC 7636): допустимый формат code_verifier —
  /// 43-128 символов из [A-Za-z0-9-._~].
  static final RegExp _cvPattern = RegExp(r'^[A-Za-z0-9\-._~]{43,128}$');

  /// Префикс/суффикс code_verifier для debug-вывода
  /// ('ABCD1234...WXYZ9876'); короткие строки возвращаются целиком.
  static String _cvDebug(String cv) {
    if (cv.length <= 16) return cv;
    return '${cv.substring(0, 8)}...${cv.substring(cv.length - 8)}';
  }

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
      // Фикс 401: миграция старого Base URL. Ранние сборки сохраняли
      // в настройках 'https://api.polza.ai/api/v1' (redirect-хост);
      // переводим на рабочий 'https://polza.ai/api/v1', чтобы
      // providerCatalog и ручные пресеты ходили на правильный адрес.
      if (settings.baseUrl.trim() == 'https://api.polza.ai/api/v1') {
        settings.baseUrl = polzaBaseUrl;
        await settings.saveNow();
      }
      _accessToken = await _tokenStore.readAccessToken();
      _refreshToken = await _tokenStore.readRefreshToken();
      _account = await _tokenStore.readAccount();
      if (_accessToken != null && _accessToken!.isNotEmpty) {
        _status = PolzaAuthStatus.authenticated;
        // Фикс 401 (финал): при восстановлении сессии Base URL
        // принудительно переводится на рабочий https://polza.ai/api/v1 —
        // даже если в настройках остался старый адрес. Миграция должна
        // срабатывать всегда, а не только для конкретной старой строки:
        // запросы при активной сессии всё равно идут на polzaBaseUrl
        // (effectiveConfig), поэтому здесь важно лишь синхронизировать
        // настройки и каталог подключений.
        if (settings.baseUrl.trim() != polzaBaseUrl) {
          settings.baseUrl = polzaBaseUrl;
          await settings.saveNow();
        }
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

    // Диагностика PKCE (RFC 7636): code_verifier обязан быть 43-128
    // символов из [A-Za-z0-9-._~]. Он хранится ТОЛЬКО в памяти
    // (_pendingPkce) — шифрование (_seal) и хэширование к нему
    // НЕ применяются, иначе сервер получил бы не тот verifier.
    // Для отладки сохраняем первые/последние 8 символов verifier
    // (ключ polza_oauth_debug_cv) и проверяем формат.
    final String cv = pkce.codeVerifier;
    final bool cvOk = _cvPattern.hasMatch(cv);
    // Контроль: challenge = BASE64URL(SHA256(verifier)) без '=' на конце —
    // пересчитываем и сравниваем с сохранённым (защита от ошибок генерации).
    final bool challengeOk = pkce.codeChallenge ==
        PkcePair._b64u(sha256.convert(ascii.encode(cv)).bytes);
    debugPrint('[pkce] cv gen: len=${cv.length}, formatOk=$cvOk, '
        'challengeOk=$challengeOk, ${_cvDebug(cv)}');
    try {
      await storage.setString('polza_oauth_debug_cv', _cvDebug(cv));
      await storage.setString(
        'polza_oauth_debug_pkce_error',
        cvOk && challengeOk ? '' : 'cv_bad_format',
      );
    } catch (_) {}

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
        // prompt=login заставляет Polza всегда показывать форму входа:
        // без него браузер молча возвращает прежнюю сессию и «открывается
        // то же окно» вместо формы авторизации.
        'prompt': 'login',
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
    // Диагностика PKCE: code_verifier отправляется КАК ЕСТЬ из памяти
    // (_pendingPkce) — он не проходит через SecureTokenStore._seal и не
    // хэшируется перед отправкой. Для отладки сохраняем первые/последние
    // 8 символов отправленного verifier и сравниваем с сохранённым
    // при генерации: расхождение означает cv_mismatch.
    final String cvSent = pkce?.codeVerifier ?? '';
    try {
      await storage.setString(
        'polza_oauth_debug_cv_sent',
        _cvDebug(cvSent),
      );
      final genStored =
          await storage.getString('polza_oauth_debug_cv') ?? '';
      final bool match =
          genStored.isNotEmpty && genStored == _cvDebug(cvSent);
      await storage.setString(
        'polza_oauth_debug_pkce_match',
        match ? 'true' : 'false',
      );
      await storage.setString(
        'polza_oauth_debug_pkce_error',
        match ? '' : 'cv_mismatch',
      );
      debugPrint('[pkce] cv sent: len=${cvSent.length}, '
          'match=$match, ${_cvDebug(cvSent)}');
    } catch (_) {}
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
          // OAuth Debug: нужен СЫРОЙ текст ответа сервера, поэтому
          // Dio не декодирует JSON автоматически (ResponseType.plain).
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
      // Polza возвращает API-ключ в поле 'key' (pza_...), а не
      // 'access_token'. Поддержан fallback на access_token/api_key/token
      // на случай изменений провайдера. Refresh_token Polza не выдаёт:
      // он не парсится и не сохраняется.
      final String access = (data['key'] ??
              data['access_token'] ??
              data['api_key'] ??
              data['token'] ??
              '')
          .toString()
          .trim();
      // OAuth Debug (диагностика неверного токена): сырой ответ сервера
      // и извлечённый ключ сохраняются в SharedPreferences и показываются
      // в настройках Polza — пользователь может прислать скриншот.
      await storage.setString('polza_oauth_debug_raw', responseBody);
      await storage.setString('polza_oauth_debug_parsed', access);
      if (access.isEmpty || !access.startsWith('pza_')) {
        await storage.setString('polza_oauth_debug_error', 'key_not_pza');
      } else {
        await storage.setString('polza_oauth_debug_error', '');
      }
      if (response.statusCode == 200 && access.isNotEmpty) {
        final ok = await _finalizeLogin(accessToken: access);
        return ok;
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
    // Фикс 401 (финал): новый ключ pza_... применяется БЕЗУСЛОВНО.
    // applyToSettings -> settings.setConnection перезаписывает
    // settings.apiKey и settings.baseUrl свежими значениями, а активный
    // Polza-пресет дополнительно обновляется тем же токеном: иначе запросы
    // продолжали уходить со старым ключом из settings/preset и падали
    // с 401, хотя polzaAuth.accessToken уже был правильным.
    applyToSettings();
    await _updateActivePreset(accessToken);
    notifyListeners();
    await refreshAccountStatus();
    return true;
  }

  /// Фикс 401 (финал): обновляет активный пресет свежим OAuth-токеном
  /// Polza AI. Пресет считается «Polza-пресетом», если его baseUrl
  /// указывает на polza.ai (включая старый api.polza.ai): его apiKey
  /// и baseUrl перезаписываются принудительно, чтобы старый ключ не
  /// уходил в запросах. Пресеты других провайдеров (RouterAI и т.п.)
  /// не затрагиваются — их явные ключи должны продолжать работать.
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

  /// Применяет URL, ключ и дефолтную модель Polza AI к активным настройкам.
  ///
  /// Фикс 401 (финал): при успешном логине вызывается БЕЗУСЛОВНО —
  /// settings.setConnection перезаписывает settings.apiKey и settings.baseUrl
  /// свежим токеном pza_..., даже если там уже был сохранён старый ключ.
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



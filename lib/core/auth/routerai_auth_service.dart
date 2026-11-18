// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_state.dart';
import '../storage.dart';
import 'polza_auth_service.dart' show PkcePair;

/// Глобальный экземпляр сервиса авторизации RouterAI.
final RouterAiAuthService routerAiAuth = RouterAiAuthService();

/// Состояния процесса авторизации RouterAI.
enum RouterAiAuthStatus {
  unauthenticated,
  authenticating,
  authenticated,
  error,
}

/// Минимальные сведения об аккаунте RouterAI: OAuth отдаёт только ключ,
/// профиль хранит метку и время обновления.
class RouterAiAccountInfo {
  final String userId;
  final String label;
  final DateTime updatedAt;

  const RouterAiAccountInfo({
    this.userId = '',
    this.label = 'RouterAI Аккаунт',
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'userId': userId,
        'label': label,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory RouterAiAccountInfo.fromJson(Map<String, dynamic> json) {
    return RouterAiAccountInfo(
      userId: (json['userId'] ?? '').toString(),
      label: (json['label'] ?? 'RouterAI Аккаунт').toString(),
      updatedAt: DateTime.tryParse((json['updatedAt'] ?? '').toString()) ??
          DateTime.now(),
    );
  }
}

/// Хранилище OAuth-ключа RouterAI (ключ формата sk-...).
class RouterAiTokenStore {
  static const String _kAccessKey = 'routerai_secure_access_token_v1';
  static const String _kAccountKey = 'routerai_account_info_v1';

  Future<void> saveTokens({required String accessToken}) =>
      storage.setString(_kAccessKey, accessToken);

  /// Ключ валиден только в форме sk-...: прочее содержимое стирается.
  Future<String?> readAccessToken() async {
    final raw = await storage.getString(_kAccessKey);
    if (raw == null || raw.isEmpty) return null;
    if (!raw.startsWith('sk-')) {
      await storage.setString(_kAccessKey, '');
      return null;
    }
    return raw;
  }

  Future<void> saveAccount(RouterAiAccountInfo info) =>
      storage.setString(_kAccountKey, jsonEncode(info.toJson()));

  Future<RouterAiAccountInfo?> readAccount() async {
    final raw = await storage.getString(_kAccountKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return RouterAiAccountInfo.fromJson(
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

/// Сервис авторизации через RouterAI по OAuth 2.0 PKCE.
///
/// Архитектура повторяет PolzaAuthService: локальный loopback-сервер
/// перехватывает редирект браузера, PKCE-пара ([PkcePair]) защищает обмен
/// кода, сессии входа изолированы друг от друга. Отличия по документации
/// RouterAI: авторизация на /auth, обмен — POST /api/v1/auth/keys с телом
/// {"code", "code_verifier", "callback_url"} (БЕЗ grant_type), в ответе —
/// {"key": "sk-..."}.
class RouterAiAuthService extends ChangeNotifier {
  static const String routeraiBaseUrl = 'https://routerai.ru/api/v1';
  static const String routeraiAuthEndpoint = 'https://routerai.ru/auth';
  static const String routeraiTokenEndpoint =
      'https://routerai.ru/api/v1/auth/keys';
  static const String defaultModel = 'deepseek/deepseek-chat';

  /// Имя приложения, которое RouterAI ожидает в параметре app_name.
  static const String appName = 'GenTech Chat';

  /// Ключи OAuth-отладки; их читает RouterAiAuthSection.
  static const String debugRawKey = 'routerai_oauth_debug_raw';
  static const String debugParsedKey = 'routerai_oauth_debug_parsed';
  static const String debugErrorKey = 'routerai_oauth_debug_error';

  final RouterAiTokenStore _tokenStore = RouterAiTokenStore();
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  RouterAiAuthStatus _status = RouterAiAuthStatus.unauthenticated;
  String? _accessToken;
  RouterAiAccountInfo? _account;
  String? _errorMessage;

  PkcePair? _pendingPkce;
  String? _pendingRedirectUri;
  HttpServer? _loopbackServer;
  Timer? _timeoutTimer;
  bool _isExchanging = false;

  RouterAiAuthStatus get status => _status;

  String get accessToken => _accessToken ?? '';

  bool get isAuthenticated =>
      _status == RouterAiAuthStatus.authenticated &&
      (_accessToken != null && _accessToken!.isNotEmpty);
  bool get isAuthenticating => _status == RouterAiAuthStatus.authenticating;
  RouterAiAccountInfo? get account => _account;
  String? get errorMessage => _errorMessage;

  /// Маскированное представление ключа для показа в UI.
  String get maskedToken {
    final t = _accessToken ?? '';
    if (t.isEmpty) return '';
    if (t.length <= 10) return '••••••••';
    return '${t.substring(0, 7)}••••${t.substring(t.length - 4)}';
  }

  /// Алиас: запуск входа в один клик.
  Future<void> login() => startOAuthPkceFlow();

  /// Восстановление сессии при старте приложения.
  Future<void> load() async {
    try {
      _accessToken = await _tokenStore.readAccessToken();
      _account = await _tokenStore.readAccount();
      if (_accessToken != null && _accessToken!.isNotEmpty) {
        _status = RouterAiAuthStatus.authenticated;
        if (settings.apiKey.trim().isEmpty) applyToSettings();
        notifyListeners();
      }
    } catch (_) {
      _status = RouterAiAuthStatus.unauthenticated;
    }
  }

  /// Запуск входа: поднимаем loopback-сервер и открываем страницу
  /// авторизации RouterAI в системном браузере.
  Future<void> startOAuthPkceFlow() async {
    if (_accessToken != null && _accessToken!.isNotEmpty) {
      _status = RouterAiAuthStatus.authenticated;
      _errorMessage = null;
      notifyListeners();
      return;
    }

    await _stopLoopbackServer();
    _isExchanging = false;
    _errorMessage = null;
    _status = RouterAiAuthStatus.authenticating;
    notifyListeners();

    final pkce = PkcePair.generate();
    _pendingPkce = pkce;

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
    final redirectUri =
        'http://127.0.0.1:${server.port}/auth/routerai/callback';
    _pendingRedirectUri = redirectUri;

    // PKCE и callback_url передаются в слушатель локально: исключает
    // рассинхрон между сессиями входа.
    unawaited(_listenLoopback(server, pkce, redirectUri));

    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(minutes: 5), () {
      if (_status == RouterAiAuthStatus.authenticating) {
        cancelAuthFlow(
          error: 'Время ожидания входа в браузере истекло. Попробуйте снова.',
        );
      }
    });

    // Параметры авторизации — ровно по документации RouterAI.
    final authUri = Uri.parse(routeraiAuthEndpoint).replace(
      queryParameters: <String, String>{
        'callback_url': redirectUri,
        'code_challenge': pkce.codeChallenge,
        'code_challenge_method': 'S256',
        'state': pkce.state,
        'app_name': appName,
      },
    );

    debugPrint('[RouterAiAuth] Opening authorize URL: $authUri');

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

  Future<void> _listenLoopback(
    HttpServer server,
    PkcePair sessionPkce,
    String sessionRedirectUri,
  ) async {
    try {
      await for (final HttpRequest request in server) {
        final uri = request.uri;

        // Игнорируем запросы иконок и preflight-запросы браузера.
        if (request.method == 'OPTIONS' || uri.path.contains('favicon')) {
          request.response.statusCode = HttpStatus.noContent;
          await request.response.close();
          continue;
        }

        final hasAuthParams = uri.queryParameters.containsKey('code') ||
            uri.queryParameters.containsKey('error') ||
            uri.queryParameters.containsKey('key') ||
            uri.queryParameters.containsKey('api_key');

        if (!hasAuthParams) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          continue;
        }

        // Страница успешного завершения в браузер.
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        request.response.write(_callbackHtml);
        await request.response.close();

        // Гарантируем, что при обмене используются именно те PKCE и
        // callback_url, для которых был поднят этот сервер.
        _pendingPkce = sessionPkce;
        _pendingRedirectUri = sessionRedirectUri;

        await handleCallbackUri(uri);
        break;
      }
    } catch (_) {
      // Сервер закрыт либо соединение оборвано — не критично.
    } finally {
      if (_loopbackServer == server) {
        await _stopLoopbackServer();
      } else {
        try {
          await server.close(force: true);
        } catch (_) {}
      }
    }
  }

  static const String _callbackHtml = '''
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>GenTech Chat — RouterAI</title>
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
    <p>Аккаунт RouterAI подключён к GenTech Chat. Можно закрыть вкладку
       и вернуться в приложение.</p>
  </div>
</body>
</html>
''';

  /// Обрабатывает редирект от провайдера.
  Future<bool> handleCallbackUri(Uri uri) async {
    if (_isExchanging) return false;

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
    if (directKey != null && directKey.trim().startsWith('sk-')) {
      return _finalizeLogin(accessToken: directKey.trim());
    }

    final code = params['code']?.trim() ?? '';
    if (code.isEmpty) {
      cancelAuthFlow(error: 'В ответе провайдера отсутствует код авторизации.');
      return false;
    }

    return _exchangeCodeForToken(code);
  }

  /// Обмен authorization_code + code_verifier (PKCE) на ключ RouterAI.
  /// Тело — ровно по документации: {"code", "code_verifier",
  /// "callback_url"} без grant_type; ответ: {"key": "sk-..."}.
  Future<bool> _exchangeCodeForToken(String code) async {
    if (_isExchanging) return false;
    _isExchanging = true;

    final pkce = _pendingPkce;
    final callbackUrl = _pendingRedirectUri ?? '';
    final codeVerifier = pkce?.codeVerifier ?? '';

    debugPrint(
      '[RouterAiAuth] Exchanging code. callback_url: $callbackUrl, '
      'code_verifier length: ${codeVerifier.length}',
    );

    if (callbackUrl.isEmpty || codeVerifier.isEmpty) {
      _isExchanging = false;
      cancelAuthFlow(error: 'PKCE-сессия истекла. Запустите вход заново.');
      return false;
    }

    final payload = <String, dynamic>{
      'code': code,
      'code_verifier': codeVerifier,
      'callback_url': callbackUrl,
    };

    try {
      // 1. Основной запрос в формате JSON (документация RouterAI).
      final response = await _dio.post<String>(
        routeraiTokenEndpoint,
        data: jsonEncode(payload),
        options: Options(
          headers: const <String, String>{
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );

      var body = response.data ?? '';
      var status = response.statusCode ?? 0;

      // 2. Fallback: если сервер жалуется на формат/redirect_uri —
      // повторяем x-www-form-urlencoded с теми же тремя полями.
      if (status == 400 &&
          (body.contains('redirect_uri') ||
              body.contains('invalid_request'))) {
        debugPrint(
            '[RouterAiAuth] Retrying token exchange with form-urlencoded...');
        final retryRes = await _dio.post<String>(
          routeraiTokenEndpoint,
          data: <String, String>{
            'code': code,
            'code_verifier': codeVerifier,
            'callback_url': callbackUrl,
          },
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            headers: const <String, String>{'Accept': 'application/json'},
            responseType: ResponseType.plain,
            validateStatus: (_) => true,
          ),
        );
        if ((retryRes.statusCode ?? 0) >= 200 &&
            (retryRes.statusCode ?? 0) < 300) {
          body = retryRes.data ?? '';
          status = retryRes.statusCode ?? 0;
        }
      }

      debugPrint('[RouterAiAuth] /auth/keys -> HTTP $status: '
          '${body.length > 500 ? '${body.substring(0, 500)}…' : body}');

      if (status >= 200 && status < 300) {
        Map<String, dynamic> data = <String, dynamic>{};
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map) {
            data = Map<String, dynamic>.from(decoded);
            // Ключ может лежать в data['data'] (обёртка ответа).
            if (data['data'] is Map) {
              data = Map<String, dynamic>.from(data['data'] as Map);
            }
          }
        } catch (_) {}

        // Документация RouterAI: ключ приходит в поле 'key' (sk-...).
        final key =
            (data['key'] ?? data['api_key'] ?? '').toString().trim();
        final userId =
            (data['user_id'] ?? data['id'] ?? '').toString().trim();

        if (key.startsWith('sk-')) {
          await _saveDebug(raw: body, parsed: key, error: '');
          _isExchanging = false;
          return _finalizeLogin(accessToken: key, userId: userId);
        }

        await _saveDebug(raw: body, parsed: key, error: 'HTTP $status');
        _isExchanging = false;
        cancelAuthFlow(
          error: 'Сервер RouterAI вернул ответ без ключа sk-. '
              'HTTP $status: ${_clip(body)}',
        );
        return false;
      }

      await _saveDebug(raw: body, parsed: '', error: 'HTTP $status');
      _isExchanging = false;
      cancelAuthFlow(
        error: 'Не удалось обменять код авторизации на ключ RouterAI. '
            'HTTP $status: ${_clip(body)}',
      );
      return false;
    } catch (e) {
      _isExchanging = false;
      await _saveDebug(raw: e.toString(), parsed: '', error: 'network');
      cancelAuthFlow(
        error: 'Сетевая ошибка при обмене кода PKCE на ключ RouterAI: $e',
      );
      return false;
    }
  }

  /// Обрезка сырого тела для сообщения об ошибке (читаемость в UI).
  static String _clip(String raw) {
    final t = raw.replaceAll('\n', ' ').trim();
    return t.length > 800 ? '${t.substring(0, 800)}…' : t;
  }

  /// Запись OAuth-отладки в хранилище (её читает RouterAiAuthSection).
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
    _status = RouterAiAuthStatus.authenticating;
    notifyListeners();

    if (input.startsWith('http://') ||
        input.startsWith('https://') ||
        input.startsWith('gentech://')) {
      final uri = Uri.tryParse(input);
      if (uri != null) {
        // Пользователь вставил полный callback URL вручную: базовый
        // callback_url совпадает с тем, куда редиректнул сервер.
        _pendingRedirectUri ??=
            '${uri.scheme}://${uri.authority}${uri.path}';
        return handleCallbackUri(uri);
      }
    }
    if (!input.startsWith('sk-') && _pendingPkce != null) {
      return _exchangeCodeForToken(input);
    }
    if (!input.startsWith('sk-')) {
      cancelAuthFlow(error: 'Ключ RouterAI должен начинаться с sk-.');
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
    _isExchanging = false;
    await _stopLoopbackServer();

    _accessToken = accessToken;
    _status = RouterAiAuthStatus.authenticated;
    _errorMessage = null;

    _account = RouterAiAccountInfo(
      userId: userId.isNotEmpty ? userId : (_account?.userId ?? ''),
      label: _account?.label ?? 'RouterAI Аккаунт',
      updatedAt: DateTime.now(),
    );

    await _tokenStore.saveTokens(accessToken: accessToken);
    await _tokenStore.saveAccount(_account!);
    applyToSettings();
    await _updateActivePreset(accessToken);
    notifyListeners();
    return true;
  }

  /// Обновляет активный пресет свежим OAuth-ключом RouterAI (если пресет
  /// относится к этому провайдеру).
  Future<void> _updateActivePreset(String token) async {
    try {
      final pr = presets.active;
      if (pr == null) return;
      if (!pr.baseUrl.trim().toLowerCase().contains('routerai.ru')) return;
      pr.apiKey = token;
      pr.baseUrl = routeraiBaseUrl;
      await presets.upsert(pr);
    } catch (_) {}
  }

  /// Прописывает URL, ключ RouterAI и модель в активные настройки.
  void applyToSettings() {
    final token = _accessToken;
    if (token == null || token.isEmpty) return;
    final currentModel = settings.model.trim();
    settings.setConnection(
      url: routeraiBaseUrl,
      key: token,
      mdl: currentModel.isEmpty ? defaultModel : currentModel,
    );
  }

  /// Отмена текущего ожидания авторизации.
  void cancelAuthFlow({String? error}) {
    _timeoutTimer?.cancel();
    _pendingPkce = null;
    _pendingRedirectUri = null;
    _isExchanging = false;
    unawaited(_stopLoopbackServer());
    _errorMessage = error;
    _status = error != null
        ? RouterAiAuthStatus.error
        : (_accessToken != null && _accessToken!.isNotEmpty
            ? RouterAiAuthStatus.authenticated
            : RouterAiAuthStatus.unauthenticated);
    notifyListeners();
  }

  /// Выход из аккаунта RouterAI с очисткой хранилища.
  Future<void> logout() async {
    _timeoutTimer?.cancel();
    _pendingPkce = null;
    _pendingRedirectUri = null;
    _isExchanging = false;
    await _stopLoopbackServer();

    final oldToken = _accessToken;
    _accessToken = null;
    _account = null;
    _errorMessage = null;
    _status = RouterAiAuthStatus.unauthenticated;
    await _tokenStore.clear();

    // Если в настройках лежал именно этот RouterAI-ключ — убираем его,
    // чтобы запросы не уходили с протухшим ключом.
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

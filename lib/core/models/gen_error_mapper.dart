// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../services/chat_service.dart' show ChatServiceException;
import 'gen_error.dart';

/// Преобразует любые исключения генерации в типизированный [GenError]:
///  - 401/403 -> AuthError;
///  - 402 -> InsufficientFunds;
///  - 429 -> RateLimited;
///  - 400/422 с признаками фильтра контента -> ContentFiltered,
///    иначе BadRequestError;
///  - 404 -> ModelNotFoundError;
///  - 5xx -> ServerError;
///  - таймауты -> JobTimeout;
///  - сетевые сбои -> NetworkError;
///  - остальное -> UnknownGenError.
///
/// Текст ошибки безопасно извлекается из JSON-ответа провайдера
/// (error.message / message / detail); битый JSON не роняет разбор.
abstract final class GenErrorMapper {
  /// Подстроки, по которым 400/422 распознаётся как фильтр контента.
  static const List<String> _safetyHints = <String>[
    'safety',
    'content_filter',
    'content filtering',
    'content_policy',
    'content policy',
    'moderation',
    'filtered',
    'flagged',
  ];

  /// Подстроки таймаута в текстовых сообщениях.
  static const List<String> _timeoutHints = <String>[
    'timeout',
    'timed out',
    'таймаут',
    'не ответил',
  ];

  /// Главная точка входа: любое исключение -> [GenError].
  static GenError fromException(Object error) {
    if (error is GenError) return error;
    if (error is DioException) return _fromDio(error);
    if (error is ChatServiceException) return _fromText(error.message);
    if (error is TimeoutException) {
      return const JobTimeout(details: 'Превышено время ожидания ответа.');
    }
    if (error is SocketException) {
      return NetworkError(details: _clip(error.message));
    }
    if (error is HttpException) {
      return NetworkError(details: _clip(error.message));
    }
    return UnknownGenError(details: _clip(error.toString()));
  }

  /// Разбор DioException: таймауты, HTTP-статус из badResponse, сеть.
  static GenError _fromDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const JobTimeout(details: 'Провайдер не ответил вовремя.');
      case DioExceptionType.badResponse:
        final status = e.response?.statusCode ?? 0;
        return _fromStatusCode(status, e.response?.data);
      case DioExceptionType.cancel:
        return const NetworkError(details: 'Запрос отменён.');
      case DioExceptionType.badCertificate:
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return NetworkError(details: _clip(e.message ?? 'Ошибка соединения.'));
      default:
        // Прочие типы Dio (в т.ч. добавленные в новых версиях пакета)
        // трактуем как сбой соединения — безопасное значение по умолчанию.
        return NetworkError(details: _clip(e.message ?? 'Ошибка соединения.'));
    }
  }

  /// Код HTTP-ответа + тело -> [GenError]. Тело может быть строкой JSON,
  /// готовым Map или чем угодно ещё — разбор безопасен.
  static GenError _fromStatusCode(int code, Object? body) {
    final details = _detailsFromBody(body);
    switch (code) {
      case 401:
      case 403:
        return AuthError(details: details);
      case 402:
        return InsufficientFunds(details: details);
      case 429:
        return RateLimited(details: details);
      case 404:
        return ModelNotFoundError(details: details);
      case 400:
      case 422:
        return _looksLikeSafety(details)
            ? ContentFiltered(details: details)
            : BadRequestError(details: details);
    }
    if (code >= 500) return ServerError(statusCode: code, details: details);
    return UnknownGenError(details: 'Ошибка $code. ${_clip(details)}');
  }

  /// Разбор текста ошибки: ChatServiceException уже содержит код ответа
  /// провайдера в сообщении ('Неверный API-ключ (401)...').
  static GenError _fromText(String message) {
    final m = message.trim();
    if (m.contains('401') || m.contains('403')) return AuthError(details: m);
    if (m.contains('402')) return InsufficientFunds(details: m);
    if (m.contains('429')) return RateLimited(details: m);
    if (m.contains('404')) return ModelNotFoundError(details: m);
    if (m.contains('400') || m.contains('422')) {
      return _looksLikeSafety(m)
          ? ContentFiltered(details: m)
          : BadRequestError(details: m);
    }
    if (RegExp(r'\b5\d{2}\b').hasMatch(m)) return ServerError(details: m);
    if (_looksLikeTimeout(m)) return JobTimeout(details: m);
    return UnknownGenError(details: m);
  }

  static bool _looksLikeSafety(String text) {
    final lower = text.toLowerCase();
    for (final h in _safetyHints) {
      if (lower.contains(h)) return true;
    }
    return false;
  }

  static bool _looksLikeTimeout(String text) {
    final lower = text.toLowerCase();
    for (final h in _timeoutHints) {
      if (lower.contains(h)) return true;
    }
    return false;
  }

  /// Безопасное извлечение текста ошибки из тела ответа.
  /// Порядок: error.message -> error (строка) -> message -> detail ->
  /// сырой текст (обрезается до 300 символов).
  static String _detailsFromBody(Object? body) {
    if (body == null) return '';
    Object? json = body;
    if (body is String) {
      try {
        json = jsonDecode(body);
      } catch (_) {
        return _clip(body);
      }
    }
    if (json is Map) {
      final error = json['error'];
      if (error is Map) {
        final m = error['message'];
        if (m is String && m.trim().isNotEmpty) return _clip(m);
      }
      if (error is String && error.trim().isNotEmpty) return _clip(error);
      final m = json['message'];
      if (m is String && m.trim().isNotEmpty) return _clip(m);
      final detail = json['detail'];
      if (detail is String && detail.trim().isNotEmpty) return _clip(detail);
    }
    return _clip(body.toString());
  }

  static String _clip(String s) {
    final t = s.trim();
    return t.length > 300 ? t.substring(0, 300) : t;
  }

  /// Сырые детали из любого [GenError] (для сохранения в ChatMessage).
  static String detailsOf(GenError e) => switch (e) {
        AuthError(:final details) => details,
        InsufficientFunds(:final details) => details,
        RateLimited(:final details) => details,
        ModelNotFoundError(:final details) => details,
        ServerError(:final details) => details,
        ContentFiltered(:final details) => details,
        JobTimeout(:final details) => details,
        NetworkError(:final details) => details,
        BadRequestError(:final details) => details,
        UnknownGenError(:final details) => details,
      };

  /// Восстановление [GenError] по сохранённому коду (ChatMessage.errorCode),
  /// чтобы ошибка корректно отображалась после перезапуска приложения.
  static GenError fromCode(String code, {String details = ''}) {
    switch (code) {
      case 'auth':
        return AuthError(details: details);
      case 'funds':
        return InsufficientFunds(details: details);
      case 'rate_limit':
        return RateLimited(details: details);
      case 'model_not_found':
        return ModelNotFoundError(details: details);
      case 'server':
        return ServerError(details: details);
      case 'content_filtered':
        return ContentFiltered(details: details);
      case 'timeout':
        return JobTimeout(details: details);
      case 'network':
        return NetworkError(details: details);
      case 'bad_request':
        return BadRequestError(details: details);
      default:
        return UnknownGenError(details: details);
    }
  }
}

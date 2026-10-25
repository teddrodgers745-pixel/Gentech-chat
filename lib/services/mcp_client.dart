// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app_state.dart';
import '../models/mcp_server.dart';
import '../models/tool.dart';

/// Ошибка MCP-клиента с готовым понятным сообщением для пользователя.
class McpClientException implements Exception {
  final String message;
  McpClientException(this.message);

  @override
  String toString() => message;
}

/// Клиент MCP-сервера: запрашивает список инструментов по JSON-RPC 2.0
/// (метод tools/list) и превращает ответ в объекты [Tool].
class McpClient {
  static const Duration _timeout = Duration(seconds: 30);

  /// POST на адрес сервера с телом {'jsonrpc':'2.0','method':'tools/list','id':1}.
  /// Если у сервера задан токен — отправляется заголовок Authorization: Bearer.
  Future<List<Tool>> fetchTools(McpServer server) async {
    final url = server.url.trim();
    if (url.isEmpty) {
      throw McpClientException('У сервера не указан URL.');
    }
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw McpClientException('URL должен начинаться с http:// или https://.');
    }

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final token = server.token.trim();
    if (token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }

    final client = http.Client();
    try {
      final resp = await client
          .post(
            uri,
            headers: headers,
            body: jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'tools/list',
              'id': 1,
            }),
          )
          .timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw McpClientException(
          'Ошибка HTTP ${resp.statusCode}. Проверьте адрес и токен сервера.',
        );
      }
      return _parse(resp.body);
    } on McpClientException {
      rethrow;
    } on TimeoutException {
      throw McpClientException('Сервер не ответил за 30 секунд.');
    } catch (_) {
      throw McpClientException(
        'Не удалось соединиться с сервером. Проверьте адрес и сеть.',
      );
    } finally {
      client.close();
    }
  }

  /// Разбор ответа: извлекаем массив 'tools' из поля 'result'.
  List<Tool> _parse(String body) {
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw McpClientException('Сервер вернул не JSON.');
    }
    if (decoded is! Map) {
      throw McpClientException('Неверный формат ответа сервера.');
    }
    final map = Map<String, dynamic>.from(decoded);

    final err = map['error'];
    if (err is Map) {
      final msg = err['message'];
      throw McpClientException(
        'Ошибка сервера: ${msg is String && msg.trim().isNotEmpty ? msg : 'неизвестная ошибка'}',
      );
    }

    final result = map['result'];
    if (result is! Map) {
      throw McpClientException('В ответе нет результата tools/list.');
    }
    final res = Map<String, dynamic>.from(result);
    final rawTools = res['tools'];
    if (rawTools is! List) {
      throw McpClientException('Сервер не вернул список инструментов.');
    }

    final out = <Tool>[];
    for (final item in rawTools) {
      if (item is! Map) continue;
      final name = ((item['name'] as String?) ?? '').trim();
      if (name.isEmpty) continue;
      final schema = item['inputSchema'];
      out.add(Tool(
        id: newId(),
        name: name,
        description: ((item['description'] as String?) ?? '').trim(),
        parametersSchema: schema == null ? '' : jsonEncode(schema),
      ));
    }
    return out;
  }
}

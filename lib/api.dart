import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class StreamChunk {
  final String content;
  final String reasoning;
  const StreamChunk(this.content, this.reasoning);
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}

class ChatApi {
  http.Client? _client;
  bool wasCancelled = false;

  void cancel() {
    if (_client != null) {
      wasCancelled = true;
      _client!.close();
      _client = null;
    }
  }

  Stream<StreamChunk> stream({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, String>> messages,
  }) async* {
    wasCancelled = false;
    final client = http.Client();
    _client = client;
    try {
      final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$base/chat/completions');
      final req = http.Request('POST', uri);
      req.headers.addAll({
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
        'Accept': 'text/event-stream',
      });
      req.body = jsonEncode({
        'model': model,
        'messages': messages,
        'stream': true,
      });

      final resp = await client.send(req).timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) {
        final body = await resp.stream.bytesToString();
        throw ApiException(_describe(resp.statusCode, body));
      }

      final lines =
          resp.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final choices = json['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;
          final delta = (choices[0] as Map)['delta'] as Map?;
          if (delta == null) continue;
          final c = (delta['content'] as String?) ?? '';
          final r = (delta['reasoning_content'] as String?) ?? '';
          if (c.isNotEmpty || r.isNotEmpty) yield StreamChunk(c, r);
        } catch (_) {
          // Битая строка потока: пропускаем.
        }
      }
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  String _describe(int code, String body) {
    switch (code) {
      case 401:
        return 'Неверный API-ключ (401). Проверьте его в настройках.';
      case 402:
        return 'Недостаточно средств на балансе (402).';
      case 429:
        return 'Слишком много запросов (429). Подождите немного.';
    }
    return 'Ошибка $code: ${_extractError(body)}';
  }

  String _extractError(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is Map) {
        final m = (j['error'] as Map)['message'];
        if (m != null) return m.toString();
      }
      if (j is Map && j['message'] != null) return j['message'].toString();
    } catch (_) {}
    return body.length > 300 ? body.substring(0, 300) : body;
  }
}

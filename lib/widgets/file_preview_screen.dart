// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app_state.dart';
import '../theme.dart';

/// Тип предпросмотра, определяемый по расширению имени файла.
enum PreviewKind { web, image, text }

PreviewKind previewKindFor(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final ext = dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
  switch (ext) {
    case 'html':
    case 'htm':
    case 'svg':
      return PreviewKind.web;
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'gif':
    case 'webp':
    case 'bmp':
      return PreviewKind.image;
    default:
      return PreviewKind.text;
  }
}

/// Язык подсветки для текстового предпросмотра (как в чате).
String highlightLanguageFor(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final ext = dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
  const map = <String, String>{
    'py': 'python',
    'js': 'javascript',
    'ts': 'typescript',
    'json': 'json',
    'dart': 'dart',
    'md': 'markdown',
    'yml': 'yaml',
    'yaml': 'yaml',
    'css': 'css',
    'java': 'java',
    'kt': 'kotlin',
    'kts': 'kotlin',
    'go': 'go',
    'rs': 'rust',
    'c': 'c',
    'cpp': 'cpp',
    'cc': 'cpp',
    'h': 'cpp',
    'sh': 'bash',
    'bash': 'bash',
    'sql': 'sql',
    'php': 'php',
    'rb': 'ruby',
    'swift': 'swift',
    'xml': 'xml',
    'cs': 'cs',
  };
  return map[ext] ?? 'plaintext';
}

/// HTML-документ из SVG-кода: центрирование на белом фоне,
/// чтобы прозрачный фон SVG был виден корректно.
String wrapSvgDocument(String svg) {
  return '<!DOCTYPE html><html><head>'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '</head><body style="margin:0;display:flex;align-items:center;'
      'justify-content:center;min-height:100vh;background:#ffffff;">'
      '$svg</body></html>';
}

/// Готовит HTML из строки: добавляет viewport, если его нет,
/// чтобы страница выглядела корректно на телефоне.
String prepareHtmlDocument(String code) {
  final src = code.trim();
  if (src.contains('name="viewport"')) return src;
  final headRe = RegExp(r'<head[^>]*>', caseSensitive: false);
  if (headRe.hasMatch(src)) {
    return src.replaceFirst(
      headRe,
      '<head><meta name="viewport" content="width=device-width, initial-scale=1">',
    );
  }
  return '<!DOCTYPE html><html><head>'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '</head><body style="margin:0">$src</body></html>';
}

/// Полноэкранный предпросмотр файла: WebView (html/svg),
/// изображение (base64/data URI) либо текст с подсветкой синтаксиса.
class FilePreviewScreen extends StatelessWidget {
  final String fileName;
  final String code;
  final String lang;

  const FilePreviewScreen({
    super.key,
    required this.fileName,
    required this.code,
    this.lang = '',
  });

  @override
  Widget build(BuildContext context) {
    final kind = previewKindFor(fileName);
    return Scaffold(
      appBar: AppBar(
        title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (kind == PreviewKind.text)
            IconButton(
              tooltip: 'Копировать',
              icon: const Icon(Icons.copy_rounded),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Скопировано'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: settings,
          builder: (context, _) {
            switch (kind) {
              case PreviewKind.web:
                return _WebViewPreview(
                  code: code,
                  isSvg: fileName.toLowerCase().endsWith('.svg'),
                );
              case PreviewKind.image:
                return _ImagePreview(code: code);
              case PreviewKind.text:
                return _TextPreview(
                  code: code,
                  lang: highlightLanguageFor(fileName),
                );
            }
          },
        ),
      ),
    );
  }
}

/// WebView-предпросмотр: локальный HTML из строки, без доступа в сеть.
class _WebViewPreview extends StatefulWidget {
  final String code;
  final bool isSvg;

  const _WebViewPreview({required this.code, required this.isSvg});

  @override
  State<_WebViewPreview> createState() => _WebViewPreviewState();
}

class _WebViewPreviewState extends State<_WebViewPreview> {
  WebViewController? _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final html = widget.isSvg
          ? wrapSvgDocument(widget.code)
          : prepareHtmlDocument(widget.code);
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFFFFFFFF))
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) {
              // Разрешаем только локальную загрузку: переходы в интернет
              // из предпросмотра блокируем.
              if (request.url.startsWith('http://') ||
                  request.url.startsWith('https://')) {
                return NavigationDecision.prevent;
              }
              return NavigationDecision.navigate;
            },
          ),
        );
      _controller = controller;
      await controller
          .loadHtmlString(html)
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить предпросмотр.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || _error != null) {
      return _PreviewFallback(
        message: _error ?? 'Не удалось загрузить предпросмотр.',
      );
    }
    return Stack(
      children: [
        WebViewWidget(controller: controller),
        if (_loading)
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ],
    );
  }
}

/// Полноэкранный просмотр картинки: код файла как base64 либо data URI.
class _ImagePreview extends StatelessWidget {
  final String code;

  const _ImagePreview({required this.code});

  @override
  Widget build(BuildContext context) {
    Uint8List? bytes;
    try {
      var s = code.trim();
      final m = RegExp(r'data:image/[^;,]+;base64,([\s\S]*)').firstMatch(s);
      if (m != null) s = m.group(1)!;
      s = s.replaceAll(RegExp(r'\s'), '');
      if (s.isNotEmpty) bytes = base64Decode(s);
    } catch (_) {
      bytes = null;
    }
    if (bytes == null || bytes.isEmpty) {
      return const _PreviewFallback(message: 'Не удалось отобразить изображение.');
    }
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        return ColoredBox(
          color: p.bg,
          child: InteractiveViewer(
            maxScale: 8,
            child: Center(
              child: Image.memory(
                bytes!,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const _PreviewFallback(
                  message: 'Не удалось отобразить изображение.',
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Текстовый предпросмотр с подсветкой, как блоки кода в чате.
class _TextPreview extends StatelessWidget {
  final String code;
  final String lang;

  const _TextPreview({required this.code, required this.lang});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final base = p.isDark ? atomOneDarkTheme : githubTheme;
        final theme = Map<String, TextStyle>.from(base);
        theme['root'] = (base['root'] ?? const TextStyle())
            .copyWith(backgroundColor: Colors.transparent);
        return ColoredBox(
          color: p.bg,
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(16),
              child: HighlightView(
                code,
                language: lang,
                theme: theme,
                textStyle: fontStyle(
                  settings.codeFont,
                  size: 14,
                  color: p.text,
                  height: 1.5,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Заглушка, когда содержимое отобразить не удалось.
class _PreviewFallback extends StatelessWidget {
  final String message;

  const _PreviewFallback({required this.message});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        return ColoredBox(
          color: p.bg,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: p.muted, fontSize: 14),
              ),
            ),
          ),
        );
      },
    );
  }
}

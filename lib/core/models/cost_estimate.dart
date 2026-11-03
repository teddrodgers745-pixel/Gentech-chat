// Copyright (c) 2026 Minkail. All rights reserved.

import '../providers/heuristic_rules.dart';
import 'model_info.dart';

/// Оценка стоимости одного запроса к модели.
///
/// [estimatedUsd] — предварительная цена в USD (null — оценить не удалось);
/// [unitLabel] — за что насчитана цена ('за изображение', 'за секунду видео',
/// 'за запрос'); [formatted] — готовая строка для интерфейса.
class CostEstimate {
  final double? estimatedUsd;
  final String unitLabel;
  final bool isKnown;
  final String formatted;

  const CostEstimate({
    required this.estimatedUsd,
    required this.unitLabel,
    required this.isKnown,
    required this.formatted,
  });

  /// Оценка неизвестна: бейдж стоимости не показывается.
  static const CostEstimate unknown = CostEstimate(
    estimatedUsd: null,
    unitLabel: '',
    isKnown: false,
    formatted: '',
  );
}

/// Оценщик стоимости запроса по идентификатору модели.
///
/// Семейства генерации изображений и видео имеют фиксированные цены
/// (за изображение и за секунду видео); для текстовых моделей стоимость
/// считается по токенам из [Pricing] каталога, когда он известен
/// (~4 символа на токен, объём ответа принят равным объёму запроса).
abstract final class CostEstimator {
  static const String _usd = r'$';

  static const double _fluxSchnellImage = 0.003;
  static const double _fluxDevImage = 0.025;

  /// flux-pro и dall-e-3 — одна ценовая категория.
  static const double _proImage = 0.04;

  static const double _wanVideoSecond = 0.04;
  static const double _klingVideoSecond = 0.07;
  static const double _soraVideoSecond = 0.10;

  /// Оценка стоимости запроса. [pricing] — цены каталога провайдера,
  /// если они загружены; для изображений и видео он не требуется.
  static CostEstimate estimate({
    required String modelId,
    String prompt = '',
    Pricing? pricing,
  }) {
    final id = HeuristicRules.normalize(modelId);
    if (id.isEmpty) return CostEstimate.unknown;

    final image = _imageEstimate(id);
    if (image != null) return image;

    final video = _videoEstimate(id);
    if (video != null) return video;

    return _textEstimate(prompt, pricing);
  }

  /// Цена генерации одного изображения для известных семейств.
  static CostEstimate? _imageEstimate(String id) {
    if (HeuristicRules.inferRoute(id) != GenerationRoute.imageGeneration) {
      return null;
    }
    final double price;
    if (id.contains('flux-schnell')) {
      price = _fluxSchnellImage;
    } else if (id.contains('flux-dev')) {
      price = _fluxDevImage;
    } else if (id.contains('flux-pro') ||
        id.contains('dall-e-3') ||
        id.contains('dalle-3')) {
      price = _proImage;
    } else {
      return null;
    }
    return _known(price, 'за изображение');
  }

  /// Цена секунды сгенерированного видео для известных семейств.
  static CostEstimate? _videoEstimate(String id) {
    final isVideo = id.contains('wan') ||
        id.contains('kling') ||
        id.contains('sora') ||
        id.contains('veo') ||
        id.contains('video');
    if (!isVideo) return null;
    final double price;
    if (id.contains('kling')) {
      price = _klingVideoSecond;
    } else if (id.contains('sora')) {
      price = _soraVideoSecond;
    } else if (id.contains('wan')) {
      price = _wanVideoSecond;
    } else {
      return null;
    }
    return _known(price, 'за секунду видео');
  }

  /// Оценка по токенам: возможна только при известных ценах каталога.
  static CostEstimate _textEstimate(String prompt, Pricing? pricing) {
    final pr = pricing;
    if (pr == null || !pr.hasAny) return CostEstimate.unknown;
    final text = prompt.trim();
    var tokens = (text.length / 4).ceil();
    if (tokens < 1) tokens = 1;
    final inPrice = pr.inputPerMillion ?? 0.0;
    final outPrice = pr.outputPerMillion ?? inPrice;
    final usd = (tokens * (inPrice + outPrice)) / 1000000;
    if (usd <= 0) return CostEstimate.unknown;
    final symbol = pr.currency == 'RUB' ? '₽' : _usd;
    return CostEstimate(
      estimatedUsd: usd,
      unitLabel: 'за запрос',
      isKnown: true,
      formatted: '≈ ${_fmtMoney(usd, symbol)} за запрос',
    );
  }

  static CostEstimate _known(double price, String unitLabel) {
    return CostEstimate(
      estimatedUsd: price,
      unitLabel: unitLabel,
      isKnown: true,
      formatted: '≈ ${_fmtMoney(price, _usd)} $unitLabel',
    );
  }

  /// Деньги без обнуления мелких цен: 0.003 -> '$0.0030',
  /// 0.025 -> '$0.025', 0.04 -> '$0.040', 1.5 -> '$1.50'.
  static String _fmtMoney(double v, String symbol) {
    if (v < 0.01) return '$symbol${v.toStringAsFixed(4)}';
    if (v < 1) return '$symbol${v.toStringAsFixed(3)}';
    return '$symbol${v.toStringAsFixed(2)}';
  }
}

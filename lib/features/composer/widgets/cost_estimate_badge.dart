// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../../core/models/cost_estimate.dart';
import '../../../core/models/model_info.dart';
import '../../../theme.dart';

/// Бейдж предварительной оценки стоимости запроса рядом с полем ввода.
/// Реагирует на набор текста через [textController] и на смену модели —
/// через пересборку родителя (новый [modelId]). Когда цену оценить
/// нельзя, бейдж не показывается.
class CostEstimateBadge extends StatelessWidget {
  final String modelId;

  /// Поле ввода композера: бейдж пересчитывает оценку на каждое
  /// изменение текста (пересборка локальная, панель не дёргается).
  final TextEditingController? textController;

  /// Текст промпта, если контроллер не передан.
  final String prompt;

  /// Цены каталога провайдера (для текстовых моделей); null — неизвестны.
  final Pricing? pricing;

  final Palette p;

  const CostEstimateBadge({
    super.key,
    required this.modelId,
    required this.p,
    this.textController,
    this.prompt = '',
    this.pricing,
  });

  CostEstimate _estimate() => CostEstimator.estimate(
        modelId: modelId,
        prompt: textController?.text ?? prompt,
        pricing: pricing,
      );

  @override
  Widget build(BuildContext context) {
    final controller = textController;
    if (controller == null) {
      return _badge(_estimate());
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _badge(_estimate()),
    );
  }

  Widget _badge(CostEstimate estimate) {
    if (!estimate.isKnown || estimate.estimatedUsd == null) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: p.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.payments_outlined, size: 13, color: p.accent),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              estimate.formatted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: p.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

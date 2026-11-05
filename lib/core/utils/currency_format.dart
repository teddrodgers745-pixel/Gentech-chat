// Copyright (c) 2026 Minkail. All rights reserved.

/// Конвертация стоимости в выбранную валюту по фиксированным курсам
/// и форматирование для интерфейса. Базовая сумма хранится в рублях;
/// курсы заданы константами (USD = 90 руб, EUR = 100 руб, CNY = 12 руб).
abstract final class CurrencyFormat {
  /// Сколько рублей в одной единице валюты.
  static const Map<String, double> rubRates = <String, double>{
    'RUB': 1,
    'USD': 90,
    'EUR': 100,
    'CNY': 12,
  };

  /// Символ валюты для интерфейса; неизвестный код — рубль.
  static String symbolFor(String currency) {
    switch (currency.trim().toUpperCase()) {
      case 'USD':
        return r'$';
      case 'EUR':
        return '€';
      case 'CNY':
        return '¥';
      default:
        return '₽';
    }
  }

  /// Конвертирует базовую сумму (в рублях) в выбранную валюту.
  static double convertFromRub(double rubAmount, String currency) {
    final rate = rubRates[currency.trim().toUpperCase()] ?? 1;
    if (rate <= 0) return rubAmount;
    return rubAmount / rate;
  }

  /// Готовая строка вида '1,23 $' (запятая как десятичный разделитель).
  static String format(double rubAmount, String currency) {
    final v = convertFromRub(rubAmount, currency);
    final s = v.toStringAsFixed(2);
    return '${s.replaceAll('.', ',')} ${symbolFor(currency)}';
  }
}

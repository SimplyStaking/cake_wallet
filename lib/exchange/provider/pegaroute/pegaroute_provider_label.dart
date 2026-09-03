import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/trade.dart';

String tradeProviderDisplayName(Trade trade) {
  if (trade.provider != ExchangeProviderDescription.pegaroute) return trade.provider.toString();
  try {
    final execution =
        const PegarouteExecutionBindingValidator().validatePersisted(trade: trade).execution;
    final subprovider = execution.subprovider;
    final route = subprovider == null || subprovider.isEmpty
        ? execution.routeProvider
        : '${execution.routeProvider} / $subprovider';
    return '${trade.provider.title} via $route';
  } catch (_) {
    return trade.provider.title;
  }
}

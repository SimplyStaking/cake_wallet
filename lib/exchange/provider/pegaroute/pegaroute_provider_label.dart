import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/trade.dart';

String tradeProviderDisplayName(Trade trade) {
  if (trade.provider != ExchangeProviderDescription.pegaroute) return trade.provider.toString();
  if (trade.internalId <= 0) return trade.provider.title;
  try {
    final execution =
        const PegarouteExecutionBindingValidator().validatePersisted(trade: trade).execution;
    final subprovider = execution.subprovider;
    final provider = switch (execution.routeProvider) {
      'instaswap' => 'Instaswap',
      'thorchain' => 'THORChain',
      'maya' => 'Maya',
      'openocean' => 'OpenOcean',
      _ => execution.routeProvider,
    };
    final suffix = subprovider == null || subprovider.isEmpty ? '' : ' (via $subprovider)';
    return '${trade.provider.title} via $provider$suffix';
  } catch (_) {
    return trade.provider.title;
  }
}

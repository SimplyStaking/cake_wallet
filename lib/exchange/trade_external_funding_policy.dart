import 'package:cake_wallet/exchange/exchange_provider_description.dart';

import 'trade.dart';

/// Phase 1 external funding is deliberately fail-closed for Pegaroute.
/// Other providers keep their existing external-funding behavior.
class TradeExternalFundingPolicy {
  const TradeExternalFundingPolicy._();

  static bool canUse(Trade trade) => trade.provider != ExchangeProviderDescription.pegaroute;

  static bool canOpenRoute(Trade? trade) => trade != null && canUse(trade);
}

import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_external_funding_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fails closed for Pegaroute while preserving other providers', () {
    final pegaroute = Trade(
      id: 'pegaroute',
      amount: '1',
      provider: ExchangeProviderDescription.pegaroute,
    );
    final existing = Trade(
      id: 'existing',
      amount: '1',
      provider: ExchangeProviderDescription.changeNow,
    );

    expect(TradeExternalFundingPolicy.canUse(pegaroute), isFalse);
    expect(TradeExternalFundingPolicy.canUse(existing), isTrue);
  });
}

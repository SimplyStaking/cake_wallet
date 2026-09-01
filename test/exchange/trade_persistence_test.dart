import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_refund.dart';
import 'package:cw_core/crypto_currency.dart';

void main() {
  test('persists sender, execution, and refund envelopes in the trade row', () {
    final execution = TradeExecution(
      family: 'other',
      mode: 'deposit-transfer',
      sourceChain: 'XMR',
      sourceToken: 'XMR',
      nativeToken: 'XMR',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      routeProvider: 'instaswap',
      subprovider: 'fixture',
      privateIntent: false,
      payload: const {
        'to': 'destination',
        'amount': {'display': '1', 'baseUnits': '1'}
      },
    );
    final refund = TradeRefund(configuredAddress: 'configured');
    final trade = Trade(
      id: 'trade-fixture',
      amount: '1',
      from: CryptoCurrency.xmr,
      to: CryptoCurrency.btc,
      provider: ExchangeProviderDescription.pegaroute,
      senderAddress: 'sender',
      executionJson: execution.encode(),
      refundJson: refund.encode(),
    );

    final reloaded = Trade.fromSqliteRow(trade.toSqliteMap()..['tradeId'] = 1);
    expect(reloaded.provider, ExchangeProviderDescription.pegaroute);
    expect(reloaded.senderAddress, 'sender');
    expect(TradeExecution.fromJsonString(reloaded.executionJson!).family, 'other');
    expect(TradeRefund.fromJsonString(reloaded.refundJson!).configuredAddress, 'configured');
  });

  test('keeps unreadable persisted envelopes as raw values', () {
    final trade = Trade.fromSqliteRow({
      'tradeId': 1,
      'id': 'legacy-trade',
      'providerRaw': 17,
      'amount': '1',
      'stateRaw': 'created',
      'executionJson': '{"version":99}',
      'refundJson': '{"version":99}',
    });
    expect(trade.provider, ExchangeProviderDescription.pegaroute);
    expect(trade.executionJson, '{"version":99}');
    expect(trade.refundJson, '{"version":99}');
    expect(trade.toSqliteMap()['executionJson'], '{"version":99}');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_refund.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cw_core/crypto_currency.dart';

TradeExecutionBinding _binding() => TradeExecutionBinding(
      tradeId: 'trade-fixture',
      providerRaw: 17,
      quoteId: 'quote-fixture',
      quoteExpiresAt: DateTime.utc(2099),
      routeExpiry: null,
      sourceAmount: '1',
      sourceAmountBaseUnits: '1000000000000',
      sourceDecimals: 12,
      senderAddress: 'sender',
      refundAddress: null,
      destinationAddress: 'destination',
      isSendAll: false,
      walletId: 'wallet-fixture',
      walletChainId: null,
      walletAddress: null,
      providerReferenceId: null,
    );

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
      binding: _binding(),
      routeProvider: 'instaswap',
      subprovider: 'fixture',
      privateIntent: false,
      payload: const {
        'chain': 'XMR',
        'to': 'destination',
        'amount': {'display': '1', 'baseUnits': '1000000000000'},
        'memo': null,
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
      payoutAddress: 'destination',
      walletId: 'wallet-fixture',
      fromWalletAddress: 'sender',
      providerName: 'instaswap',
      executionJson: execution.encode(),
      refundJson: refund.encode(),
    );

    final reloaded = Trade.fromSqliteRow(trade.toSqliteMap()..['tradeId'] = 1);
    expect(reloaded.provider, ExchangeProviderDescription.pegaroute);
    expect(reloaded.senderAddress, 'sender');
    expect(TradeExecution.fromJsonString(reloaded.executionJson!).family, 'other');
    expect(TradeRefund.fromJsonString(reloaded.refundJson!).configuredAddress, 'configured');
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(trade: reloaded),
      returnsNormally,
    );
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

  test('does not replace a persisted execution payload during status merge', () {
    final trade = Trade(id: 'trade', amount: '1', executionJson: 'original');
    trade.mergeFindTradeByIdResult(Trade(id: 'trade', amount: '1', executionJson: 'replacement'));
    expect(trade.executionJson, 'original');
  });

  test('does not populate a missing creation execution during status merge', () {
    final trade = Trade(id: 'trade', amount: '1');
    trade.mergeFindTradeByIdResult(Trade(id: 'trade', amount: '1', executionJson: 'observed'));
    expect(trade.executionJson, isNull);
  });

  test('fills a missing sender once but never replaces persisted sender intent', () {
    final missing = Trade(id: 'missing', amount: '1');
    missing.mergeFindTradeByIdResult(Trade(id: 'missing', amount: '1', senderAddress: 'observed'));
    expect(missing.senderAddress, 'observed');

    final persisted = Trade(id: 'persisted', amount: '1', senderAddress: 'configured');
    persisted.mergeFindTradeByIdResult(
      Trade(id: 'persisted', amount: '1', senderAddress: 'different'),
    );
    expect(persisted.senderAddress, 'configured');
  });

  test('preserves configured refund intent across status merges', () {
    final trade = Trade(
      id: 'persisted',
      amount: '1',
      refundAddress: 'configured',
      refundJson: TradeRefund(configuredAddress: 'configured').encode(),
    );
    trade.mergeFindTradeByIdResult(
      Trade(
        id: 'persisted',
        amount: '1',
        refundAddress: 'different',
        refundJson: TradeRefund(configuredAddress: 'different').encode(),
      ),
    );
    expect(trade.refundAddress, 'configured');
    expect(TradeRefund.fromJsonString(trade.refundJson!).configuredAddress, 'configured');
  });

  test('seeds missing refund envelope from persisted configured intent', () {
    final trade = Trade(
      id: 'persisted',
      amount: '1',
      refundAddress: 'configured',
    );
    trade.mergeFindTradeByIdResult(
      Trade(
        id: 'persisted',
        amount: '1',
        refundAddress: 'different',
        refundJson: TradeRefund(configuredAddress: 'different').encode(),
      ),
    );
    expect(trade.refundAddress, 'configured');
    expect(TradeRefund.fromJsonString(trade.refundJson!).configuredAddress, 'configured');
  });

  test('preserves unknown current-version envelopes during status merge', () {
    const unknownExecution = '{"version":1,"future":true}';
    const unknownRefund = '{"version":1,"future":true}';
    final trade =
        Trade(id: 'trade', amount: '1', executionJson: unknownExecution, refundJson: unknownRefund);
    trade.mergeFindTradeByIdResult(
      Trade(
        id: 'trade',
        amount: '1',
        executionJson: '{"version":1,"future":false}',
        refundJson: '{"version":1,"future":false}',
      ),
    );
    expect(trade.executionJson, unknownExecution);
    expect(trade.refundJson, unknownRefund);
  });

  test('does not regress completed refund evidence', () {
    final completed = TradeRefund(
      status: 'completed',
      chain: 'ETH',
      amount: '1',
      originalAmount: '1.1',
      feeDeducted: '0.1',
      feeDescription: 'network fee',
      observedAddress: 'observed',
    );
    final trade = Trade(id: 'trade', amount: '1', refundJson: completed.encode());
    trade.mergeFindTradeByIdResult(
      Trade(
        id: 'trade',
        amount: '1',
        refundJson: TradeRefund(
          status: 'pending',
          chain: 'ETH',
          amount: '1',
          originalAmount: '1.1',
          feeDeducted: '0.1',
          feeDescription: 'network fee',
          observedAddress: 'observed',
        ).encode(),
      ),
    );
    expect(TradeRefund.fromJsonString(trade.refundJson!).status, 'completed');
  });
}

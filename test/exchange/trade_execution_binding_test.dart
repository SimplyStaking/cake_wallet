import 'dart:convert';
import 'dart:io';

import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:flutter_test/flutter_test.dart';

TradeExecution _execution({
  String tradeId = 'trade-fixture',
  String amount = '1',
  String baseUnits = '1000000000000000000',
  String destination = 'bc1qfixture',
}) =>
    TradeExecution(
      family: 'evm',
      mode: 'native-transfer',
      sourceChain: 'ETH',
      sourceToken: 'ETH',
      nativeToken: 'ETH',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      binding: TradeExecutionBinding(
        tradeId: tradeId,
        providerRaw: 17,
        quoteId: 'quote-fixture',
        quoteExpiresAt: DateTime.utc(2099),
        routeExpiry: null,
        sourceAmount: amount,
        sourceAmountBaseUnits: baseUnits,
        sourceDecimals: 18,
        senderAddress: '0x0000000000000000000000000000000000000002',
        refundAddress: null,
        destinationAddress: destination,
        isSendAll: false,
        walletId: 'wallet-fixture',
        walletChainId: 1,
        walletAddress: '0x0000000000000000000000000000000000000002',
        providerReferenceId: null,
      ),
      payload: {
        'chainId': 1,
        'to': '0x0000000000000000000000000000000000000001',
        'data': null,
        'value': {'display': '1', 'baseUnits': baseUnits},
        'gasLimit': null,
        'memo': null,
        'approval': null,
        'transferAmount': null,
      },
    );

Trade _trade(TradeExecution execution) => Trade(
      id: execution.binding.tradeId,
      amount: execution.binding.sourceAmount,
      from: CryptoCurrency.eth,
      to: CryptoCurrency.btc,
      provider: ExchangeProviderDescription.pegaroute,
      senderAddress: execution.binding.senderAddress,
      refundAddress: execution.binding.refundAddress,
      payoutAddress: execution.binding.destinationAddress,
      walletId: execution.binding.walletId,
      fromWalletAddress: execution.binding.walletAddress,
      chainId: execution.binding.walletChainId,
      providerName: execution.routeProvider,
      providerId: execution.binding.providerReferenceId,
      isSendAll: false,
      executionJson: execution.encode(),
    );

void main() {
  test('validates the complete persisted trade context', () {
    final execution = _execution();
    final validated = const PegarouteExecutionBindingValidator().validatePersisted(
      trade: _trade(execution),
    );
    expect(validated.rawExecutionJson, execution.encode());
    expect(validated.execution.binding.tradeId, 'trade-fixture');
  });

  test('rejects each changed persisted identity and amount', () {
    final execution = _execution();
    final validator = const PegarouteExecutionBindingValidator();
    final cases = <Trade Function(Trade)>[
      (trade) => trade..id = 'different-trade',
      (trade) => trade..providerRaw = 16,
      (trade) => trade..amount = '1.1',
      (trade) => trade..senderAddress = '0x0000000000000000000000000000000000000003',
      (trade) => trade..refundAddress = 'refund',
      (trade) => trade..payoutAddress = 'different-destination',
      (trade) => trade..walletId = 'different-wallet',
      (trade) => trade..providerName = 'thorchain',
    ];
    for (final mutate in cases) {
      final trade = mutate(_trade(execution));
      expect(
        () => validator.validatePersisted(trade: trade),
        throwsA(isA<PegarouteBindingException>()),
      );
    }
  });

  test('rejects non-canonical or mismatched source amounts', () {
    final execution = _execution(amount: '1.0000000000000000001');
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(trade: _trade(execution)),
      throwsA(isA<PegarouteBindingException>()),
    );

    final wrongUnits = _execution(baseUnits: '1000000000000000001');
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(trade: _trade(wrongUnits)),
      throwsA(isA<PegarouteBindingException>()),
    );
  });

  test('rejects a changed exact raw execution snapshot', () {
    final execution = _execution();
    final trade = _trade(execution);
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(
        trade: trade,
        expectedRawExecutionJson: '${execution.encode()} ',
      ),
      throwsA(isA<PegarouteBindingException>()),
    );
  });

  test('requires quote expiry before future swap creation', () {
    final value = json.decode(
      File('test/exchange/fixtures/pegaroute/quote.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    value['expiresAt'] = '2099-01-01T00:00:00.000Z';
    final quote = PegarouteQuoteResponse.fromJson(value);
    final route = quote.routes.single;
    final request = PegarouteSwapRequest(
      fromChain: 'ETH',
      fromToken: 'ETH',
      toChain: 'BTC',
      toToken: 'BTC',
      amount: '1',
      destinationAddress: 'bc1qfixture',
      senderAddress: '0x0000000000000000000000000000000000000002',
      routeProvider: 'instaswap',
    );
    const validator = PegarouteExecutionBindingValidator();
    expect(
      () => validator.validateQuotePreflight(
        quote: quote,
        route: route,
        request: request,
        at: DateTime.utc(2098),
      ),
      returnsNormally,
    );
    expect(
      () => validator.validateQuotePreflight(
        quote: quote,
        route: route,
        request: request,
        at: DateTime.utc(2100),
      ),
      throwsA(isA<PegarouteBindingException>()),
    );
  });

  test('preserves and validates typed route expiry without creating a dispatch deadline', () {
    final expiry = TradeExecutionExpiry.fromProviderValue(4102444800);
    expect(expiry.kind, TradeExecutionExpiryKind.unixSeconds);
    expect(expiry.instant().year, 2100);
    expect(TradeExecutionExpiry.fromJson(expiry.toJson()).instant(), expiry.instant());
  });
}

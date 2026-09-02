import 'dart:convert';
import 'dart:io';

import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/transaction_history.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:http/http.dart' as very_insecure_http_do_not_use;
import 'package:flutter_test/flutter_test.dart';

TradeExecution _execution({
  String tradeId = 'trade-fixture',
  String family = 'evm',
  String mode = 'native-transfer',
  String amount = '1',
  String baseUnits = '1000000000000000000',
  String destination = 'bc1qfixture',
  Map<String, dynamic>? payload,
}) =>
    TradeExecution(
      family: family,
      mode: mode,
      sourceChain: 'ETH',
      sourceToken: 'ETH',
      nativeToken: 'ETH',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      routeProvider: 'instaswap',
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
        reviewedRouteJson:
            '{"provider":"instaswap","providerType":"fixture","subprovider":null,"private":false,"expectedOutput":"0.99","fees":null,"estimatedTimeSeconds":0,"memo":null,"inboundAddress":null,"router":null,"minAmount":null,"expiry":null,"gasRate":null,"resolvedFee":null,"openOceanRoute":null}',
        providerReferenceId: null,
      ),
      payload: payload ??
          {
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

class _Addresses implements WalletAddresses {
  @override
  String get address => '0x0000000000000000000000000000000000000002';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Wallet
    extends WalletBase<Balance, TransactionHistoryBase<TransactionInfo>, TransactionInfo> {
  _Wallet()
      : super(
          WalletInfo.external(
            id: 'wallet-fixture',
            name: 'wallet-fixture',
            type: WalletType.ethereum,
            isRecovery: false,
            restoreHeight: 0,
            date: DateTime.utc(2024),
            dirPath: '',
            path: '',
            address: '0x0000000000000000000000000000000000000002',
          ),
          DerivationInfo(),
        ) {
    _walletAddresses = _Addresses();
  }

  @override
  int? get chainId => 1;

  late final WalletAddresses _walletAddresses;

  @override
  WalletAddresses get walletAddresses => _walletAddresses;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

PegarouteQuoteResponse _quote() => PegarouteQuoteResponse.fromJson(
      json.decode(File('test/exchange/fixtures/pegaroute/quote.json').readAsStringSync()),
    );

PegarouteSwapRequest _request() => PegarouteSwapRequest(
      fromChain: 'ETH',
      fromToken: 'ETH',
      toChain: 'BTC',
      toToken: 'BTC',
      amount: '1',
      destinationAddress: 'bc1qfixture',
      senderAddress: '0x0000000000000000000000000000000000000002',
      refundAddress: '0x0000000000000000000000000000000000000003',
      quoteId: 'quote-fixture',
      routeProvider: 'instaswap',
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
      (trade) => trade..providerName = null,
      (trade) => trade..fromWalletAddress = null,
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
    expect(
      () => _execution(amount: '1.0000000000000000001'),
      throwsFormatException,
    );

    expect(
      () => _execution(baseUnits: '1000000000000000001'),
      throwsFormatException,
    );
  });

  test('rejects family, chain, native value, and approval contradictions', () {
    final validator = const PegarouteExecutionBindingValidator();
    final cases = <TradeExecution>[
      _execution(
        payload: {
          'chainId': 56,
          'to': '0x0000000000000000000000000000000000000001',
          'data': null,
          'value': {'display': '1', 'baseUnits': '1000000000000000000'},
          'gasLimit': null,
          'memo': null,
          'approval': null,
          'transferAmount': null,
        },
      ),
      _execution(
        payload: {
          'chainId': 1,
          'to': '0x0000000000000000000000000000000000000001',
          'data': null,
          'value': {'display': '2', 'baseUnits': '2000000000000000000'},
          'gasLimit': null,
          'memo': null,
          'approval': null,
          'transferAmount': null,
        },
      ),
      _execution(
        family: 'utxo',
        mode: 'payment-with-memo',
        payload: {
          'to': 'destination',
          'amount': {'display': '1', 'baseUnits': '1000000000000000000'},
          'memo': null,
          'gasRate': null,
        },
      ),
      _execution(
        mode: 'contract-call',
        payload: {
          'chainId': 1,
          'to': '0x0000000000000000000000000000000000000001',
          'data': '0xdeadbeef',
          'value': null,
          'gasLimit': null,
          'memo': null,
          'approval': {
            'spender': '0x0000000000000000000000000000000000000004',
            'tokenAddress': '0x0000000000000000000000000000000000000005',
            'amount': {'display': '1', 'baseUnits': '1000000000000000000'},
          },
          'transferAmount': null,
        },
      ),
    ];
    for (final execution in cases) {
      expect(
        () => validator.validatePersisted(trade: _trade(execution)),
        throwsA(isA<PegarouteBindingException>()),
      );
    }
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

  test('preflights complete swap context before API I/O and binds after quote expiry', () async {
    final quote = _quote();
    final route = quote.routes.single;
    final trade = Trade(
      id: 'transaction-fixture',
      amount: '1',
      from: CryptoCurrency.eth,
      to: CryptoCurrency.btc,
      provider: ExchangeProviderDescription.pegaroute,
      providerName: 'instaswap',
      walletId: 'wallet-fixture',
      fromWalletAddress: '0x0000000000000000000000000000000000000002',
      chainId: 1,
      senderAddress: '0x0000000000000000000000000000000000000002',
      refundAddress: '0x0000000000000000000000000000000000000003',
      payoutAddress: 'bc1qfixture',
    );
    final preflight = const PegarouteExecutionBindingValidator().preflightSwap(
      trade: trade,
      wallet: _Wallet(),
      quote: quote,
      route: route,
      request: _request(),
      at: DateTime.utc(2026, 8, 31),
    );
    final value = json.decode(File('test/exchange/fixtures/pegaroute/swap.json').readAsStringSync())
        as Map<String, dynamic>;
    ((value['execution'] as Map<String, dynamic>)['value'] as Map<String, dynamic>)['baseUnits'] =
        '1000000000000000000';
    final response = PegarouteSwapResponse.fromJson(value);
    final execution = const PegarouteExecutionBindingValidator().bindSwapResponse(
      preflight: preflight,
      response: response,
    );
    expect(execution.binding.quoteId, 'quote-fixture');
    expect(execution.binding.reviewedRouteJson, isNotEmpty);

    final routeChanged = json.decode(json.encode(value)) as Map<String, dynamic>;
    (routeChanged['route'] as Map<String, dynamic>)['expectedOutput'] = '0.50';
    expect(
      () => const PegarouteExecutionBindingValidator().bindSwapResponse(
        preflight: preflight,
        response: PegarouteSwapResponse.fromJson(routeChanged),
      ),
      throwsA(isA<PegarouteBindingException>()),
    );

    var calls = 0;
    final client = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
      post: (uri, headers, body) async {
        calls++;
        return very_insecure_http_do_not_use.Response(json.encode(value), 202);
      },
    );
    await client.swap(preflight);
    expect(calls, 1);
  });

  test('raw requests cannot cross the swap API boundary', () {
    final dynamic client = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
    );
    expect(() => client.swap(_request()), throwsA(isA<TypeError>()));
  });

  test('rejects expired or mismatched swap preflight without API I/O', () {
    final quote = _quote();
    final route = quote.routes.single;
    final trade = Trade(
      id: 'transaction-fixture',
      amount: '1',
      from: CryptoCurrency.eth,
      to: CryptoCurrency.btc,
      provider: ExchangeProviderDescription.pegaroute,
      providerName: 'instaswap',
      walletId: 'wallet-fixture',
      fromWalletAddress: '0x0000000000000000000000000000000000000002',
      chainId: 1,
      senderAddress: '0x0000000000000000000000000000000000000002',
      refundAddress: '0x0000000000000000000000000000000000000003',
      payoutAddress: 'bc1qfixture',
    );
    expect(
      () => const PegarouteExecutionBindingValidator().preflightSwap(
        trade: trade,
        wallet: _Wallet(),
        quote: quote,
        route: route,
        request: _request(),
        at: DateTime.utc(2026, 9, 2),
      ),
      throwsA(isA<PegarouteBindingException>()),
    );
    expect(
      () => const PegarouteExecutionBindingValidator().preflightSwap(
        trade: trade,
        wallet: _Wallet(),
        quote: quote,
        route: route,
        request: PegarouteSwapRequest(
          fromChain: 'BSC',
          fromToken: 'BNB',
          toChain: 'BTC',
          toToken: 'BTC',
          amount: '1',
          destinationAddress: 'bc1qfixture',
          senderAddress: '0x0000000000000000000000000000000000000002',
          quoteId: 'quote-fixture',
          routeProvider: 'instaswap',
        ),
        at: DateTime.utc(2026, 8, 31),
      ),
      throwsA(isA<PegarouteBindingException>()),
    );
  });
}

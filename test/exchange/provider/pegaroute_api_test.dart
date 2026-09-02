import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:http/http.dart' as very_insecure_http_do_not_use;

String _fixture(String name) => File('test/exchange/fixtures/pegaroute/$name').readAsStringSync();

TradeExecutionBinding _binding() => TradeExecutionBinding(
      tradeId: 'trade-fixture',
      providerRaw: 17,
      quoteId: 'quote-fixture',
      quoteExpiresAt: DateTime.utc(2099),
      routeExpiry: null,
      sourceAmount: '1',
      sourceAmountBaseUnits: '1',
      sourceDecimals: 0,
      senderAddress: 'sender',
      refundAddress: null,
      destinationAddress: 'destination',
      isSendAll: false,
      walletId: 'wallet-fixture',
      walletChainId: null,
      walletAddress: null,
      providerReferenceId: null,
    );

Map<String, dynamic> _amount() => {'display': '1', 'baseUnits': '1'};

Trade _boundStatusTrade() {
  final execution = TradeExecution(
    family: 'evm',
    mode: 'native-transfer',
    sourceChain: 'ETH',
    sourceToken: 'ETH',
    nativeToken: 'ETH',
    destinationChain: 'BTC',
    destinationToken: 'BTC',
    routeProvider: 'instaswap',
    binding: TradeExecutionBinding(
      tradeId: 'transaction-fixture',
      providerRaw: 17,
      quoteId: 'quote-fixture',
      quoteExpiresAt: DateTime.utc(2099),
      routeExpiry: null,
      sourceAmount: '1',
      sourceAmountBaseUnits: '1000000000000000000',
      sourceDecimals: 18,
      senderAddress: '0x0000000000000000000000000000000000000002',
      refundAddress: '0x0000000000000000000000000000000000000003',
      destinationAddress: 'bc1qfixture',
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
      'value': {'display': '1', 'baseUnits': '1000000000000000000'},
      'gasLimit': null,
      'memo': null,
      'approval': null,
      'transferAmount': null,
    },
  );
  return Trade(
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
    executionJson: execution.encode(),
  );
}

List<Map<String, dynamic>> _executionVariants() => [
      {
        'family': 'evm',
        'mode': 'contract-call',
        'chainId': 1,
        'to': '0x0000000000000000000000000000000000000001',
        'data': '0xabcdef',
        'value': null,
        'gasLimit': null,
        'memo': null,
        'approval': null,
        'transferAmount': null,
      },
      {
        'family': 'evm',
        'mode': 'native-transfer',
        'chainId': 1,
        'to': '0x0000000000000000000000000000000000000001',
        'data': null,
        'value': _amount(),
        'gasLimit': null,
        'memo': null,
        'approval': null,
        'transferAmount': null,
      },
      {
        'family': 'evm',
        'mode': 'erc20-transfer',
        'chainId': 1,
        'to': '0x0000000000000000000000000000000000000001',
        'data': null,
        'value': null,
        'gasLimit': null,
        'memo': null,
        'approval': null,
        'transferAmount': _amount(),
      },
      {
        'family': 'utxo',
        'mode': 'payment-with-memo',
        'to': 'bc1qfixture',
        'amount': _amount(),
        'memo': null,
        'gasRate': null,
      },
      {
        'family': 'cosmos',
        'mode': 'bank-send',
        'to': 'cosmos1fixture',
        'amount': _amount(),
        'memo': null,
      },
      {
        'family': 'cosmos',
        'mode': 'msg-deposit',
        'to': 'cosmos1fixture',
        'amount': _amount(),
        'memo': null,
        'asset': 'THOR.RUNE',
        'assetDecimals': 8,
      },
      {
        'family': 'solana',
        'mode': 'serialized-tx',
        'serializedTransaction': 'base58-transaction',
        'minOut': null,
      },
      {
        'family': 'sui',
        'mode': 'serialized-tx',
        'serializedTransaction': 'base64-transaction',
        'minOut': null,
      },
      ...[
        'solana',
        'sui',
        'xrp',
        'tron',
        'near',
        'hypercore',
        'cardano',
      ].map((family) => <String, dynamic>{
            'family': family,
            'mode': 'deposit-transfer',
            'to': 'deposit-destination',
            'amount': _amount(),
            'memo': null,
          }),
      {
        'family': 'other',
        'mode': 'deposit-transfer',
        'chain': 'APTOS',
        'to': 'deposit-destination',
        'amount': _amount(),
        'memo': null,
      },
    ];

Map<String, dynamic> _tradePayload(PegarouteExecution execution) {
  final payload = execution.toJson();
  payload.remove('family');
  payload.remove('mode');
  return payload;
}

void main() {
  test('validates full origins and only permits loopback HTTP', () {
    expect(
        PegarouteConfiguration(baseUrl: 'http://localhost:4000', apiKey: 'test').isValid, isTrue);
    expect(
        PegarouteConfiguration(baseUrl: 'http://127.42.0.9:4000', apiKey: 'test').isValid, isTrue);
    expect(PegarouteConfiguration(baseUrl: 'https://api.example.test:443/', apiKey: 'test').isValid,
        isTrue);
    expect(
        PegarouteConfiguration(baseUrl: 'http://10.0.2.2:4000', apiKey: 'test').isValid, isFalse);
    expect(PegarouteConfiguration(baseUrl: 'https://example.test/api', apiKey: 'test').isValid,
        isFalse);
    expect(
        PegarouteConfiguration(baseUrl: 'https://user:pass@example.test', apiKey: 'test').isValid,
        isFalse);
    expect(PegarouteConfiguration(baseUrl: 'https://example.test?x=1', apiKey: 'test').isValid,
        isFalse);
    expect(PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: ' ').isValid, isFalse);
  });

  test('decodes quote and swap fixtures with exact execution fields', () {
    final quote = PegarouteQuoteResponse.fromJson(json.decode(_fixture('quote.json')));
    expect(quote.routes.single.provider, 'instaswap');
    expect(quote.routes.single.subprovider, 'partner-fixture');

    final swap = PegarouteSwapResponse.fromJson(json.decode(_fixture('swap.json')));
    expect(swap.execution.family, 'evm');
    expect(swap.execution.mode, 'native-transfer');
    expect(swap.execution.value!.baseUnits, '1');
    expect(swap.provider.instaswapSwapLite!.txid, 'provider-reference-fixture');
  });

  test('decodes every Pegasus execution variant into a valid trade payload', () {
    for (final value in _executionVariants()) {
      final execution = PegarouteExecution.fromJson(value);
      expect(
        () => TradeExecution(
          family: execution.family,
          mode: execution.mode,
          sourceChain: 'ETH',
          sourceToken: 'ETH',
          nativeToken: 'ETH',
          destinationChain: 'BTC',
          destinationToken: 'BTC',
          binding: _binding(),
          payload: _tradePayload(execution),
        ),
        returnsNormally,
      );
    }
  });

  test('decodes nested status, refund, and streaming contracts', () {
    final status = PegarouteStatusResponse.fromJson(json.decode(_fixture('status_refund.json')));
    expect(status.internalStatus, 'refunded');
    expect(status.input.refundAddress, isNotNull);
    expect(status.refund, isNull);
    expect(status.output.txHash, 'output-hash-fixture');
    expect(status.affiliateFeeBreakdown!.pegasusNetUsd, '0.01');
  });

  test('preserves structured error codes and retry metadata', () {
    final error = PegarouteApiError.fromJson(429, {
      'error': {
        'code': 'RATE_LIMITED',
        'message': 'retry later',
        'userMessage': 'Please retry later',
        'retryable': true,
        'retryAfterSeconds': 3,
        'provider': 'fixture-provider',
        'details': {'future': true},
      },
    });
    expect(error.code, 'RATE_LIMITED');
    expect(error.retryAfterSeconds, 3);
    expect(error.details!['future'], isTrue);
  });

  test('uses identical normalized sender and refund intent in requests', () {
    final intent = PegarouteAddressIntent(
      destinationAddress: ' destination ',
      senderAddress: ' sender ',
      refundAddress: ' refund ',
    );
    final quote = PegarouteQuoteRequest.fromIntent(
      fromChain: 'ETH',
      fromToken: 'ETH',
      toChain: 'BTC',
      toToken: 'BTC',
      amount: '1',
      intent: intent,
    );
    final swap = PegarouteSwapRequest.fromIntent(
      fromChain: 'ETH',
      fromToken: 'ETH',
      toChain: 'BTC',
      toToken: 'BTC',
      amount: '1',
      intent: intent,
    );
    expect(swap.toJson()['senderAddress'], quote.toQuery()['senderAddress']);
    expect(swap.toJson()['refundAddress'], quote.toQuery()['refundAddress']);
  });

  test('preserves private mode as a JSON boolean for swaps', () {
    final request = PegarouteSwapRequest(
      fromChain: 'ETH',
      fromToken: 'ETH',
      toChain: 'BTC',
      toToken: 'BTC',
      amount: '1',
      destinationAddress: 'destination',
      senderAddress: 'sender',
    );
    expect(request.toJson().containsKey('private'), isFalse);
  });

  test('omits a refund address equivalent to the normalized sender', () {
    final intent = PegarouteAddressIntent(
      destinationAddress: ' destination ',
      senderAddress: ' sender ',
      refundAddress: 'sender',
    );
    expect(intent.refundAddress, isNull);
  });

  test('omits sender-equivalent refunds in direct request constructors', () {
    final quote = PegarouteQuoteRequest(
      fromChain: 'ETH',
      fromToken: 'ETH',
      toChain: 'BTC',
      toToken: 'BTC',
      amount: '1',
      senderAddress: ' sender ',
      refundAddress: 'sender',
    );
    final swap = PegarouteSwapRequest(
      fromChain: 'ETH',
      fromToken: 'ETH',
      toChain: 'BTC',
      toToken: 'BTC',
      amount: '1',
      destinationAddress: 'destination',
      senderAddress: ' sender ',
      refundAddress: 'sender',
    );
    expect(quote.senderAddress, 'sender');
    expect(quote.refundAddress, isNull);
    expect(swap.senderAddress, 'sender');
    expect(swap.refundAddress, isNull);
  });

  test('injects transport and never exposes credentials in response parsing', () async {
    final calls = <String>[];
    final client = PegarouteApiClient(
      configuration:
          const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: ' test '),
      get: (uri, headers) async {
        calls.add('${uri.path}?${uri.query}');
        expect(headers.keys, contains('X-API-Key'));
        expect(headers['X-API-Key'], 'test');
        return very_insecure_http_do_not_use.Response(_fixture('quote.json'), 200);
      },
    );
    final result = await client.quote(PegarouteQuoteRequest(
      fromChain: 'ETH',
      fromToken: 'ETH',
      toChain: 'BTC',
      toToken: 'BTC',
      amount: '1',
    ));
    expect(result.quoteId, 'quote-fixture');
    expect(calls, ['/quote?fromChain=ETH&fromToken=ETH&toChain=BTC&toToken=BTC&amount=1']);
  });

  test('rejects unknown execution modes', () {
    final value = json.decode(_fixture('swap.json')) as Map<String, dynamic>;
    (value['execution'] as Map<String, dynamic>)['mode'] = 'future-mode';
    expect(() => PegarouteSwapResponse.fromJson(value), throwsA(isA<PegarouteCodecException>()));
  });

  test('rejects schema omissions instead of accepting partial routes', () {
    final value = json.decode(_fixture('quote.json')) as Map<String, dynamic>;
    final route = (value['routes'] as List).single as Map<String, dynamic>;
    route.remove('fees');
    expect(() => PegarouteQuoteResponse.fromJson(value), throwsA(isA<PegarouteCodecException>()));
  });

  test('requires nullable contract fields while accepting explicit nulls', () {
    final quote = json.decode(_fixture('quote.json')) as Map<String, dynamic>;
    expect(PegarouteQuoteResponse.fromJson(quote), isA<PegarouteQuoteResponse>());
    final quoteRoute = (quote['routes'] as List).single as Map<String, dynamic>;
    quoteRoute.remove('memo');
    expect(() => PegarouteQuoteResponse.fromJson(quote), throwsA(isA<PegarouteCodecException>()));

    final swap = json.decode(_fixture('swap.json')) as Map<String, dynamic>;
    expect(PegarouteSwapResponse.fromJson(swap), isA<PegarouteSwapResponse>());
    final execution = swap['execution'] as Map<String, dynamic>;
    execution.remove('memo');
    expect(() => PegarouteSwapResponse.fromJson(swap), throwsA(isA<PegarouteCodecException>()));

    final provider = json.decode(_fixture('swap.json')) as Map<String, dynamic>;
    final providerMap = provider['provider'] as Map<String, dynamic>;
    providerMap['referenceId'] = null;
    expect(PegarouteSwapResponse.fromJson(provider), isA<PegarouteSwapResponse>());
    providerMap.remove('referenceId');
    expect(() => PegarouteSwapResponse.fromJson(provider), throwsA(isA<PegarouteCodecException>()));
  });

  test('accepts the compact route shape used by swap status responses', () {
    final value = json.decode(_fixture('status_refund.json')) as Map<String, dynamic>;
    final route = value['route'] as Map<String, dynamic>;
    route.remove('providerType');
    route.remove('expiry');
    route.remove('memo');
    route.remove('inboundAddress');
    route.remove('router');
    route.remove('gasRate');
    route.remove('minAmount');
    route.remove('resolvedFee');
    expect(PegarouteStatusResponse.fromJson(value).route.provider, 'instaswap');
  });

  test('rejects incompatible EVM execution fields', () {
    final value = json.decode(_fixture('swap.json')) as Map<String, dynamic>;
    final execution = value['execution'] as Map<String, dynamic>;
    execution['mode'] = 'contract-call';
    execution['data'] = '0xdeadbeef';
    execution['transferAmount'] = {'display': '1', 'baseUnits': '1'};
    expect(() => PegarouteSwapResponse.fromJson(value), throwsA(isA<PegarouteCodecException>()));
  });

  test('requires calldata for contract-call execution', () {
    final value = json.decode(_fixture('swap.json')) as Map<String, dynamic>;
    final execution = value['execution'] as Map<String, dynamic>;
    execution['mode'] = 'contract-call';
    execution['data'] = null;
    expect(() => PegarouteSwapResponse.fromJson(value), throwsA(isA<PegarouteCodecException>()));
  });

  test('requires exact success status for GET and preserves status polling boundaries', () async {
    final client = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
      get: (uri, headers) async =>
          very_insecure_http_do_not_use.Response(_fixture('quote.json'), 201),
    );
    await expectLater(
      client.quote(PegarouteQuoteRequest(
        fromChain: 'ETH',
        fromToken: 'ETH',
        toChain: 'BTC',
        toToken: 'BTC',
        amount: '1',
      )),
      throwsA(isA<PegarouteCodecException>()),
    );

    final statusClient = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
      get: (uri, headers) async =>
          very_insecure_http_do_not_use.Response(_fixture('status_refund.json'), 200),
    );
    await expectLater(
      PegarouteExchangeProvider(apiClient: statusClient).findTradeById(
        id: 'transaction-fixture',
      ),
      throwsA(isA<PegarouteBindingException>()),
    );
  });

  test('rejects invalid refund lifecycle values', () {
    expect(
      () => PegarouteRefund.fromJson({
        'status': 'sent',
        'chain': 'ETH',
        'amount': '1',
        'originalAmount': '1',
        'feeDeducted': '0',
        'feeDescription': 'none',
        'refundAddress': 'address',
      }),
      throwsA(isA<PegarouteCodecException>()),
    );
  });

  test('keeps configured but handler-less Pegaroute out of provider I/O', () async {
    var calls = 0;
    final api = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
      get: (uri, headers) async {
        calls++;
        return very_insecure_http_do_not_use.Response('{}', 500);
      },
    );
    final provider = PegarouteExchangeProvider(apiClient: api);
    expect(provider.isAvailable, isFalse);
    expect(provider.isEnabled, isFalse);
    expect(provider.supportsMemoOrDestinationTag, isFalse);
    await expectLater(
      provider.fetchRate(
        from: CryptoCurrency.eth,
        to: CryptoCurrency.btc,
        amount: 1,
        isFixedRateMode: false,
        isReceiveAmount: false,
      ),
      throwsA(isA<PegarouteUnavailableException>()),
    );
    expect(calls, 0);
  });

  test('accepts empty warning providers but keeps warning fields typed', () {
    final warning = PegarouteWarning.fromJson({
      'provider': '',
      'code': 'NO_PROVIDER',
      'message': 'none',
      'userMessage': 'No provider available',
    });
    expect(warning.provider, isEmpty);
    expect(
      () => PegarouteWarning.fromJson({
        'provider': 1,
        'code': 'NO_PROVIDER',
        'message': 'none',
        'userMessage': 'No provider available',
      }),
      throwsA(isA<PegarouteCodecException>()),
    );
  });

  test('retains strict provider changed replacement terms', () {
    final quote = json.decode(_fixture('quote.json')) as Map<String, dynamic>;
    final error = PegarouteApiError.fromJson(409, {
      'error': {
        'code': 'PROVIDER_CHANGED',
        'message': 'changed',
        'userMessage': 'Review terms',
        'retryable': false,
      },
      'newQuote': quote,
      'originalProvider': 'instaswap',
      'newProvider': 'thorchain',
    });
    expect(error.requiresReview, isTrue);
    expect(error.newQuote!.quoteId, 'quote-fixture');
    expect(error.originalProvider, 'instaswap');
    expect(error.newProvider, 'thorchain');
  });

  test('rejects non-positive request amounts and empty token queries', () async {
    expect(
      () => PegarouteQuoteRequest(
        fromChain: 'ETH',
        fromToken: 'ETH',
        toChain: 'BTC',
        toToken: 'BTC',
        amount: '0',
      ),
      throwsA(isA<PegarouteCodecException>()),
    );
    expect(
      () => PegarouteQuoteRequest(
        fromChain: 'ETH',
        fromToken: 'ETH',
        toChain: 'BTC',
        toToken: 'BTC',
        amount: '1',
      ).toQuery(),
      returnsNormally,
    );
    await expectLater(
      PegarouteApiClient(
        configuration:
            const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
      ).tokens(' '),
      throwsA(isA<PegarouteCodecException>()),
    );
  });

  test('rejects explicit null for optional non-nullable response fields', () {
    final quote = json.decode(_fixture('quote.json')) as Map<String, dynamic>;
    final route = (quote['routes'] as List).single as Map<String, dynamic>;
    route['subprovider'] = null;
    expect(() => PegarouteQuoteResponse.fromJson(quote), throwsA(isA<PegarouteCodecException>()));

    final status = json.decode(_fixture('status_refund.json')) as Map<String, dynamic>;
    (status['timestamps'] as Map<String, dynamic>)['completed'] = null;
    expect(() => PegarouteStatusResponse.fromJson(status), throwsA(isA<PegarouteCodecException>()));

    final statusProvider = json.decode(_fixture('status_refund.json')) as Map<String, dynamic>;
    statusProvider['provider'] = null;
    expect(() => PegarouteStatusResponse.fromJson(statusProvider),
        throwsA(isA<PegarouteCodecException>()));

    final openOcean = json.decode(_fixture('quote.json')) as Map<String, dynamic>;
    (openOcean['routes'] as List).single['openOceanRoute'] = {
      'dexId': 1,
      'dexCode': 'fixture',
      'dexes': null,
    };
    expect(
        () => PegarouteQuoteResponse.fromJson(openOcean), throwsA(isA<PegarouteCodecException>()));

    final openOceanOmitted = json.decode(_fixture('quote.json')) as Map<String, dynamic>;
    (openOceanOmitted['routes'] as List).single['openOceanRoute'] = <String, dynamic>{};
    expect(PegarouteQuoteResponse.fromJson(openOceanOmitted), isA<PegarouteQuoteResponse>());

    final snapshot = json.decode(_fixture('status_refund.json')) as Map<String, dynamic>;
    (snapshot['input'] as Map<String, dynamic>)['instaswapSwapLite'] = null;
    expect(
        () => PegarouteStatusResponse.fromJson(snapshot), throwsA(isA<PegarouteCodecException>()));

    expect(
      () => PegarouteStreamingProgress.fromJson({
        'completedSubSwaps': 1,
        'totalSubSwaps': 2,
        'partialRefund': null,
      }),
      throwsA(isA<PegarouteCodecException>()),
    );
    expect(
      PegarouteStreamingProgress.fromJson({
        'completedSubSwaps': 1,
        'totalSubSwaps': 2,
      }).partialRefund,
      isNull,
    );

    expect(
      () => PegarouteInstaswapSnapshot.fromJson({
        'txid': 'fixture',
        'depositAddress': 'address',
        'feeBreakdown': null,
      }),
      throwsA(isA<PegarouteCodecException>()),
    );
  });

  test('rejects blank and ID-only status before transport', () async {
    final calls = <String>[];
    final client = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
      get: (uri, headers) async {
        calls.add(uri.path);
        return very_insecure_http_do_not_use.Response(_fixture('status_refund.json'), 200);
      },
    );
    await expectLater(client.status(' '), throwsA(isA<PegarouteCodecException>()));
    expect(calls, isEmpty);

    final provider = PegarouteExchangeProvider(apiClient: client);
    await expectLater(
      provider.findTradeById(id: 'different-id'),
      throwsA(isA<PegarouteBindingException>()),
    );
    expect(calls, isEmpty);
  });

  test('falls back to the status input provider reference ID', () async {
    final value = json.decode(_fixture('status_refund.json')) as Map<String, dynamic>;
    (value['input'] as Map<String, dynamic>)['providerReferenceId'] = 'input-reference';
    final client = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
      get: (uri, headers) async => very_insecure_http_do_not_use.Response(json.encode(value), 200),
    );
    final trade = await PegarouteExchangeProvider(apiClient: client).findTradeForContext(
      trade: _boundStatusTrade(),
    );
    expect(trade.providerId, 'input-reference');
  });

  test('preflights Pegaroute status and validates the complete response', () async {
    var calls = 0;
    final client = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
      get: (uri, headers) async {
        calls++;
        return very_insecure_http_do_not_use.Response(_fixture('status_refund.json'), 200);
      },
    );
    final provider = PegarouteExchangeProvider(apiClient: client);
    final trade = _boundStatusTrade();
    final result = await provider.findTradeForContext(trade: trade);
    expect(result.id, trade.id);
    expect(calls, 1);

    final mismatch = _boundStatusTrade()..amount = '2';
    await expectLater(
      provider.findTradeForContext(trade: mismatch),
      throwsA(isA<PegarouteBindingException>()),
    );
    expect(calls, 1);

    final changedResponse = json.decode(_fixture('status_refund.json')) as Map<String, dynamic>;
    (changedResponse['output'] as Map<String, dynamic>)['address'] = 'different-destination';
    final responseProvider = PegarouteExchangeProvider(
      apiClient: PegarouteApiClient(
        configuration:
            const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
        get: (uri, headers) async =>
            very_insecure_http_do_not_use.Response(json.encode(changedResponse), 200),
      ),
    );
    await expectLater(
      responseProvider.findTradeForContext(trade: _boundStatusTrade()),
      throwsA(isA<PegarouteBindingException>()),
    );
  });
}

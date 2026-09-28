import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:http/http.dart' as very_insecure_http_do_not_use;

// Reused final-reference wire/transport scenarios only. Successful decoding is
// not funding eligibility; real provider/store/wallet callers test that seam.
String _fixture(String name) => File('test/exchange/fixtures/pegaroute/$name').readAsStringSync();
Map<String, dynamic> _amount() => {'display': '1', 'baseUnits': '1'};
const _unsupportedFamilies = {'cosmos', 'sui', 'xrp', 'near', 'hypercore', 'cardano'};

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
        'encoding': 'base58',
        'serializedTransaction': '3MN',
        'minOut': null
      },
      {'family': 'sui', 'mode': 'serialized-tx', 'serializedTransaction': 'dHh4', 'minOut': null},
      ...['solana', 'sui', 'xrp', 'tron', 'near', 'hypercore', 'cardano'].map(
        (family) => <String, dynamic>{
          'family': family,
          'mode': 'deposit-transfer',
          'to': 'deposit-destination',
          'amount': _amount(),
          'memo': null,
        },
      ),
      {
        'family': 'other',
        'mode': 'deposit-transfer',
        'chain': 'APTOS',
        'to': 'deposit-destination',
        'amount': _amount(),
        'memo': null,
      },
    ];

void main() {
  test('validates full origins and only permits loopback HTTP', () {
    expect(PegarouteConfiguration(baseUrl: 'http://localhost:4000').isValid, isTrue);
    expect(PegarouteConfiguration(baseUrl: 'http://127.42.0.9:4000').isValid, isTrue);
    expect(PegarouteConfiguration(baseUrl: 'https://api.example.test:443/').isValid, isTrue);
    expect(PegarouteConfiguration(baseUrl: 'http://10.0.2.2:4000').isValid, isFalse);
    expect(PegarouteConfiguration(baseUrl: 'https://example.test/api').isValid, isFalse);
    expect(PegarouteConfiguration(baseUrl: 'https://user:pass@example.test').isValid, isFalse);
    expect(PegarouteConfiguration(baseUrl: 'https://example.test?x=1').isValid, isFalse);
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

  test('preserves string private routes and treats an omitted value as false', () {
    final value = json.decode(_fixture('quote.json')) as Map<String, dynamic>;
    final route = (value['routes'] as List).single as Map<String, dynamic>;
    route['private'] = 'private-fixture';
    expect(
      PegarouteQuoteResponse.fromJson(value).routes.single.privateValue!.value,
      'private-fixture',
    );

    route.remove('private');
    expect(PegarouteQuoteResponse.fromJson(value).routes.single.privateValue, isNull);
  });

  test('accepts additive response metadata and omitted optional provider details', () {
    final quote = json.decode(_fixture('quote.json')) as Map<String, dynamic>;
    (quote['routes'] as List).single
      ..remove('subprovider')
      ..remove('private')
      ..['futureLabel'] = {'name': 'informational'};
    expect(PegarouteQuoteResponse.fromJson(quote).routes.single.subprovider, isNull);

    final swap = json.decode(_fixture('swap.json')) as Map<String, dynamic>;
    swap['futureInfo'] = ['informational'];
    (swap['route'] as Map)
      ..remove('subprovider')
      ..remove('private')
      ..['futureLabel'] = 'informational';
    (swap['provider'] as Map).remove('details');
    final decoded = PegarouteSwapResponse.fromJson(swap);
    expect(decoded.provider.details, isNull);
    expect(decoded.route.subprovider, isNull);
    expect(decoded.execution.value!.baseUnits, '1');

    (swap['execution'] as Map)['futureOperation'] = 'not supported';
    expect(() => PegarouteSwapResponse.fromJson(swap), throwsA(isA<PegarouteCodecException>()));
  });

  test('keeps required route and execution fields required when metadata is optional', () {
    for (final field in ['provider', 'expectedOutput', 'fees', 'estimatedTimeSeconds']) {
      final swap = json.decode(_fixture('swap.json')) as Map<String, dynamic>;
      (swap['route'] as Map).remove(field);
      expect(() => PegarouteSwapResponse.fromJson(swap), throwsA(isA<PegarouteCodecException>()),
          reason: field);
    }
    for (final field in ['family', 'mode', 'to', 'chainId', 'value', 'data']) {
      final swap = json.decode(_fixture('swap.json')) as Map<String, dynamic>;
      (swap['execution'] as Map).remove(field);
      expect(() => PegarouteSwapResponse.fromJson(swap), throwsA(isA<PegarouteCodecException>()),
          reason: field);
    }
  });

  test('freezes quote route maps, lists, and provider detail maps', () {
    final quoteValue = json.decode(_fixture('quote.json')) as Map<String, dynamic>;
    final quote = PegarouteQuoteResponse.fromJson(quoteValue);
    (quoteValue['routes'] as List).single['expectedOutput'] = '0.01';
    expect(quote.routes.single.expectedOutput, '0.99');
    expect(() => quote.routes.add(quote.routes.single), throwsA(isA<UnsupportedError>()));

    final feeValue = json.decode(_fixture('quote.json')) as Map<String, dynamic>;
    (feeValue['routes'] as List).single['resolvedFee'] = {'feeBps': 1};
    final feeQuote = PegarouteQuoteResponse.fromJson(feeValue);
    expect(
      () => feeQuote.routes.single.resolvedFee!['feeBps'] = 2,
      throwsA(isA<UnsupportedError>()),
    );

    final provider = PegarouteProviderInfo.fromJson(json.decode(_fixture('swap.json'))['provider']);
    expect(
      () => (provider.details as Map<String, dynamic>)['instaswapSwapLite'] = <String, dynamic>{},
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('Solana serialized execution requires and preserves its encoding label', () {
    final value = _executionVariants().firstWhere((value) => value['family'] == 'solana');
    final execution = PegarouteExecution.fromJson(value);
    expect(execution.toJson()['encoding'], 'base58');
    expect(execution.toJson()['serializedTransaction'], value['serializedTransaction']);
  });

  test('Solana serialized execution rejects missing and invalid encoding labels', () {
    final value = _executionVariants().firstWhere((value) => value['family'] == 'solana');
    value.remove('encoding');
    expect(() => PegarouteExecution.fromJson(value), throwsA(isA<PegarouteCodecException>()));
    for (final label in [null, '', 'BASE64', 'base64 ', 'unknown', 1, true]) {
      value['encoding'] = label;
      expect(() => PegarouteExecution.fromJson(value), throwsA(isA<PegarouteCodecException>()));
    }
  });

  test('encoding is forbidden on every non-Solana-serialized API shape', () {
    for (final value in _executionVariants()) {
      if (value['family'] == 'solana' && value['mode'] == 'serialized-tx') continue;
      for (final label in [null, 'base64']) {
        value['encoding'] = label;
        expect(() => PegarouteExecution.fromJson(value), throwsA(isA<PegarouteCodecException>()));
      }
    }
  });

  test('decodes order status and refund evidence', () {
    final status = PegarouteStatusResponse.fromJson(json.decode(_fixture('status_refund.json')));
    expect(status.internalStatus, 'refunded');
    expect(status.input.refundAddress, isNotNull);
    expect(status.refund, isNull);
    expect(status.output.txHash, 'output-hash-fixture');
  });

  test('unused status metadata does not replace order or refund fields', () {
    final value = json.decode(_fixture('status_refund.json')) as Map<String, dynamic>;
    const unused = ['fees', 'timestamps', 'affiliateFeeBreakdown', 'error', 'streamingProgress'];
    for (final field in unused) { value.remove(field); }
    expect(PegarouteStatusResponse.fromJson(value).internalStatus, 'refunded');
    for (final field in unused) { value[field] = {'futureMetadata': true}; }
    final status = PegarouteStatusResponse.fromJson(value);
    expect(status.internalStatus, 'refunded');
    expect(status.refund, isNull);
    expect(status.output.txHash, 'output-hash-fixture');
    value.remove('refund');
    expect(() => PegarouteStatusResponse.fromJson(value), throwsA(isA<PegarouteCodecException>()));
  });

  test('preserves structured retry metadata but drops arbitrary diagnostic details', () {
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
    // R4's public-error boundary deliberately does not retain arbitrary
    // upstream prose/details, which can contain credentials or private data.
    expect(error.details, isNull);
    expect(error.userMessage, 'Pegaroute RATE_LIMITED');
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

  test('public-only swaps omit the retired private JSON body field', () {
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

  test('decodes canonical private modes and preserves the warning audit trail', () {
    final value = json.decode(_fixture('quote_private_zk.json')) as Map<String, dynamic>;
    final quote = PegarouteQuoteResponse.fromJson(value);
    expect(quote.routes.single.privateValue!.value, 'zk');
    expect(quote.warnings.map((warning) => warning.provider), ['thorchain', 'maya', 'openocean']);
    final route = (value['routes'] as List).single as Map<String, dynamic>;
    for (final mode in [false, true, 'zk', 'future-mode', 'false', 'x' * 64]) {
      route['private'] = mode;
      final decoded = PegarouteQuoteResponse.fromJson(value).routes.single.privateValue!;
      expect(decoded.toJson(), mode);
      expect(decoded.isEnabled, mode != false);
    }
    for (final mode in [null, '', '   ', 'x' * 65, 0, [], {}]) {
      route['private'] = mode;
      expect(() => PegarouteQuoteResponse.fromJson(value), throwsA(isA<PegarouteCodecException>()));
    }
  });

  test('binds typed private intent independently of the GET query encoding', () async {
    final uris = <Uri>[];
    final client = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
      get: (uri, headers) async {
        uris.add(uri);
        expect(headers, isEmpty);
        return very_insecure_http_do_not_use.Response(_fixture('quote_private_zk.json'), 200);
      },
    );
    for (final mode in [null, false, true, 'zk', 'future-mode']) {
      final request = PegarouteQuoteRequest(
        fromChain: 'ETH',
        fromToken: 'ETH',
        toChain: 'BTC',
        toToken: 'BTC',
        amount: '1',
        privateValue: mode == null ? null : PegaroutePrivateValue(mode),
      );
      final quote = await client.quote(request);
      expect(uris.last.queryParameters['private'], mode?.toString());
      expect(json.decode(quote.requestJson)['private'], mode ?? false);
      expect(uris.last.queryParameters.containsKey('integrationId'), isFalse);
    }
    final count = uris.length;
    for (final mode in ['true', 'false', ' true ', ' false ', ' zk ']) {
      await expectLater(
        client.quote(PegarouteQuoteRequest(
          fromChain: 'ETH',
          fromToken: 'ETH',
          toChain: 'BTC',
          toToken: 'BTC',
          amount: '1',
          privateValue: PegaroutePrivateValue(mode),
        )),
        throwsA(isA<PegarouteCodecException>()),
      );
    }
    expect(uris, hasLength(count));
  });

  test('omits a refund address equivalent to the normalized sender', () {
    final intent = PegarouteAddressIntent(
      destinationAddress: ' destination ',
      senderAddress: ' sender ',
      refundAddress: 'sender',
    );
    expect(intent.refundAddress, isNull);
  });

  test('does not turn a blank custom refund intent into refund-to-sender', () {
    for (final refund in ['', '   ']) {
      expect(
        () => PegarouteAddressIntent(
          destinationAddress: 'destination',
          senderAddress: 'sender',
          refundAddress: refund,
        ),
        throwsA(isA<PegarouteCodecException>()),
      );
    }
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

    final evm = PegarouteSwapRequest(
      fromChain: 'ETH',
      fromToken: 'ETH',
      toChain: 'BTC',
      toToken: 'BTC',
      amount: '1',
      destinationAddress: 'destination',
      senderAddress: '0xABCDEF0000000000000000000000000000000001',
      refundAddress: '0xabcdef0000000000000000000000000000000001',
    );
    expect(evm.refundAddress, isNull);

    final nonEvm = PegarouteSwapRequest(
      fromChain: 'SOL',
      fromToken: 'SOL',
      toChain: 'BTC',
      toToken: 'BTC',
      amount: '1',
      destinationAddress: 'destination',
      senderAddress: 'SolAddress',
      refundAddress: 'soladdress',
    );
    expect(nonEvm.refundAddress, 'soladdress');
  });

  test('injects transport without exposing credentials', () async {
    final calls = <String>[];
    final client = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
      get: (uri, headers) async {
        calls.add('${uri.path}?${uri.query}');
        expect(headers, isEmpty);
        return very_insecure_http_do_not_use.Response(_fixture('quote.json'), 200);
      },
    );
    final result = await client.quote(
      PegarouteQuoteRequest(
        fromChain: 'ETH',
        fromToken: 'ETH',
        toChain: 'BTC',
        toToken: 'BTC',
        amount: '1',
      ),
    );
    expect(result.response.quoteId, 'quote-fixture');
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
        configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
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
    (status['output'] as Map<String, dynamic>)['amount'] = null;
    expect(() => PegarouteStatusResponse.fromJson(status), throwsA(isA<PegarouteCodecException>()));

    final statusProvider = json.decode(_fixture('status_refund.json')) as Map<String, dynamic>;
    statusProvider['provider'] = null;
    expect(
      () => PegarouteStatusResponse.fromJson(statusProvider),
      throwsA(isA<PegarouteCodecException>()),
    );

    final openOcean = json.decode(_fixture('quote.json')) as Map<String, dynamic>;
    (openOcean['routes'] as List).single['openOceanRoute'] = {
      'dexId': 1,
      'dexCode': 'fixture',
      'dexes': null,
    };
    expect(
      () => PegarouteQuoteResponse.fromJson(openOcean),
      throwsA(isA<PegarouteCodecException>()),
    );

    final openOceanOmitted = json.decode(_fixture('quote.json')) as Map<String, dynamic>;
    (openOceanOmitted['routes'] as List).single['openOceanRoute'] = <String, dynamic>{};
    expect(PegarouteQuoteResponse.fromJson(openOceanOmitted), isA<PegarouteQuoteResponse>());

    final snapshot = json.decode(_fixture('status_refund.json')) as Map<String, dynamic>;
    (snapshot['input'] as Map<String, dynamic>)['instaswapSwapLite'] = null;
    expect(
      () => PegarouteStatusResponse.fromJson(snapshot),
      throwsA(isA<PegarouteCodecException>()),
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

  test('retained wire variants round trip without granting funding capability', () {
    for (final value in _executionVariants().where((v) => !_unsupportedFamilies.contains(v['family']))) {
      final decoded = PegarouteExecution.fromJson(value);
      final restored = PegarouteExecution.fromJson(decoded.toJson());
      expect(restored.toJson(), value);
    }
  });

  for (final family in _unsupportedFamilies) {
    test('rejects unsupported $family execution at the codec boundary', () {
      for (final value in _executionVariants().where((v) => v['family'] == family)) {
        expect(() => PegarouteExecution.fromJson(value), throwsA(isA<PegarouteCodecException>()));
        expect(() => PegarouteExecution(family: family, mode: value['mode'] as String),
            throwsA(isA<PegarouteCodecException>()));
      }
    });
  }
}

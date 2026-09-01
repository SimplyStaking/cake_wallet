import 'dart:convert';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:http/http.dart';

String _fixture(String name) => File('test/exchange/fixtures/pegaroute/$name').readAsStringSync();

void main() {
  test('validates full origins and only permits loopback HTTP', () {
    expect(
        PegarouteConfiguration(baseUrl: 'http://localhost:4000', apiKey: 'test').isValid, isTrue);
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
    expect(swap.execution.mode, 'contract-call');
    expect(swap.execution.value!.baseUnits, '0');
    expect(swap.provider.instaswapSwapLite, isNull);
  });

  test('decodes nested status, refund, and streaming contracts', () {
    final status = PegarouteStatusResponse.fromJson(json.decode(_fixture('status_refund.json')));
    expect(status.internalStatus, 'refunded');
    expect(status.input.refundAddress, isNotNull);
    expect(status.refund!.status, 'completed');
    expect(status.refund!.txHash, 'refund-hash-fixture');
    expect(status.output.txHash, 'output-hash-fixture');
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

  test('omits a refund address equivalent to the normalized sender', () {
    final intent = PegarouteAddressIntent(
      destinationAddress: ' destination ',
      senderAddress: ' sender ',
      refundAddress: 'sender',
    );
    expect(intent.refundAddress, isNull);
  });

  test('injects transport and never exposes credentials in response parsing', () async {
    final calls = <String>[];
    final client = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
      get: (uri, headers) async {
        calls.add('${uri.path}?${uri.query}');
        expect(headers.keys, contains('X-API-Key'));
        return Response(_fixture('quote.json'), 200);
      },
    );
    final result = await client.quote(const PegarouteQuoteRequest(
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

  test('keeps configured but handler-less Pegaroute out of provider I/O', () async {
    var calls = 0;
    final api = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
      get: (uri, headers) async {
        calls++;
        return Response('{}', 500);
      },
    );
    final provider = PegarouteExchangeProvider(apiClient: api);
    expect(provider.isAvailable, isFalse);
    expect(provider.isEnabled, isFalse);
    expect(provider.supportsMemoOrDestinationTag, isFalse);
    expect(
      await provider.fetchRate(
        from: CryptoCurrency.eth,
        to: CryptoCurrency.btc,
        amount: 1,
        isFixedRateMode: false,
        isReceiveAmount: false,
      ),
      0,
    );
    expect(calls, 0);
  });
}

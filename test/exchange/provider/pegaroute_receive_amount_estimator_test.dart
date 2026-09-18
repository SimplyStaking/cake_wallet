import 'dart:async';
import 'dart:convert';

import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_currency_mapper.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_receive_amount_estimator.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/format_fixed.dart';
import 'package:cw_core/parse_fixed.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as very_insecure_http_do_not_use;

final _now = DateTime.utc(2026, 9, 11, 12);
const _usdcId = 'USDC-0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48';

void main() {
  test('solves fee-bearing USDC to XMR in three forward observations with immutable provenance',
      () async {
    // 2 USDC fixed fee plus 50 bps spread on a 0.0018 XMR/USDC rate.
    final harness = _Harness((input, _) => [_route(_feeOutput(input))]);
    final estimate = await harness.estimate(
        intent: PegarouteAddressIntent(
      senderAddress: 'sender',
      destinationAddress: 'recipient',
      refundAddress: 'refund',
    ));

    expect(estimate.requestCount, 3);
    expect(estimate.isEstimate, isTrue);
    expect(estimate.isGuaranteedFixedRate, isFalse);
    expect(estimate.sourceDecimals, 6);
    expect(estimate.destinationDecimals, 12);
    expect(estimate.sourceAsset.chain, 'ETH');
    expect(estimate.sourceAsset.token, _usdcId);
    expect(estimate.destinationAsset.token, 'XMR');
    expect(estimate.requestedReceiveAmount.display, '0.2');
    expect(estimate.requestedReceiveAmount.baseUnits, '200000000000');
    expect(estimate.expectedOutput.display, _feeOutput(estimate.sourceAmount.display));
    expect(BigInt.parse(estimate.expectedOutput.baseUnits),
        greaterThanOrEqualTo(BigInt.from(200000000000)));
    expect(BigInt.parse(estimate.expectedOutput.baseUnits),
        lessThanOrEqualTo(BigInt.from(200200000000)));
    expect(estimate.provider, 'instaswap');
    expect(estimate.quote.response.quoteId, 'quote-3');
    expect(estimate.quote.isBoundTo(harness.client), isTrue);
    expect(estimate.quote.isBoundTo(PegarouteApiClient()), isFalse);
    expect(estimate.quote.response.routes.single, same(estimate.route));
    expect(estimate.request.amount, estimate.sourceAmount.display);
    expect(jsonDecode(estimate.quote.requestJson), {
      ...harness.requests.last.queryParameters,
      'private': false,
    });
    expect(() => estimate.quote.response.routes.clear(), throwsUnsupportedError);
    expect(() => estimate.route.resolvedFee!['feeBps'] = 9000, throwsUnsupportedError);
    expect(estimate.observedAt, _now);
    expect(estimate.quoteExpiresAt, _now.add(const Duration(seconds: 30)));
    for (final request in harness.requests) {
      expect(request.path, '/quote');
      expect(request.queryParameters, {
        'fromChain': 'ETH',
        'fromToken': _usdcId,
        'toChain': 'XMR',
        'toToken': 'XMR',
        'amount': request.queryParameters['amount'],
        'senderAddress': 'sender',
        'destinationAddress': 'recipient',
        'refundAddress': 'refund',
      });
    }
    expect(harness.posts, 0);
  });

  for (final target in ['0.12', '0.24']) {
    test('converges on nonlinear pool pricing plus fees for target $target', () async {
      // Constant product pool with 100,000 USDC / 200 XMR reserves,
      // a 0.3% input fee and 0.002 XMR outbound fee; all integers.
      String pool(String input) {
        final netInput = parseFixed(input, 6) * BigInt.from(997);
        final output =
            BigInt.from(200000000000000) * netInput ~/ (BigInt.from(100000000000000) + netInput) -
                BigInt.from(2000000000);
        return formatFixed(output, 12);
      }

      final harness = _Harness((input, _) => [_route(pool(input))]);
      final result = await harness.estimate(receiveAmount: target);
      final expected = parseFixed(target, 12);
      final observed = parseFixed(pool(result.sourceAmount.display), 12);
      expect(observed, greaterThanOrEqualTo(expected));
      expect(observed - expected, lessThanOrEqualTo(expected ~/ BigInt.from(1000)));
      expect(result.expectedOutput.baseUnits, observed.toString());
      expect(harness.requests.length, lessThanOrEqualTo(4));
      expect(harness.requests.length, greaterThanOrEqualTo(2));
    });
  }

  test('rounds input upward to the native BTC quantum and retains the observed overshoot',
      () async {
    final harness = _Harness(
        (input, _) => [
              _route(
                formatFixed(parseFixed(input, 8) * BigInt.from(3), 6),
              )
            ],
        policy: const PegarouteReceiveEstimatePolicy(maxOvershootBps: 0));
    final result = await harness.provider.estimateReceiveAmount(
      from: CryptoCurrency.btc,
      to: CryptoCurrency.usdc,
      receiveAmount: '1.000001',
      initialSourceAmount: '0.003',
    );
    expect(harness.requests.map((uri) => uri.queryParameters['amount']), ['0.003', '0.00333334']);
    expect(result.sourceAmount.baseUnits, '333334');
    expect(result.expectedOutput.display, '1.000002');
    expect(result.requestedReceiveAmount.display, '1.000001');
    expect(result.rate, closeTo(1.000001 / 0.00333334, 1e-10));
    expect(result.rate, isNot(closeTo(1.000002 / 0.00333334, 1e-6)));
  });

  test('keeps input candidates exact above 2^53 base units with 18 source decimals', () async {
    final harness = _Harness((input, _) => [_route(input)],
        policy: const PegarouteReceiveEstimatePolicy(maxOvershootBps: 0));
    final result = await harness.provider.estimateReceiveAmount(
      from: CryptoCurrency.eth,
      to: CryptoCurrency.weth,
      receiveAmount: '1.000000000000000003',
      initialSourceAmount: '1',
    );
    expect(harness.requests.last.queryParameters['amount'], '1.000000000000000003');
    expect(result.sourceAmount.baseUnits, '1000000000000000003');
    expect(result.expectedOutput.baseUnits, '1000000000000000003');
  });

  test('accepts a seed already within the observed band in one quote', () async {
    final harness = _Harness((_, __) => [_route('0.20001')]);
    final result = await harness.estimate();
    expect(result.requestCount, 1);
    expect(result.sourceAmount.display, '100');
    expect(result.expectedOutput.display, '0.20001');
  });

  test('legacy receive fetchRate uses target/input and keeps forward behavior independent',
      () async {
    final harness = _Harness((input, _) => [_route(_feeOutput(input))]);
    expect(harness.provider.supportsReceiveAmountEstimate, isTrue);
    expect(harness.provider.supportsFixedRate, isFalse);
    final result = await harness.estimate();
    final receiveRate = await harness.provider.fetchRate(
      from: CryptoCurrency.usdc,
      to: CryptoCurrency.xmr,
      amount: 0.2,
      isFixedRateMode: false,
      isReceiveAmount: true,
    );
    expect(receiveRate, result.rate);
    expect(0.2 / receiveRate, closeTo(double.parse(result.sourceAmount.display), 1e-10));
    final before = harness.requests.length;
    final forward = await harness.provider.fetchRate(
      from: CryptoCurrency.usdc,
      to: CryptoCurrency.xmr,
      amount: 100,
      isFixedRateMode: false,
      isReceiveAmount: false,
    );
    expect(harness.requests.length, before + 1);
    expect(forward, double.parse(_feeOutput('100')) / 100);
    for (final receive in [true, false]) {
      expect(
          await harness.provider.fetchRate(
            from: CryptoCurrency.usdc,
            to: CryptoCurrency.xmr,
            amount: 0.2,
            isFixedRateMode: true,
            isReceiveAmount: receive,
          ),
          0);
    }
    expect(harness.requests.length, before + 1);
    expect(harness.posts, 0);
  });

  test('expands legacy scientific notation without introducing binary fractional noise', () async {
    final harness = _Harness((input, _) => [_route(input)]);
    final rate = await harness.provider.fetchRate(
      from: CryptoCurrency.eth,
      to: CryptoCurrency.weth,
      amount: 0.0000001,
      isFixedRateMode: false,
      isReceiveAmount: true,
    );
    expect(rate, greaterThan(0));
    expect(harness.requests.last.queryParameters['amount']!.contains('e'), isFalse);
    expect(harness.requests.length, 2);
  });

  test('uses a returned minimum with native-unit ceiling and no inadmissible interpolation',
      () async {
    final harness = _Harness((input, _) => [
          _route(
            input == '1' ? '0' : '0.2',
            minimum: '100.0000001',
          )
        ]);
    final result = await harness.estimate(initialSourceAmount: '1');
    expect(harness.requests.map((uri) => uri.queryParameters['amount']), ['1', '100.000001']);
    expect(result.sourceAmount.baseUnits, '100000001');
  });

  test('prefers a usable public route to a better quote below its minimum', () async {
    final harness = _Harness((input, _) => [
          _route('1', provider: 'thorchain', minimum: '1000'),
          _route('0.2'),
          _route('100', provider: 'private-route', private: true),
        ]);
    expect((await harness.estimate()).provider, 'instaswap');
    expect(harness.requests, hasLength(1));
  });

  test('stays on the selected route when another provider becomes better', () async {
    final harness = _Harness((input, count) => [
          _route(count == 1 ? '0.01' : '2', provider: 'thorchain'),
          _route(_feeOutput(input)),
        ]);
    final result = await harness.estimate();
    expect(result.provider, 'instaswap');
    expect(result.quote.response.routes.first.provider, 'thorchain');
    expect(result.quote.response.routes.last, same(result.route));
    expect(harness.requests, hasLength(3));
  });

  for (final mutation in <String, void Function(Map<String, Object?>)>{
    'provider': (route) => route['provider'] = 'maya',
    'providerType': (route) => route['providerType'] = 'dex-aggregator',
    'private': (route) => route['private'] = true,
    'inboundAddress': (route) => route['inboundAddress'] = 'new-vault',
    'router': (route) => route['router'] = 'new-router',
    'fee policy': (route) => route['resolvedFee'] = {'feeBps': 200},
  }.entries) {
    test('rejects changed ${mutation.key} instead of switching curves', () async {
      final harness = _Harness((input, count) {
        final route = _route(_feeOutput(input));
        if (count > 1) mutation.value(route);
        return [route];
      });
      await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.routeChanged));
      expect(harness.requests, hasLength(2));
    });
  }

  test('rejects a disappearing selected route without falling back', () async {
    final harness = _Harness((input, count) => count == 1 ? [_route(_feeOutput(input))] : []);
    await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.routeChanged));
    expect(harness.requests, hasLength(2));
  });

  test('retains final informational labels without rejecting the selected provider', () async {
    final harness = _Harness((input, count) => [
          _route(_feeOutput(input))
            ..['subprovider'] = 'partner-$count'
            ..['openOceanRoute'] = {'dexId': count, 'dexCode': 'dex-$count'}
        ]);
    final result = await harness.estimate();
    expect(harness.requests, hasLength(3));
    expect(result.route.subprovider, 'partner-3');
    expect(result.route.openOceanRoute!.dexId, 3);
    expect(result.provider, 'instaswap');
  });

  test('retains amount-dependent memo and fee observations without treating them as order approval',
      () async {
    final harness = _Harness((input, _) => [
          _route(_feeOutput(input))
            ..['memo'] = 'SWAP:XMR.XMR:recipient:${_feeOutput(input)}'
            ..['fees'] = {'affiliate': '0', 'liquidity': input, 'outbound': '0.002', 'total': input}
        ]);
    final result = await harness.estimate();
    expect(result.route.memo, 'SWAP:XMR.XMR:recipient:${result.expectedOutput.display}');
    expect(result.route.fees!.liquidity, result.sourceAmount.display);
    expect(result.isGuaranteedFixedRate, isFalse);
  });

  test('denies a zero output on the previously selected curve', () async {
    final harness = _Harness((_, count) => [_route(count == 1 ? '0.1' : '0')]);
    await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.invalidAmount));
    expect(harness.requests, hasLength(2));
  });

  for (final mode in [true, 'zk', 'false', 'future-mode']) {
    test('rejects private intent $mode before I/O even if the server could echo public', () async {
      final harness = _Harness((_, __) => [_route('0.2')]);
      await expectLater(
          harness.provider.estimateReceiveAmount(
            from: CryptoCurrency.usdc,
            to: CryptoCurrency.xmr,
            receiveAmount: '0.2',
            privateValue: PegaroutePrivateValue(mode),
          ),
          _failure(PegarouteReceiveEstimateFailure.privateIntent));
      expect(harness.requests, isEmpty);
    });
  }

  for (final routes in [
    <Map<String, Object?>>[],
    [_route('0')],
    [_route('0.2', private: true)]
  ]) {
    test('denies empty, zero or private-only quotes $routes', () async {
      final harness = _Harness((_, __) => routes);
      await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.noRoute));
      expect(harness.requests, hasLength(1));
    });
  }

  test('excludes XMR routes with source memos', () async {
    final harness = _Harness((_, __) => [_route('0.2')..['memo'] = 'requires memo']);
    await expectLater(
        harness.provider.estimateReceiveAmount(
          from: CryptoCurrency.xmr,
          to: CryptoCurrency.btc,
          receiveAmount: '0.2',
        ),
        _failure(PegarouteReceiveEstimateFailure.noRoute));
  });

  for (final output in ['0.1', '0.09']) {
    test('denies flat/decreasing outputs as inputs increase ($output)', () async {
      final harness = _Harness((_, count) => [_route(count == 1 ? '0.1' : output)]);
      await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.nonMonotonic));
      expect(harness.requests, hasLength(2));
    });
  }

  test('denies output rising when the source candidate falls', () async {
    final harness = _Harness((_, count) => [_route(count == 1 ? '0.4' : '0.5')]);
    await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.nonMonotonic));
    expect(harness.requests, hasLength(2));
  });

  test('never returns a below-target approximation on request budget exhaustion', () async {
    // Monotonic but capped below the target (an unattainable liquidity curve).
    final harness = _Harness((input, _) {
      final units = parseFixed(input, 6);
      final output = BigInt.from(199000000000) * units ~/ (units + BigInt.from(100000000));
      return [_route(formatFixed(output, 12))];
    });
    await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.noSolution));
    expect(harness.requests, hasLength(4));
  });

  test('does not accept excessive overshoot caused by coarse source rounding', () async {
    final harness =
        _Harness((input, _) => [_route(formatFixed(parseFixed(input, 8) * BigInt.from(1000), 6))]);
    await expectLater(
        harness.provider.estimateReceiveAmount(
          from: CryptoCurrency.btc,
          to: CryptoCurrency.usdc,
          receiveAmount: '0.0001',
          initialSourceAmount: '0.00000001',
        ),
        _failure(PegarouteReceiveEstimateFailure.noSolution));
    expect(harness.requests, hasLength(1));
  });

  test('enforces caller maximum before any candidate GET', () async {
    final harness = _Harness((input, _) => [_route(_feeOutput(input))]);
    await expectLater(harness.estimate(maxSourceAmount: '105'),
        _failure(PegarouteReceiveEstimateFailure.noSolution));
    expect(harness.requests, hasLength(1));
    await expectLater(harness.estimate(maxSourceAmount: '99'),
        _failure(PegarouteReceiveEstimateFailure.noSolution));
    expect(harness.requests, hasLength(1));
  });

  test('does not exceed caller maximum to follow provider minimum', () async {
    final harness = _Harness((_, __) => [_route('0', minimum: '200')]);
    await expectLater(harness.estimate(maxSourceAmount: '150'),
        _failure(PegarouteReceiveEstimateFailure.noSolution));
    expect(harness.requests, hasLength(1));
  });

  test('does not return minimum-deposit overshoot outside the acceptance band', () async {
    final harness = _Harness((_, __) => [_route('0.3', minimum: '100')]);
    await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.noSolution));
    expect(harness.requests, hasLength(1));
  });

  test('a tighter request policy bounds valid but unconverged observations', () async {
    final harness = _Harness((input, _) => [_route(_feeOutput(input))],
        policy: const PegarouteReceiveEstimatePolicy(maxRequests: 1));
    await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.noSolution));
    expect(harness.requests, hasLength(1));
  });

  for (final policy in [
    const PegarouteReceiveEstimatePolicy(maxRequests: 0),
    const PegarouteReceiveEstimatePolicy(maxRequests: 5),
    const PegarouteReceiveEstimatePolicy(timeBudget: Duration.zero),
    const PegarouteReceiveEstimatePolicy(timeBudget: Duration(seconds: 7)),
    const PegarouteReceiveEstimatePolicy(maxOvershootBps: -1),
    const PegarouteReceiveEstimatePolicy(maxOvershootBps: 101),
  ]) {
    test('invalid policy cannot bypass the request/deadline/overshoot ceilings $policy', () async {
      final harness = _Harness((_, __) => [_route('0.2')], policy: policy);
      await expectLater(harness.estimate(), throwsArgumentError);
      expect(harness.requests, isEmpty);
    });
  }

  for (final bad in [
    '',
    '0',
    '-1',
    'NaN',
    'Infinity',
    '1e-3',
    '0.0000000000001',
    '1 XMR',
    '01',
    ' 1'
  ]) {
    test('denies invalid/unrepresentable target "$bad" before transport', () async {
      final harness = _Harness((_, __) => [_route('0.2')]);
      await expectLater(harness.estimate(receiveAmount: bad),
          _failure(PegarouteReceiveEstimateFailure.invalidAmount));
      expect(harness.requests, isEmpty);
    });
  }

  test('denies non-native-precision source seed before transport', () async {
    final harness = _Harness((_, __) => [_route('0.2')]);
    await expectLater(harness.estimate(initialSourceAmount: '100.0000001'),
        _failure(PegarouteReceiveEstimateFailure.invalidAmount));
    expect(harness.requests, isEmpty);
  });

  for (final bad in ['-1', 'NaN', 'Infinity', '0.2000000000001', '1e-3']) {
    test('denies invalid or overprecision observed output $bad', () async {
      final harness = _Harness((_, __) => [_route(bad)]);
      await expectLater(
          harness.estimate(), _failure(PegarouteReceiveEstimateFailure.invalidAmount));
      expect(harness.requests, hasLength(1));
    });
  }

  test('rejects duplicate provider observations', () async {
    final harness = _Harness((_, __) => [_route('0.2'), _route('0.201')]);
    await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.invalidQuote));
  });

  test('rejects reused quote IDs across different candidate amounts', () async {
    final harness = _Harness((input, _) => [_route(_feeOutput(input))],
        editEnvelope: (body, _) => body['quoteId'] = 'reused');
    await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.invalidQuote));
    expect(harness.requests, hasLength(2));
  });

  for (final foreign in [false, true]) {
    test('denies a quote with mismatched ${foreign ? 'client provenance' : 'forward request'}',
        () async {
      final client = _MismatchingClient(foreign: foreign);
      await expectLater(
          PegarouteReceiveAmountEstimator(apiClient: client, clock: () => _now)
              .estimate(from: CryptoCurrency.usdc, to: CryptoCurrency.xmr, receiveAmount: '0.2'),
          _failure(PegarouteReceiveEstimateFailure.invalidQuote));
    });
  }

  test('denies stale quote before returning an otherwise matching output', () async {
    final harness = _Harness((_, __) => [_route('0.2')],
        editEnvelope: (body, _) => body['expiresAt'] = _now.toIso8601String());
    await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.staleQuote));
  });

  test('denies solving with earlier observations that expire during the next request', () async {
    var now = _now;
    final harness = _Harness((input, count) {
      if (count == 2) now = now.add(const Duration(seconds: 31));
      return [_route(_feeOutput(input))];
    }, clock: () => now);
    await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.staleQuote));
    expect(harness.requests, hasLength(2));
  });

  for (final expiry in [
    _now.add(const Duration(seconds: 5)).millisecondsSinceEpoch ~/ 1000,
    _now.add(const Duration(seconds: 5)).millisecondsSinceEpoch / 1000,
    '${_now.add(const Duration(seconds: 5)).millisecondsSinceEpoch ~/ 1000}',
    _now.add(const Duration(seconds: 5)).toIso8601String()
  ]) {
    test('retains earlier valid route expiry $expiry without inventing a deadline', () async {
      final harness = _Harness((_, __) => [_route('0.2')..['expiry'] = expiry]);
      expect((await harness.estimate()).quoteExpiresAt, _now.add(const Duration(seconds: 5)));
    });
  }

  test('denies expired route even when envelope remains fresh', () async {
    final harness =
        _Harness((_, __) => [_route('0.2')..['expiry'] = _now.millisecondsSinceEpoch ~/ 1000]);
    await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.noRoute));
  });

  for (final expiry in ['not-a-date', '2026-09-11T12:00:30', -1, '999999999999999999999999']) {
    test('rejects invalid/ambiguous expiry $expiry', () async {
      final harness = _Harness((_, __) => [_route('0.2')..['expiry'] = expiry]);
      await expectLater(harness.estimate(), _failure(PegarouteReceiveEstimateFailure.invalidQuote));
    });
  }

  for (final lateError in [false, true]) {
    test(
        'deadline stops a hung request and late ${lateError ? 'error' : 'success'} cannot resume the loop',
        () async {
      final pending = Completer<very_insecure_http_do_not_use.Response>();
      var calls = 0;
      final client = PegarouteApiClient(
        configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
        get: (_, __) {
          calls++;
          return pending.future;
        },
      );
      final estimator = PegarouteReceiveAmountEstimator(
          apiClient: client,
          policy: const PegarouteReceiveEstimatePolicy(timeBudget: Duration(milliseconds: 30)),
          clock: () => _now);
      await expectLater(
          estimator.estimate(
              from: CryptoCurrency.usdc, to: CryptoCurrency.xmr, receiveAmount: '0.2'),
          _failure(PegarouteReceiveEstimateFailure.budgetExceeded));
      expect(calls, 1);
      if (lateError) {
        pending.completeError(StateError('late transport error'));
      } else {
        pending.complete(_response(_envelope([_route('0.1')], 1)));
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(calls, 1);
    });
  }

  test('a sequence of timely requests shares one elapsed deadline', () async {
    var calls = 0;
    final client = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
      get: (_, __) async {
        final count = ++calls;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return _response(_envelope([_route(count == 1 ? '0.1' : '0.15')], count));
      },
    );
    final estimator = PegarouteReceiveAmountEstimator(
        apiClient: client,
        policy: const PegarouteReceiveEstimatePolicy(timeBudget: Duration(milliseconds: 100)),
        clock: () => _now);
    await expectLater(
        estimator.estimate(from: CryptoCurrency.usdc, to: CryptoCurrency.xmr, receiveAmount: '0.2'),
        _failure(PegarouteReceiveEstimateFailure.budgetExceeded));
    expect(calls, inInclusiveRange(1, 2));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(calls, lessThanOrEqualTo(2));
  });

  for (final status in [400, 429, 503]) {
    test('propagates quote error $status without retrying or returning a prior approximation',
        () async {
      final harness =
          _Harness((input, _) => [_route(_feeOutput(input))], failAt: 2, failureStatus: status);
      await expectLater(harness.estimate(),
          throwsA(isA<PegarouteApiError>().having((e) => e.httpStatus, 'status', status)));
      expect(harness.requests, hasLength(2));
      expect(
          await harness.provider.fetchRate(
            from: CryptoCurrency.usdc,
            to: CryptoCurrency.xmr,
            amount: 0.2,
            isFixedRateMode: false,
            isReceiveAmount: true,
          ),
          0);
      expect(harness.posts, 0);
    });
  }

  test('unknown token, conflicting chain, and ineligible source fail before I/O', () async {
    final harness = _Harness((_, __) => [_route('0.2')]);
    final unknown = _usdc(contract: '0x0000000000000000000000000000000000000001');
    for (final from in [unknown, _usdc(tag: 'BSC'), CryptoCurrency.avaxc]) {
      await expectLater(
          harness.provider
              .estimateReceiveAmount(from: from, to: CryptoCurrency.xmr, receiveAmount: '0.2'),
          throwsA(anyOf(isA<PegarouteCurrencyException>(), isA<PegarouteUnavailableException>())));
    }
    await expectLater(
        harness.provider
            .estimateReceiveAmount(from: CryptoCurrency.eth, to: unknown, receiveAmount: '1'),
        throwsA(isA<PegarouteCurrencyException>()));
    expect(harness.requests, isEmpty);
  });

  test('canonical decimals override neither forged token nor native metadata', () async {
    final harness = _Harness((_, __) => [_route('0.2')]);
    for (final from in [
      _usdc(decimals: 18),
      _usdc(decimals: -1),
      const CryptoCurrency(title: 'BTC', name: 'btc', decimals: 18)
    ]) {
      await expectLater(
          harness.provider
              .estimateReceiveAmount(from: from, to: CryptoCurrency.xmr, receiveAmount: '0.2'),
          _failure(PegarouteReceiveEstimateFailure.invalidMetadata));
    }
    expect(harness.requests, isEmpty);
  });

  test('snapshots trusted qualified wallet metadata with a canonical catalog identity', () async {
    final harness = _Harness((input, _) => [_route(_feeOutput(input))]);
    final from = _usdc();
    final result = await harness.provider
        .estimateReceiveAmount(from: from, to: CryptoCurrency.xmr, receiveAmount: '0.2');
    from.chainId = 56;
    expect(result.sourceAsset.chain, 'ETH');
    expect(result.sourceDecimals, 6);
    expect(result.request.fromToken, _usdcId);
  });
}

Matcher _failure(PegarouteReceiveEstimateFailure reason) => throwsA(
      isA<PegarouteReceiveEstimateException>().having((e) => e.reason, 'reason', reason),
    );

final class _MismatchingClient extends PegarouteApiClient {
  _MismatchingClient({required this.foreign})
      : super(
          configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
          get: (_, __) async => _response(_envelope([_route('0.2')], 1)),
        );

  final bool foreign;

  @override
  Future<PegarouteValidatedQuote> quote(PegarouteQuoteRequest request) => foreign
      ? PegarouteApiClient(
          configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
          get: (_, __) async => _response(_envelope([_route('0.2')], 1)),
        ).quote(request)
      : super.quote(PegarouteQuoteRequest(
          fromChain: request.toChain,
          fromToken: request.toToken,
          toChain: request.fromChain,
          toToken: request.fromToken,
          amount: request.amount,
        ));
}

String _feeOutput(String input) =>
    formatFixed((parseFixed(input, 6) - BigInt.from(2000000)) * BigInt.from(1791), 12);

Erc20Token _usdc({int decimals = 6, String tag = 'ETH', String? contract}) => Erc20Token(
      name: 'USD Coin',
      symbol: 'USDC',
      contractAddress: contract ?? _usdcId.substring(5),
      decimal: decimals,
      tag: tag,
      chainId: 1,
    );

Map<String, Object?> _route(String output,
        {String provider = 'instaswap', Object private = false, String? minimum}) =>
    {
      'provider': provider,
      'subprovider': 'partner',
      'providerType': 'api-provider',
      'private': private,
      'expectedOutput': output,
      'estimatedTimeSeconds': 120,
      'expiry': null,
      'memo': null,
      'inboundAddress': null,
      'router': null,
      'gasRate': null,
      'minAmount': minimum,
      'fees': {'affiliate': '0', 'liquidity': '0.001', 'outbound': '0.002', 'total': '0.003'},
      'resolvedFee': {'feeBps': 50},
    };

Map<String, Object?> _envelope(List<Map<String, Object?>> routes, int count) => {
      'quoteId': 'quote-$count',
      'expiresAt': _now.add(const Duration(seconds: 30)).toIso8601String(),
      'routes': routes,
      'warnings': <Object>[],
    };

very_insecure_http_do_not_use.Response _response(Map<String, Object?> body, [int status = 200]) =>
    very_insecure_http_do_not_use.Response(jsonEncode(body), status);

final class _Harness {
  _Harness(
    List<Map<String, Object?>> Function(String, int) routes, {
    PegarouteReceiveEstimatePolicy policy = const PegarouteReceiveEstimatePolicy(),
    DateTime Function()? clock,
    void Function(Map<String, Object?>, int)? editEnvelope,
    int? failAt,
    int failureStatus = 503,
  }) {
    client = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
      get: (uri, headers) async {
        expect(headers, isEmpty);
        requests.add(uri);
        final count = requests.length;
        if (failAt != null && count >= failAt) {
          return _response({
            'error': {
              'code': 'PROVIDER_UNAVAILABLE',
              'message': 'unavailable',
              'userMessage': 'unavailable',
              'retryable': true,
              'retryAfterSeconds': 1
            }
          }, failureStatus);
        }
        final body = _envelope(routes(uri.queryParameters['amount']!, count), count);
        editEnvelope?.call(body, count);
        return _response(body);
      },
      post: (_, __, ___) async {
        posts++;
        throw StateError('POST forbidden');
      },
    );
    provider = PegarouteExchangeProvider(
        apiClient: client, receiveEstimatePolicy: policy, quoteClock: clock ?? () => _now);
  }

  final requests = <Uri>[];
  var posts = 0;
  late final PegarouteApiClient client;
  late final PegarouteExchangeProvider provider;

  Future<PegarouteReceiveAmountEstimate> estimate(
          {String receiveAmount = '0.2',
          String? initialSourceAmount,
          String? maxSourceAmount,
          PegarouteAddressIntent? intent}) =>
      provider.estimateReceiveAmount(
          from: CryptoCurrency.usdc,
          to: CryptoCurrency.xmr,
          receiveAmount: receiveAmount,
          initialSourceAmount: initialSourceAmount,
          maxSourceAmount: maxSourceAmount,
          intent: intent);
}

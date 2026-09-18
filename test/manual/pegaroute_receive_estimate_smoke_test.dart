import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_receive_amount_estimator.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/utils/print_verbose.dart';
import 'package:cw_core/utils/proxy_wrapper.dart';
import 'package:cw_core/utils/tor/disabled.dart';
import 'package:flutter_test/flutter_test.dart';

// Opt-in GET-only check against the already-running, authenticated quote proxy.
// flutter test --no-pub \
//   --dart-define=PEGAROUTE_API_BASE_URL=http://127.0.0.1:4002 \
//   --dart-define=PEGAROUTE_RUN_RECEIVE_ESTIMATE_SMOKE=true \
//   test/manual/pegaroute_receive_estimate_smoke_test.dart
void main() {
  test('estimates USDC input for 0.2 XMR using observed forward quotes', () async {
    const proxyUrl = String.fromEnvironment('PEGAROUTE_API_BASE_URL');
    expect(proxyUrl, 'http://127.0.0.1:4002');
    final configuration = PegarouteConfiguration.generated();
    expect(configuration.baseUrl, proxyUrl);
    expect(configuration.isValid, isTrue);

    final previousTor = CakeTor.instance;
    CakeTor.instance = CakeTorDisabled();
    addTearDown(() => CakeTor.instance = previousTor);
    var started = 0;
    var completed = 0;
    final provider = PegarouteExchangeProvider(
      apiClient: PegarouteApiClient(
        configuration: configuration,
        get: (uri, headers) async {
          expect(uri.path, '/quote');
          started++;
          final response = await ProxyWrapper().get(clearnetUri: uri, headers: headers);
          completed++;
          return response;
        },
        post: (_, __, ___) => throw StateError('Live smoke test permits GET only'),
      ),
    );
    final elapsed = Stopwatch()..start();
    final PegarouteReceiveAmountEstimate estimate;
    try {
      estimate = await provider.estimateReceiveAmount(
        from: CryptoCurrency.usdc,
        to: CryptoCurrency.xmr,
        receiveAmount: '0.2',
        maxSourceAmount: '200',
      );
    } finally {
      printV('Pegaroute live estimate attempt: $started forward quotes started, '
          '$completed completed in ${elapsed.elapsedMilliseconds}ms');
    }
    expect(provider.supportsFixedRate, isFalse);
    expect(estimate.isEstimate, isTrue);
    expect(estimate.request.fromChain, 'ETH');
    expect(estimate.request.toChain, 'XMR');
    expect(estimate.request.amount, estimate.sourceAmount.display);
    expect(estimate.requestCount, inInclusiveRange(1, 4));
    final observed = BigInt.parse(estimate.expectedOutput.baseUnits);
    expect(observed, greaterThanOrEqualTo(BigInt.from(200000000000)));
    expect(observed, lessThanOrEqualTo(BigInt.from(200200000000)));
    expect(estimate.rate, greaterThan(0));
    printV('Pegaroute receive estimate: ${estimate.sourceAmount.display} USDC -> '
        '${estimate.expectedOutput.display} XMR for target '
        '${estimate.requestedReceiveAmount.display} XMR; '
        '${estimate.requestCount} forward quotes via ${estimate.provider}; '
        'estimate only, rate=${estimate.rate}');
  }, skip: !const bool.fromEnvironment('PEGAROUTE_RUN_RECEIVE_ESTIMATE_SMOKE'));
}

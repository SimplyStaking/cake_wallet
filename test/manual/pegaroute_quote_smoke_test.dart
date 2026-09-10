import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/utils/print_verbose.dart';
import 'package:cw_core/utils/proxy_wrapper.dart';
import 'package:cw_core/utils/tor/disabled.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quotes 1 ETH to XMR through the configured Cake proxy', () async {
    const proxyUrl = String.fromEnvironment('PEGAROUTE_API_BASE_URL');
    expect(proxyUrl, isNotEmpty, reason: 'Explicitly supply the quote proxy origin');
    final configuration = PegarouteConfiguration.generated();
    expect(configuration.baseUrl, proxyUrl);
    expect(configuration.isValid, isTrue);

    final previousTor = CakeTor.instance;
    CakeTor.instance = CakeTorDisabled();
    addTearDown(() => CakeTor.instance = previousTor);
    final provider = PegarouteExchangeProvider();
    expect(provider.isAvailable, isTrue);
    expect(provider.isExecutionAvailable, isFalse);
    final limits = await provider.fetchLimits(
      from: CryptoCurrency.eth,
      to: CryptoCurrency.xmr,
      isFixedRateMode: false,
    );
    expect(limits, isNotNull);
    expect(limits!.min ?? 0, lessThanOrEqualTo(1));
    final rate = await provider.fetchRate(
      from: CryptoCurrency.eth,
      to: CryptoCurrency.xmr,
      amount: 1,
      isFixedRateMode: false,
      isReceiveAmount: false,
    );
    expect(rate.isFinite, isTrue);
    expect(rate, greaterThan(0));
    printV('Live Pegaroute quote: 1 ETH -> $rate XMR');
  },
      skip: !const bool.fromEnvironment('RUN_PEGAROUTE_QUOTE_SMOKE'),
      timeout: const Timeout(Duration(seconds: 90)));
}

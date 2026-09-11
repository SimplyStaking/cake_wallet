import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cake_wallet/entities/preferences_key.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_provider_preferences.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as very_insecure_http_do_not_use;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences storage;
  late PegarouteProviderPreferences preferences;
  late Map<String, dynamic> quote;
  late PegarouteExchangeProvider provider;
  var decentralizedOnly = false;
  var gets = 0;
  Future<void> Function()? beforeResponse;

  Future<double> rate() => provider.fetchRate(
        from: CryptoCurrency.eth,
        to: CryptoCurrency.usdc,
        amount: 1,
        isFixedRateMode: false,
        isReceiveAmount: false,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await SharedPreferences.getInstance();
    preferences = PegarouteProviderPreferences(storage);
    gets = 0;
    decentralizedOnly = false;
    beforeResponse = null;
    quote = jsonDecode(File('test/exchange/fixtures/pegaroute/quote.json').readAsStringSync())
        as Map<String, dynamic>;
    quote['expiresAt'] = '2099-01-01T00:00:00.000Z';
    final template = Map<String, dynamic>.from(quote['routes'][0] as Map);
    // Deliberately unsorted: selection must use the enabled route's output.
    quote['routes'] = [
      {...template, 'provider': 'instaswap', 'expectedOutput': '12', 'minAmount': '0.005'},
      {...template, 'provider': 'thorchain', 'expectedOutput': '10', 'minAmount': '0.002'},
      {...template, 'provider': 'openocean', 'expectedOutput': '11', 'minAmount': '0.001'},
    ];
    provider = PegarouteExchangeProvider(
      providerPreferences: preferences,
      decentralizedOnly: () => decentralizedOnly,
      apiClient: PegarouteApiClient(
        configuration: const PegarouteConfiguration(baseUrl: 'https://fixture.invalid'),
        get: (uri, headers) async {
          expect(uri.path, '/quote');
          expect(headers, isEmpty);
          gets++;
          await beforeResponse?.call();
          return very_insecure_http_do_not_use.Response(jsonEncode(quote), 200);
        },
        post: (_, __, ___) async => throw StateError('Quote discovery must never create an order'),
      ),
    );
  });

  test('provider choices persist independently and survive reload', () async {
    expect(preferences.states.values, everyElement(true));
    await preferences.setEnabled('instaswap', false);
    await preferences.setEnabled('maya', false);
    final restored = PegarouteProviderPreferences(storage);
    expect(restored.isEnabled('instaswap'), false);
    expect(restored.isEnabled('maya'), false);
    expect(restored.isEnabled('openocean'), true);
    expect(restored.isEnabled('thorchain'), true);
    expect(restored.isEnabled('unknown'), false);
    await expectLater(restored.setEnabled('unknown', true), throwsArgumentError);
  });

  test('malformed preferences do not re-enable excluded providers', () async {
    await storage.setString(PreferencesKey.pegarouteProviderStatesKey, 'broken');
    expect(PegarouteProviderPreferences(storage).states.values, everyElement(false));
    await storage.setString(PreferencesKey.pegarouteProviderStatesKey,
        jsonEncode({'instaswap': 'true', 'maya': false}));
    final restored = PegarouteProviderPreferences(storage);
    expect(restored.isEnabled('instaswap'), false);
    expect(restored.isEnabled('maya'), false);
    expect(restored.isEnabled('thorchain'), true);
  });

  test('discovery selects the highest enabled quote and filters limits', () async {
    expect(await rate(), 12);
    await preferences.setEnabled('instaswap', false);
    expect(await rate(), 11);
    await preferences.setEnabled('openocean', false);
    expect(await rate(), 10);
    final limits = await provider.fetchLimits(
        from: CryptoCurrency.eth, to: CryptoCurrency.usdc, isFixedRateMode: false);
    expect(limits!.min, 0.002);
    await preferences.setEnabled('thorchain', false);
    expect(await rate(), 0);
    expect(
        await provider.fetchLimits(
            from: CryptoCurrency.eth, to: CryptoCurrency.usdc, isFixedRateMode: false),
        isNull);
    await preferences.setEnabled('maya', false);
    final before = gets;
    expect(await rate(), 0);
    expect(gets, before);
  });

  test('decentralized-only excludes Instaswap without erasing its saved preference', () async {
    decentralizedOnly = true;
    expect(await rate(), 11);
    expect(preferences.isEnabled('instaswap'), true);
    decentralizedOnly = false;
    expect(await rate(), 12);
  });

  test('a provider disabled while HTTP is pending cannot supply the returned rate', () async {
    final waiting = Completer<void>();
    beforeResponse = () => waiting.future;
    final pending = rate();
    await preferences.setEnabled('instaswap', false);
    waiting.complete();
    expect(await pending, 11);
  });

  test('receive estimation uses the same enabled-provider choices', () async {
    await preferences.setEnabled('instaswap', false);
    await preferences.setEnabled('openocean', false);
    final estimate = await provider.estimateReceiveAmount(
        from: CryptoCurrency.eth, to: CryptoCurrency.usdc, receiveAmount: '10');
    expect(estimate.provider, 'thorchain');
    expect(estimate.sourceAmount.display, '1');
  });
}

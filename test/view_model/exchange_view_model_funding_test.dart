import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cake_wallet/core/amount_parsing_proxy.dart';
import 'package:cake_wallet/entities/bitcoin_amount_display_mode.dart';
import 'package:cake_wallet/entities/exchange_api_mode.dart';
import 'package:cake_wallet/entities/preferences_key.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/exchange_trade_state.dart';
import 'package:cake_wallet/exchange/limits.dart';
import 'package:cake_wallet/exchange/limits_state.dart';
import 'package:cake_wallet/exchange/provider/exchange_provider.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_provider_preferences.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_creation_failure.dart';
import 'package:cake_wallet/exchange/trade_request.dart';
import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/store/app_store.dart';
import 'package:cake_wallet/store/dashboard/fiat_conversion_store.dart';
import 'package:cake_wallet/store/dashboard/trades_store.dart';
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cake_wallet/store/templates/exchange_template_store.dart';
import 'package:cake_wallet/view_model/contact_list/contact_list_view_model.dart';
import 'package:cake_wallet/view_model/exchange/exchange_view_model.dart';
import 'package:cake_wallet/view_model/send/fees_view_model.dart';
import 'package:cake_wallet/view_model/unspent_coins/unspent_coins_list_view_model.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/db/sqlite.dart' as sqlite;
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/exceptions.dart';
import 'package:cw_core/transaction_history.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as very_insecure_http_do_not_use;
import 'package:mobx/mobx.dart' show ObservableMap;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

class _AppStore extends Mock implements AppStore {}

class _SettingsStore extends Mock implements SettingsStore {}

class _Wallet extends Mock
    implements WalletBase<Balance, TransactionHistoryBase<TransactionInfo>, TransactionInfo> {}

class _WalletAddresses extends Mock implements WalletAddresses {}

class _ExchangeTemplateStore extends Mock implements ExchangeTemplateStore {}

class _ContactListViewModel extends Mock implements ContactListViewModel {}

class _FeesViewModel extends Mock implements FeesViewModel {}

class _UnspentCoinsListViewModel extends Mock implements UnspentCoinsListViewModel {}

class _Database extends Mock implements Database {}

class _TradesStore extends Mock implements TradesStore {
  final stored = <Trade>[];

  @override
  void setTrade(Trade trade) => stored.add(trade);
}

class _Balance extends Balance {
  _Balance() : super(Money.parse('1', CryptoCurrency.eth), Money.zero(CryptoCurrency.eth));
}

// Persistence is outside the provider-selection behavior under test.
class _Trade extends Trade {
  _Trade(ExchangeProviderDescription provider, {this.saveError})
      : super(id: '${provider.title}-trade', amount: '1', provider: provider);

  final Object? saveError;
  int saves = 0;

  @override
  Future<int> save() async {
    saves++;
    if (saveError != null) throw saveError!;
    return 1;
  }
}

class _Provider extends ExchangeProvider {
  _Provider(this.description, {required this.rate, this.error, Object? saveError})
      : trade = _Trade(description, saveError: saveError);

  @override
  final ExchangeProviderDescription description;
  final double rate;
  final Object? error;
  final _Trade trade;
  final requests = <TradeRequest>[];
  Future<Limits?>? nextLimits;
  Future<double>? nextRate;
  final quotedAmounts = <double>[];

  @override
  String get title => description.title;

  @override
  bool get isAvailable => true;

  @override
  bool get isEnabled => true;

  @override
  bool get supportsFixedRate => true;

  @override
  bool get createsOrderBeforeReturning => true;

  @override
  Future<bool> checkIsAvailable() async => true;

  @override
  Future<Limits?> fetchLimits({
    required CryptoCurrency from,
    required CryptoCurrency to,
    required bool isFixedRateMode,
  }) async =>
      await (nextLimits ?? Future.value(Limits(min: 0.1, max: 100)));

  @override
  Future<double> fetchRate({
    required CryptoCurrency from,
    required CryptoCurrency to,
    required double amount,
    required bool isFixedRateMode,
    required bool isReceiveAmount,
  }) async {
    quotedAmounts.add(amount);
    return await (nextRate ?? Future.value(rate));
  }

  @override
  Future<Trade> createTrade({
    required TradeRequest request,
    required bool isFixedRateMode,
    required bool isSendAll,
  }) async {
    requests.add(request);
    if (error != null) throw error!;
    return trade;
  }

  @override
  Future<Trade> findTradeById({required String id}) async => throw UnimplementedError();
}

final class _CreationFailure implements Exception, TradeCreationFailure {
  const _CreationFailure(this.boundary);

  @override
  final TradeCreationFailureBoundary boundary;

  @override
  String get userMessage => 'The provider may have created this order.';
}

// Suppress constructor quote loading until the offline providers are installed.
// Both rate ordering and createTrade then run their production implementations.
class _OfflineExchangeViewModel extends ExchangeViewModel {
  _OfflineExchangeViewModel(
    AppStore appStore,
    TradesStore tradesStore,
    SharedPreferences preferences,
    UnspentCoinsListViewModel unspentCoins,
  ) : super(
          appStore,
          _ExchangeTemplateStore(),
          tradesStore,
          preferences,
          _ContactListViewModel(),
          unspentCoins,
          _FeesViewModel(),
          FiatConversionStore()..prices[CryptoCurrency.xmr] = 1,
        );

  bool fixturesReady = false;

  @override
  Future<void> loadLimits() async {
    if (fixturesReady) await super.loadLimits();
  }

  @override
  Future<void> calculateBestRate() async {
    if (fixturesReady) await super.calculateBestRate();
  }
}

Future<_OfflineExchangeViewModel> _viewModel(
  List<ExchangeProvider> providers, {
  CryptoCurrency depositCurrency = CryptoCurrency.eth,
  CryptoCurrency receiveCurrency = CryptoCurrency.xmr,
  bool initialQuoteExpected = true,
}) async {
  final preferences = await SharedPreferences.getInstance();
  final appStore = _AppStore();
  final settingsStore = _SettingsStore();
  final wallet = _Wallet();
  final addresses = _WalletAddresses();
  final unspentCoins = _UnspentCoinsListViewModel();

  when(() => appStore.wallet).thenReturn(wallet);
  when(() => appStore.settingsStore).thenReturn(settingsStore);
  when(() => appStore.amountParsingProxy)
      .thenReturn(const AmountParsingProxy(BitcoinAmountDisplayMode.bitcoin));
  when(() => settingsStore.exchangeStatus).thenReturn(ExchangeApiMode.enabled);
  when(() => settingsStore.forceDecentralizedExchanges).thenReturn(false);
  when(() => settingsStore.pegarouteProviderPreferences)
      .thenReturn(PegarouteProviderPreferences(preferences));
  when(() => settingsStore.trocadorProviderStates).thenReturn(ObservableMap<String, bool>());
  when(() => wallet.type).thenReturn(WalletType.ethereum);
  when(() => wallet.currency).thenReturn(CryptoCurrency.eth);
  when(() => wallet.id).thenReturn('wallet-id');
  when(() => wallet.chainId).thenReturn(1);
  when(() => wallet.balance)
      .thenReturn(ObservableMap<CryptoCurrency, Balance>.of({CryptoCurrency.eth: _Balance()}));
  when(() => wallet.walletAddresses).thenReturn(addresses);
  when(() => addresses.addressForExchange).thenReturn('source-address');
  when(() => addresses.address).thenReturn('source-address');
  when(() => unspentCoins.initialSetup()).thenAnswer((_) async {});

  final viewModel = _OfflineExchangeViewModel(appStore, _TradesStore(), preferences, unspentCoins);
  addTearDown(viewModel.dispose);
  for (final provider in viewModel.selectedProviders.toList()) {
    viewModel.removeExchangeProvider(provider);
  }
  viewModel.providerList = providers;
  viewModel.provider = providers.first;
  for (final provider in providers) {
    viewModel.addExchangeProvider(provider);
  }
  viewModel.depositCurrency = depositCurrency;
  viewModel.receiveCurrency = receiveCurrency;
  viewModel.receiveAddress = 'destination-address';
  viewModel.fixturesReady = true;
  await viewModel.loadLimits();
  await viewModel.calculateBestRate();
  await viewModel.changeDepositAmount(amount: '1', isCanonical: true);
  expect(viewModel.forcedProvider, isNull);
  expect(viewModel.bestRateProvider, initialQuoteExpected ? same(providers.first) : isNull);
  return viewModel;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    S.current = const S();
  });

  setUp(() {
    // Constructor token discovery sees an empty wallet catalog. Trocador and
    // fiat discovery are disabled/cached so no real provider requests occur.
    SharedPreferences.setMockInitialValues({
      PreferencesKey.exchangeProvidersSelection: '{"Trocador":false}',
    });
    final previousDatabase = sqlite.db;
    final database = _Database();
    when(() => database.query(
          WalletInfo.tableName,
          where: '1 = 1',
          whereArgs: null,
          orderBy: 'sortOrder',
        )).thenAnswer((_) async => <Map<String, Object?>>[]);
    sqlite.db = database;
    addTearDown(() => sqlite.db = previousDatabase);
  });

  test('provider preference change clears old minimum while refreshing, including failure',
      () async {
    final provider = _Provider(ExchangeProviderDescription.changeNow, rate: 2);
    final viewModel = await _viewModel([provider]);
    viewModel.limits = Limits(min: 12, max: null);
    final response = Completer<Limits?>();
    provider.nextLimits = response.future;
    await viewModel.pegarouteProviderPreferences.setEnabled('instaswap', false);
    expect(viewModel.limitsState, isA<LimitsIsLoading>());
    expect(viewModel.limits.min, isNull);
    expect(viewModel.bestRateProvider, isNull);
    response.complete(null);
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.limitsState, isA<LimitsLoadedFailure>());
    expect(viewModel.limits.min, isNull);
    expect(provider.requests, isEmpty);
  });

  test('an older limit response cannot overwrite the current refreshed limits', () async {
    final provider = _Provider(ExchangeProviderDescription.changeNow, rate: 2);
    final viewModel = await _viewModel([provider]);
    final older = Completer<Limits?>();
    provider.nextLimits = older.future;
    final firstLoad = viewModel.loadLimits();
    final newer = Completer<Limits?>();
    provider.nextLimits = newer.future;
    final secondLoad = viewModel.loadLimits();
    newer.complete(Limits(min: 0, max: null));
    await secondLoad;
    older.complete(Limits(min: 12, max: null));
    await firstLoad;
    expect(viewModel.limits.min, 0);
    expect(provider.requests, isEmpty);
  });

  test('an in-flight rate cannot restore a quote while its limits are being refreshed', () async {
    final provider = _Provider(ExchangeProviderDescription.changeNow, rate: 2);
    final viewModel = await _viewModel([provider]);
    final rateResponse = Completer<double>();
    provider.nextRate = rateResponse.future;
    final oldQuote = viewModel.calculateBestRate();
    final limitResponse = Completer<Limits?>();
    provider.nextLimits = limitResponse.future;
    final reload = viewModel.loadLimits();
    expect(viewModel.bestRateProvider, isNull);
    rateResponse.complete(2);
    await oldQuote;
    expect(viewModel.bestRateProvider, isNull);
    limitResponse.complete(Limits(min: 0, max: null));
    await reload;
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.bestRateProvider, same(provider));
    expect(provider.requests, isEmpty);
  });

  test('empty refresh clears the best provider, displayed rate and calculated output', () async {
    final provider = _Provider(ExchangeProviderDescription.pegaroute, rate: 2384);
    final viewModel = await _viewModel([provider]);
    viewModel.providerDisplay = provider;
    provider.nextRate = Future.value(0);
    await viewModel.calculateBestRate();
    expect(viewModel.noProviderForPair, isTrue);
    expect(viewModel.bestRate, 0);
    expect(viewModel.bestRateProvider, isNull);
    expect(viewModel.providerDisplay, isNull);
    expect(viewModel.receiveAmount, isEmpty);
    expect(viewModel.depositAmount, '1');
  });

  test('amount edits query the entered amount instead of scaling the initial comparison', () async {
    final provider = _Provider(ExchangeProviderDescription.pegaroute, rate: 2384);
    final viewModel = await _viewModel([provider]);
    provider.nextLimits = Future.value(Limits(min: 0, max: null));
    await viewModel.loadLimits();
    final pending = Completer<double>();
    provider.nextRate = pending.future;
    final refresh = viewModel.changeDepositAmount(amount: '0.002', isCanonical: true);
    expect(provider.quotedAmounts.last, 0.002);
    expect(viewModel.bestRate, 0);
    expect(viewModel.receiveAmount, isEmpty);
    pending.complete(0);
    await refresh;
    expect(viewModel.noProviderForPair, isTrue);
    expect(viewModel.receiveAmount, isEmpty);
    expect(provider.requests, isEmpty);
  });

  test('an older same-input quote cannot replace a newer unavailable result', () async {
    final provider = _Provider(ExchangeProviderDescription.pegaroute, rate: 2);
    final viewModel = await _viewModel([provider]);
    final older = Completer<double>();
    provider.nextRate = older.future;
    final refresh = viewModel.calculateBestRate();
    provider.nextRate = Future.value(0);
    await viewModel.calculateBestRate();
    older.complete(20);
    await refresh;
    expect(viewModel.noProviderForPair, isTrue);
    expect(viewModel.bestRate, 0);
  });

  test('a quote for an older amount cannot replace the current amount result', () async {
    final provider = _Provider(ExchangeProviderDescription.changeNow, rate: 2);
    final viewModel = await _viewModel([provider]);
    final older = Completer<double>();
    provider.nextRate = older.future;
    final first = viewModel.changeDepositAmount(amount: '2', isCanonical: true);
    provider.nextRate = Future.value(3);
    await viewModel.changeDepositAmount(amount: '3', isCanonical: true);
    older.complete(20);
    await first;
    expect(viewModel.bestRate, 3);
    expect(viewModel.depositAmount, '3');
    expect(viewModel.receiveAmount, '9');
  });

  test('a removed provider cannot reappear when its old quote completes', () async {
    final first = _Provider(ExchangeProviderDescription.pegaroute, rate: 3);
    final second = _Provider(ExchangeProviderDescription.exolix, rate: 2);
    final viewModel = await _viewModel([first, second]);
    final older = Completer<double>();
    first.nextRate = older.future;
    final refresh = viewModel.calculateBestRate();
    viewModel.removeExchangeProvider(first);
    await viewModel.calculateBestRate();
    older.complete(10);
    await refresh;
    expect(viewModel.bestRateProvider, same(second));
    expect(viewModel.bestRate, 2);
  });

  test('failed provider quotes are isolated and an all-failed refresh clears stale output',
      () async {
    final first = _Provider(ExchangeProviderDescription.pegaroute, rate: 3);
    final second = _Provider(ExchangeProviderDescription.exolix, rate: 2);
    final viewModel = await _viewModel([first, second]);
    first.nextRate = Future.error(StateError('transport failed'));
    await viewModel.calculateBestRate();
    expect(viewModel.bestRateProvider, same(second));
    first.nextRate = Future.error(StateError('transport failed'));
    second.nextRate = Future.value(0);
    await viewModel.calculateBestRate();
    expect(viewModel.bestRateProvider, isNull);
    expect(viewModel.receiveAmount, isEmpty);
  });

  test('automatic comparison keeps the higher Exolix rate over a lower Pegaroute rate', () async {
    final exolix = _Provider(ExchangeProviderDescription.exolix, rate: 3);
    final pegaroute = _Provider(ExchangeProviderDescription.pegaroute, rate: 2);
    final viewModel = await _viewModel([exolix, pegaroute]);
    pegaroute.nextRate = Future.value(2.5);
    await viewModel.calculateBestRate();
    expect(viewModel.bestRateProvider, same(exolix));
    expect(viewModel.bestRate, 3);
    expect(viewModel.receiveAmount, '3');
  });

  test('unavailable quotes use the existing Cake error instead of an invalid-output error',
      () async {
    final provider = _Provider(ExchangeProviderDescription.pegaroute, rate: 2);
    final viewModel = await _viewModel([provider]);
    provider.nextRate = Future.value(0);
    await viewModel.calculateBestRate();
    await viewModel.createTrade();
    expect((viewModel.tradeState as TradeIsCreatedFailure).error,
        S.current.none_of_selected_providers_can_exchange);
    expect(provider.requests, isEmpty);
  });

  test('clearing the input invalidates an in-flight quote and its output', () async {
    final provider = _Provider(ExchangeProviderDescription.changeNow, rate: 2);
    final viewModel = await _viewModel([provider]);
    final pending = Completer<double>();
    provider.nextRate = pending.future;
    final refresh = viewModel.calculateBestRate();
    await viewModel.changeDepositAmount(amount: '');
    pending.complete(2);
    await refresh;
    expect(viewModel.bestRateProvider, isNull);
    expect(viewModel.depositAmount, isEmpty);
    expect(viewModel.receiveAmount, isEmpty);
    expect(viewModel.isFetchingRate, isFalse);
  });

  test('a pair change rejects the previous quote while new limits are loading', () async {
    final provider = _Provider(ExchangeProviderDescription.changeNow, rate: 2);
    final viewModel = await _viewModel([provider]);
    final pending = Completer<double>();
    provider.nextRate = pending.future;
    final refresh = viewModel.calculateBestRate();
    final limits = Completer<Limits?>();
    provider.nextLimits = limits.future;
    viewModel.fiatConversionStore.prices[CryptoCurrency.usdcArb] = 1;
    viewModel.fixturesReady = false;
    viewModel.changeReceiveCurrency(currency: CryptoCurrency.usdcArb);
    viewModel.fixturesReady = true;
    final reload = viewModel.loadLimits();
    pending.complete(2);
    await refresh;
    expect(viewModel.bestRateProvider, isNull);
    expect(viewModel.receiveAmount, isEmpty);
    provider.nextRate = Future.value(3);
    limits.complete(Limits(min: 0, max: null));
    await reload;
    expect(viewModel.bestRate, 3);
    expect(viewModel.receiveAmount, '3');
  });

  test('a stale provider-settings failure cannot overwrite a successful refresh', () async {
    final provider = _Provider(ExchangeProviderDescription.changeNow, rate: 2);
    final viewModel = await _viewModel([provider]);
    final pending = Completer<double>();
    provider.nextRate = pending.future;
    final refresh = viewModel.calculateBestRate();
    provider.nextRate = Future.value(3);
    await viewModel.pegarouteProviderPreferences.setEnabled('instaswap', false);
    await Future<void>.delayed(Duration.zero);
    pending.completeError(StateError('old transport error'));
    await refresh;
    expect(viewModel.bestRate, 3);
    expect(viewModel.noProviderForPair, isFalse);
  });

  test('an unavailable forced provider is not presented as a usable automatic quote', () async {
    final exolix = _Provider(ExchangeProviderDescription.exolix, rate: 3);
    final pegaroute = _Provider(ExchangeProviderDescription.pegaroute, rate: 2);
    final viewModel = await _viewModel([exolix, pegaroute]);
    pegaroute.nextRate = Future.value(0);
    viewModel.setForcedProvider(pegaroute);
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.forcedProviderRate, 0);
    expect(viewModel.noProviderForPair, isTrue);
    expect(viewModel.receiveAmount, isEmpty);
    await viewModel.createTrade();
    expect((viewModel.tradeState as TradeIsCreatedFailure).error,
        S.current.none_of_selected_providers_can_exchange);
    expect(exolix.requests, isEmpty);
    expect(pegaroute.requests, isEmpty);
    viewModel.setForcedProvider(null);
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.bestRateProvider, same(exolix));
    expect(viewModel.noProviderForPair, isFalse);
    expect(viewModel.receiveAmount, '3');
  });

  test('same-value UI reactions do not re-request unavailable quotes', () async {
    final provider = _Provider(ExchangeProviderDescription.changeNow, rate: 2);
    final viewModel = await _viewModel([provider]);
    provider.nextRate = Future.value(0);
    await viewModel.calculateBestRate();
    final requests = provider.quotedAmounts.length;
    await viewModel.changeDepositAmount(amount: '1.0', isCanonical: true);
    expect(provider.quotedAmounts, hasLength(requests));
    expect(viewModel.receiveAmount, isEmpty);
  });

  test('receive-target mode preserves the entered side when its quote disappears', () async {
    final provider = _Provider(ExchangeProviderDescription.changeNow, rate: 2);
    final viewModel = await _viewModel([provider]);
    viewModel.isFixedRateMode = true;
    await viewModel.changeReceiveAmount(amount: '4', isCanonical: true);
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.depositAmount, '2');
    provider.nextRate = Future.value(0);
    await viewModel.calculateBestRate();
    expect(viewModel.receiveAmount, '4');
    expect(viewModel.depositAmount, isEmpty);
    expect(viewModel.noProviderForPair, isTrue);
  });

  test('provider errors use the existing Cake message after safe fallback is exhausted', () async {
    final first = _Provider(ExchangeProviderDescription.pegaroute,
        rate: 3,
        error: const PegarouteApiError(
            httpStatus: 400,
            code: 'AMOUNT_TOO_LOW',
            message: 'upstream diagnostic',
            userMessage: 'Instaswap: Minimum: 1.1 ETH.',
            retryable: false));
    final second = _Provider(ExchangeProviderDescription.exolix,
        rate: 2, error: StateError('ordinary provider failure'));
    final viewModel = await _viewModel([first, second]);
    await viewModel.createTrade();
    expect(first.requests, hasLength(1));
    expect(second.requests, hasLength(1));
    expect((viewModel.tradeState as TradeIsCreatedFailure).error,
        S.current.none_of_selected_providers_can_exchange);
  });

  test('Pegaroute quotes retain exact Money amounts and skip precision-failed routes', () async {
    final quote = jsonDecode(File('test/exchange/fixtures/pegaroute/quote.json').readAsStringSync())
        as Map<String, dynamic>;
    quote['expiresAt'] = '2099-01-01T00:00:00.000Z';
    final route = Map<String, dynamic>.from((quote['routes'] as List).first as Map)
      ..['provider'] = 'instaswap'
      ..['minAmount'] = null
      ..['expectedOutput'] = '7';
    final amounts = <String>[];
    var allFailed = false;
    var posts = 0;
    final provider = PegarouteExchangeProvider(
        apiClient: PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://fixture.invalid'),
      get: (uri, headers) async {
        amounts.add(uri.queryParameters['amount']!);
        return very_insecure_http_do_not_use.Response(
            jsonEncode({
              ...quote,
              'routes': allFailed ? <Object>[] : [route],
              'warnings': [
                for (final failed in ['openocean', if (allFailed) 'instaswap'])
                  {
                    'provider': failed,
                    'code': 'AMOUNT_PRECISION_EXCEEDED',
                    'message': 'Source amount exceeds provider precision.',
                    'userMessage': 'Too many decimal places.',
                    'details': {'maxAmountDecimals': 8},
                  },
              ],
            }),
            200);
      },
      post: (_, __, ___) async {
        posts++;
        throw StateError('Precision failures must not create an order');
      },
    ));
    final viewModel = await _viewModel([provider]);
    for (final amount in ['0.1', '0.123456789123456789']) {
      amounts.clear();
      await viewModel.changeDepositAmount(amount: amount, isCanonical: true);
      expect(amounts, [amount]);
      expect(viewModel.bestRateProvider, same(provider));
      expect(viewModel.noProviderForPair, isFalse);
      expect(viewModel.receiveAmount, isNotEmpty);
    }

    allFailed = true;
    amounts.clear();
    await viewModel.calculateBestRate();
    expect(amounts, ['0.123456789123456789']);
    expect(viewModel.bestRateProvider, isNull);
    expect(viewModel.noProviderForPair, isTrue);
    expect(viewModel.receiveAmount, isEmpty);
    await viewModel.createTrade();
    expect((viewModel.tradeState as TradeIsCreatedFailure).error,
        S.current.none_of_selected_providers_can_exchange);
    expect(posts, 0);
    expect(amounts, ['0.123456789123456789']);
  });

  test('a missing 1-unit Pegaroute limit does not suppress actual-amount discovery', () async {
    final quote = jsonDecode(File('test/exchange/fixtures/pegaroute/quote.json').readAsStringSync())
        as Map<String, dynamic>;
    quote['expiresAt'] = '2099-01-01T00:00:00.000Z';
    final routes = quote['routes'];
    final amounts = <String>[];
    final provider = PegarouteExchangeProvider(
        apiClient: PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://fixture.invalid'),
      get: (uri, headers) async {
        final amount = uri.queryParameters['amount']!;
        amounts.add(amount);
        return very_insecure_http_do_not_use.Response(
            jsonEncode({
              ...quote,
              'routes': amount == '0.003' ? routes : <Object>[],
              'warnings': amount == '0.003'
                  ? <Object>[]
                  : [
                      {
                        'provider': 'instaswap',
                        'code': 'PROVIDER_UNAVAILABLE',
                        'message': 'private diagnostic',
                        'userMessage': 'Temporarily unavailable.'
                      }
                    ],
            }),
            200);
      },
      post: (_, __, ___) async => throw StateError('Discovery must not create an order'),
    ));
    final viewModel = await _viewModel([provider], initialQuoteExpected: false);
    expect(viewModel.limitsState, isA<LimitsLoadedFailure>());
    await viewModel.createTrade();
    expect((viewModel.tradeState as TradeIsCreatedFailure).error,
        S.current.none_of_selected_providers_can_exchange);
    await viewModel.changeDepositAmount(amount: '0.003', isCanonical: true);
    expect(amounts.last, '0.003');
    expect(viewModel.bestRateProvider, same(provider));
    expect(viewModel.noProviderForPair, isFalse);
    expect(viewModel.receiveAmount, isNotEmpty);
  });

  test('unavailable swaps use the same Cake error with Pegaroute enabled or disabled', () async {
    final quote = jsonDecode(File('test/exchange/fixtures/pegaroute/quote.json').readAsStringSync())
        as Map<String, dynamic>;
    quote['expiresAt'] = '2099-01-01T00:00:00.000Z';
    final route = Map<String, dynamic>.from((quote['routes'] as List).first as Map)
      ..['minAmount'] = null
      ..['expectedOutput'] = '7';
    final quotedAmounts = <String>[];
    final pegaroute = PegarouteExchangeProvider(
        apiClient: PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://fixture.invalid'),
      get: (uri, headers) async {
        final amount = uri.queryParameters['amount']!;
        quotedAmounts.add(amount);
        return very_insecure_http_do_not_use.Response(
            jsonEncode({
              ...quote,
              'routes': double.parse(amount) >= 0.003 ? [route] : <Object>[],
              'warnings': [
                {
                  'provider': 'instaswap',
                  'code': 'AMOUNT_TOO_LOW',
                  'message': 'internal upstream diagnostic',
                  'userMessage': 'Minimum: 0.002049625039184008 ETH.'
                },
                {
                  'provider': 'openocean',
                  'code': 'UNSUPPORTED_PAIR',
                  'message': 'internal upstream diagnostic',
                  'userMessage': 'Unsupported pair.'
                },
              ],
            }),
            200);
      },
      post: (_, __, ___) async => throw StateError('Discovery must not create an order'),
    ));
    final other = _Provider(ExchangeProviderDescription.exolix, rate: 0);
    final viewModel = await _viewModel([pegaroute, other], receiveCurrency: CryptoCurrency.usdcArb);
    await viewModel.changeDepositAmount(amount: '0.002', isCanonical: true);
    expect(quotedAmounts.last, '0.002');
    expect(viewModel.noProviderForPair, isTrue);
    expect(viewModel.bestRateProvider, isNull);
    expect(viewModel.receiveAmount, isEmpty);
    await viewModel.createTrade();
    expect((viewModel.tradeState as TradeIsCreatedFailure).error,
        S.current.none_of_selected_providers_can_exchange);

    viewModel.removeExchangeProvider(pegaroute);
    await viewModel.loadLimits();
    await viewModel.createTrade();
    expect((viewModel.tradeState as TradeIsCreatedFailure).error,
        S.current.none_of_selected_providers_can_exchange);
    expect(viewModel.receiveAmount, isEmpty);

    viewModel.addExchangeProvider(pegaroute);
    await viewModel.loadLimits();
    await viewModel.changeDepositAmount(amount: '0.003', isCanonical: true);
    expect(quotedAmounts.last, '0.003');
    expect(viewModel.noProviderForPair, isFalse);
    expect(viewModel.bestRateProvider, same(pegaroute));
    expect(viewModel.receiveAmount, '7');
    expect(other.requests, isEmpty);
  });

  test('a timed-out quote clears the old provider and uses the existing unavailable error',
      () async {
    final provider = _Provider(ExchangeProviderDescription.changeNow, rate: 2);
    final viewModel = await _viewModel([provider]);
    final pending = Completer<double>();
    provider.nextRate = pending.future;
    await viewModel.calculateBestRate();
    expect(viewModel.isFetchingRate, isFalse);
    expect(viewModel.bestRateProvider, isNull);
    await viewModel.createTrade();
    expect((viewModel.tradeState as TradeIsCreatedFailure).error,
        S.current.none_of_selected_providers_can_exchange);
    pending.complete(3);
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.bestRate, 0);
  });

  test('wallet balance failure stops automatic selection with a localized error', () async {
    final first = _Provider(
      ExchangeProviderDescription.changeNow,
      rate: 2,
      error: TransactionWrongBalanceException(CryptoCurrency.eth),
    );
    final second = _Provider(ExchangeProviderDescription.exolix, rate: 1);
    final viewModel = await _viewModel([first, second]);

    await viewModel.createTrade();

    expect(first.requests, hasLength(1));
    expect(second.requests, isEmpty);
    final failure = viewModel.tradeState as TradeIsCreatedFailure;
    expect(failure.title, S.current.trade_not_created);
    expect(failure.error, S.current.tx_wrong_balance_exception(CryptoCurrency.eth.toString()));
    expect((viewModel.tradesStore as _TradesStore).stored, isEmpty);
  });

  test('balance failure shows exact required, available and one-wei shortfall', () async {
    final first = _Provider(
      ExchangeProviderDescription.changeNow,
      rate: 2,
      error: TransactionWrongBalanceException(
        CryptoCurrency.eth,
        requiredBalance: Money.parse('1.000000000000000001', CryptoCurrency.eth),
        availableBalance: Money.parse('1', CryptoCurrency.eth),
      ),
    );
    final second = _Provider(ExchangeProviderDescription.exolix, rate: 1);
    final viewModel = await _viewModel([first, second]);

    await viewModel.createTrade();

    expect(first.requests, hasLength(1));
    expect(second.requests, isEmpty);
    final error = (viewModel.tradeState as TradeIsCreatedFailure).error;
    expect(error, startsWith(S.current.tx_wrong_balance_exception(CryptoCurrency.eth.toString())));
    expect(error, contains('${S.current.transaction_cost}: 1.000000000000000001 ETH'));
    expect(error, contains('${S.current.available_balance}: 1 ETH'));
    expect(error, contains('${S.current.overshot}: 0.000000000000000001 ETH'));
  });

  test('token source shortage keeps its currency and precision without provider fallback',
      () async {
    final token = Erc20Token(
      name: 'USD Coin',
      symbol: 'USDC',
      contractAddress: '0x1111111111111111111111111111111111111111',
      decimal: 6,
      chainId: 1,
      tag: 'ETH',
    );
    final first = _Provider(
      ExchangeProviderDescription.changeNow,
      rate: 2,
      error: TransactionWrongBalanceException(
        token,
        requiredBalance: Money.parse('1', token),
        availableBalance: Money.parse('0.999999', token),
      ),
    );
    final second = _Provider(ExchangeProviderDescription.exolix, rate: 1);
    final viewModel = await _viewModel([first, second], depositCurrency: token);

    await viewModel.createTrade();

    expect(first.requests, hasLength(1));
    expect(first.requests.single.fromCurrency, token);
    expect(second.requests, isEmpty);
    final error = (viewModel.tradeState as TradeIsCreatedFailure).error;
    expect(error, startsWith(S.current.tx_wrong_balance_exception(token.toString())));
    expect(error, contains('${S.current.transaction_cost}: 1 USDC'));
    expect(error, contains('${S.current.available_balance}: 0.999999 USDC'));
    expect(error, contains('${S.current.overshot}: 0.000001 USDC'));
  });

  test('inconsistent funding currencies still stop fallback with the base localized error',
      () async {
    final first = _Provider(
      ExchangeProviderDescription.changeNow,
      rate: 2,
      error: TransactionWrongBalanceException(
        CryptoCurrency.eth,
        requiredBalance: Money.parse('2', CryptoCurrency.eth),
        availableBalance: Money.parse('1', CryptoCurrency.btc),
      ),
    );
    final second = _Provider(ExchangeProviderDescription.exolix, rate: 1);
    final viewModel = await _viewModel([first, second]);

    await viewModel.createTrade();

    expect(first.requests, hasLength(1));
    expect(second.requests, isEmpty);
    expect((viewModel.tradeState as TradeIsCreatedFailure).error,
        S.current.tx_wrong_balance_exception(CryptoCurrency.eth.toString()));
  });

  final fallbackErrors = {
    'ordinary provider failure': StateError('ordinary provider failure'),
    'untyped balance-like provider error': StateError('insufficient funds'),
    'confirmed pre-request provider failure':
        const _CreationFailure(TradeCreationFailureBoundary.beforeRequest),
  };
  for (final entry in fallbackErrors.entries) {
    test('${entry.key} falls back and creates the next provider trade', () async {
      final first = _Provider(
        ExchangeProviderDescription.changeNow,
        rate: 2,
        error: entry.value,
      );
      final second = _Provider(ExchangeProviderDescription.exolix, rate: 1);
      final viewModel = await _viewModel([first, second]);

      await viewModel.createTrade();

      expect(first.requests, hasLength(1));
      expect(second.requests, hasLength(1));
      expect((viewModel.tradeState as TradeIsCreatedSuccessfully).trade, same(second.trade));
      expect((viewModel.tradesStore as _TradesStore).stored, [second.trade]);
      expect(second.trade.saves, 1);
    });
  }

  test('ambiguous provider creation still stops fallback with the provider message', () async {
    const error = _CreationFailure(TradeCreationFailureBoundary.requestMayHaveReached);
    final first = _Provider(ExchangeProviderDescription.changeNow, rate: 2, error: error);
    final second = _Provider(ExchangeProviderDescription.exolix, rate: 1);
    final viewModel = await _viewModel([first, second]);

    await viewModel.createTrade();

    expect(first.requests, hasLength(1));
    expect(second.requests, isEmpty);
    expect((viewModel.tradeState as TradeIsCreatedFailure).error, error.userMessage);
  });

  test('failure after a provider order was returned still stops fallback', () async {
    final first = _Provider(
      ExchangeProviderDescription.changeNow,
      rate: 2,
      saveError: StateError('trade persistence failed'),
    );
    final second = _Provider(ExchangeProviderDescription.exolix, rate: 1);
    final viewModel = await _viewModel([first, second]);

    await viewModel.createTrade();

    expect(first.requests, hasLength(1));
    expect(first.trade.saves, 1);
    expect(second.requests, isEmpty);
    expect((viewModel.tradeState as TradeIsCreatedFailure).error,
        'The provider order was created but cannot be used safely.');
  });
}

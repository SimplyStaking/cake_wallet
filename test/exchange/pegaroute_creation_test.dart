import 'dart:async';

import 'package:cake_wallet/entities/exchange_api_mode.dart';
import 'package:cake_wallet/entities/preferences_key.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/exchange_trade_state.dart';
import 'package:cake_wallet/exchange/limits.dart';
import 'package:cake_wallet/exchange/limits_state.dart';
import 'package:cake_wallet/exchange/provider/exchange_provider.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_provider_preferences.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_request.dart';
import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/store/app_store.dart';
import 'package:cake_wallet/store/dashboard/fiat_conversion_store.dart';
import 'package:cake_wallet/store/dashboard/trades_store.dart';
import 'package:cake_wallet/store/templates/exchange_template_store.dart';
import 'package:cake_wallet/view_model/exchange/exchange_view_model.dart';
import 'package:cake_wallet/view_model/exchange/exchange_trade_view_model.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_trade_record.dart';
import 'package:cake_wallet/view_model/send/send_view_model_state.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/db/sqlite.dart' as sqlite;
import 'package:cw_core/wallet_type.dart';
import 'package:cake_wallet/evm/evm.dart';
import 'package:cake_wallet/monero/monero.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart' show ObservableMap, runInAction;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'pegaroute_flow_test.dart';

class TemplateStore extends Mock implements ExchangeTemplateStore {}

class InstallationMutationProvider extends PegaRouteExchangeProvider {
  InstallationMutationProvider(DepositFixture flow) : super(request: flow.request, store: flow.store,
      configuration: testPegarouteConfiguration);
  late void Function() afterCreation;
  @override
  Future<Trade> createBoundTrade({required TradeRequest request, required String walletId,
      required String sender, required int? chainId, required bool isFixedRateMode,
      required bool isSendAll, required bool Function() isCurrent}) async {
    final trade = await super.createBoundTrade(request: request, walletId: walletId,
        sender: sender, chainId: chainId, isFixedRateMode: isFixedRateMode,
        isSendAll: isSendAll, isCurrent: isCurrent);
    afterCreation();
    return trade;
  }
}

class CapturedTrades extends Mock implements TradesStore {
  Trade? stored;
  @override
  Trade? get trade => stored;
  @override
  void setTrade(Trade trade) => stored = trade;
}

class OfflineExchange extends ExchangeViewModel {
  OfflineExchange(AppStore app, CapturedTrades trades, SharedPreferences prefs, TestUnspent unspent)
      : super(app, TemplateStore(), trades, prefs, TestContacts(), unspent, TestFees(),
            FiatConversionStore()..prices[CryptoCurrency.xmr] = 1);
  bool ready = false;
  @override
  Future<void> loadLimits() async {
    if (ready) await super.loadLimits();
  }

  @override
  Future<void> calculateBestRate() async {
    if (ready) await super.calculateBestRate();
  }

  @override
  Future<void> fetchFiatPrice(CryptoCurrency currency) async {}
}

class MinimumFlow extends DepositFixture {
  MinimumFlow(super.database);
  String minimum = '0';
  @override
  Map<String, dynamic> get route => {...super.route, 'minAmount': minimum};
}

class PausedRateProvider extends PegaRouteExchangeProvider {
  PausedRateProvider(DepositFixture flow) : super(request: flow.request, store: flow.store,
      configuration: testPegarouteConfiguration);
  bool pause = false;
  final pending = <Completer<double>>[];
  final pendingLimits = <void Function(Limits)?>[];
  @override
  Future<double> fetchRateExact({required CryptoCurrency from, required CryptoCurrency to,
      required String amount, void Function(Limits)? onLimits}) {
    if (!pause) return super.fetchRateExact(from: from, to: to, amount: amount, onLimits: onLimits);
    final result = Completer<double>();
    pending.add(result);
    pendingLimits.add(onLimits);
    return result.future;
  }
}

class FallbackProvider extends ExchangeProvider {
  int orders = 0;
  bool rateFails = false;
  bool rateUnavailable = false;
  double minimum = 0;
  Completer<Limits?>? limitsWait;
  @override
  ExchangeProviderDescription get description => ExchangeProviderDescription.changeNow;
  @override
  String get title => 'offline-fallback';
  @override
  bool get isAvailable => true;
  @override
  bool get isEnabled => true;
  @override
  bool get supportsFixedRate => true;
  @override
  Future<bool> checkIsAvailable() async => true;
  @override
  Future<Limits?> fetchLimits(
          {required CryptoCurrency from,
          required CryptoCurrency to,
          required bool isFixedRateMode}) async =>
      limitsWait?.future ?? Future.value(Limits(min: minimum, max: null));
  @override
  Future<double> fetchRate(
          {required CryptoCurrency from,
          required CryptoCurrency to,
          required double amount,
          required bool isFixedRateMode,
          required bool isReceiveAmount}) async {
    if (rateFails) throw StateError('Synthetic provider outage');
    return rateUnavailable ? 0 : 0.1;
  }
  @override
  Future<Trade> createTrade(
      {required TradeRequest request,
      required bool isFixedRateMode,
      required bool isSendAll}) async {
    orders++;
    return Trade(id: 'fallback', amount: request.fromAmount, provider: description);
  }

  @override
  Future<Trade> findTradeById({required String id}) async => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database database;
  setUpAll(() {
    registerFallbackValue(WalletType.ethereum);
    registerFallbackValue(Object());
    S.current = const S();
  });
  setUp(() async {
    database = await openDepositDb();
    // Empty wallet catalog used only by constructor token-discovery queries.
    await database.execute('CREATE TABLE WalletInfo (sortOrder INTEGER)');
    evm = TestEvm();
    monero = TestMonero();
    SharedPreferences.setMockInitialValues(
        {PreferencesKey.exchangeProvidersSelection: '{"Trocador":false}'});
  });
  tearDown(() async {
    // Drain the constructor's asynchronous empty-catalog discovery before closing SQLite.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await database.close();
    sqlite.db = null;
  });

  Future<(OfflineExchange, CapturedTrades)> model(
      DepositFixture flow, FallbackProvider fallback,
      {PegaRouteExchangeProvider? replacement, bool decentralizedOnly = false}) async {
    final environment = SendFixture(flow, Trade(id: 'environment', amount: flow.principal));
    when(() => environment.settings.exchangeStatus).thenReturn(ExchangeApiMode.enabled);
    when(() => environment.settings.forceDecentralizedExchanges).thenReturn(decentralizedOnly);
    when(() => environment.settings.trocadorProviderStates)
        .thenReturn(ObservableMap<String, bool>());
    final trades = CapturedTrades();
    final vm = OfflineExchange(
        environment.app, trades, await SharedPreferences.getInstance(), environment.unspent);
    addTearDown(vm.dispose);
    for (final provider in vm.selectedProviders.toList()) {
      vm.removeExchangeProvider(provider);
    }
    final provider = replacement ?? flow.provider;
    vm.providerList = [provider, fallback];
    vm.provider = provider;
    vm.addExchangeProvider(provider);
    vm.addExchangeProvider(fallback);
    vm.depositCurrency = flow.intent.fromCurrency;
    vm.receiveCurrency = flow.intent.toCurrency;
    vm.receiveAddress = flow.payout;
    vm.depositAddress = flow.sender;
    vm.ready = true;
    await vm.loadLimits();
    await vm.changeDepositAmount(amount: flow.principal, isCanonical: true);
    await vm.calculateBestRate();
    expect(vm.bestRateProvider, same(provider));
    return (vm, trades);
  }

  test('current quote minima use the normal limits and clear after a valid quote', () async {
    final flow = MinimumFlow(database);
    final fallback = FallbackProvider()..rateUnavailable = true;
    final (vm, _) = await model(flow, fallback);
    flow.minimum = '0.0063';
    await vm.changeDepositAmount(amount: '0.001', isCanonical: true);
    await vm.calculateBestRate();
    expect(vm.noProviderForPair, true);
    expect(vm.limits.min, 0.0063);
    expect(vm.checkIfInputMeetsMinOrMaxCondition('0.001'), false);
    flow.minimum = '0';
    await vm.calculateBestRate();
    expect(vm.bestRateProvider, same(flow.provider));
    expect(vm.limits.min, 0);
    expect(vm.checkIfInputMeetsMinOrMaxCondition('0.001'), true);
    expect(flow.posts, 0);
  });

  test('a valid Pegaroute quote does not inherit another provider minimum', () async {
    final flow = DepositFixture(database);
    final fallback = FallbackProvider()..minimum = 0.003;
    final (vm, _) = await model(flow, fallback);
    await vm.changeDepositAmount(amount: '0.001', isCanonical: true);
    await vm.calculateBestRate();
    expect(vm.bestRateProvider, same(flow.provider));
    expect(vm.limits.min, 0);
    expect(vm.checkIfInputMeetsMinOrMaxCondition('0.001'), true);
    vm.setForcedProvider(fallback);
    expect(vm.limits.min, 0.003);
    vm.setForcedProvider(flow.provider);
    await vm.calculateForcedProviderRate();
    expect(vm.limits.min, 0);
    expect(flow.posts, 0);
  });

  test('periodic refresh does not replace pending quote and minimum requests', () async {
    final flow = DepositFixture(database);
    final provider = PausedRateProvider(flow);
    final (vm, _) = await model(flow, FallbackProvider(), replacement: provider);
    vm.forcedProvider = provider;
    provider.pause = true;
    final comparison = vm.calculateBestRate();
    final forced = vm.calculateForcedProviderRate();
    await Future<void>.delayed(const Duration(seconds: 11));
    expect(provider.pending, hasLength(2));
    provider.pendingLimits.first?.call(Limits(min: 3, max: null));
    provider.pending.first.complete(0);
    provider.pendingLimits.last?.call(Limits(min: 2, max: null));
    provider.pending.last.complete(0);
    await Future.wait([comparison, forced]);
    expect(vm.limits.min, 2);
    expect(flow.posts, 0);
  });

  test('an automatic comparison cannot replace the forced quote limits', () async {
    final flow = DepositFixture(database);
    final provider = PausedRateProvider(flow);
    final (vm, _) = await model(flow, FallbackProvider()..minimum = 100, replacement: provider);
    vm.forcedProvider = provider;
    provider.pause = true;
    final automatic = vm.calculateBestRate();
    final forced = vm.calculateForcedProviderRate();
    provider.pendingLimits.last?.call(Limits(min: 0.002, max: null));
    provider.pending.last.complete(0.2);
    await forced;
    provider.pendingLimits.first?.call(Limits(min: 100, max: null));
    provider.pending.first.complete(0.9);
    await automatic;
    expect(vm.forcedProviderRate, 0.2);
    expect(vm.limits.min, 0.002);
  });

  test('limits from an older pair cannot replace the current pair limits', () async {
    final flow = DepositFixture(database);
    final fallback = FallbackProvider();
    final (vm, _) = await model(flow, fallback);
    final waiting = Completer<Limits?>();
    fallback.limitsWait = waiting;
    final older = vm.loadLimits();
    vm.receiveCurrency = CryptoCurrency.btc;
    fallback.limitsWait = null;
    fallback.minimum = 0.003;
    await vm.loadLimits();
    await vm.calculateBestRate();
    expect(vm.limits.min, 0.003);
    waiting.complete(Limits(min: 100, max: 101));
    await older;
    expect(vm.limits.min, 0.003);
  });

  test('provider failures clear stale quotes and recover without order creation', () async {
    final flow = DepositFixture(database);
    final provider = PausedRateProvider(flow);
    final fallback = FallbackProvider();
    final (vm, _) = await model(flow, fallback, replacement: provider);
    provider.pause = true;
    final failed = vm.calculateBestRate();
    provider.pending.last.completeError(StateError('Synthetic Pegaroute outage'));
    await failed;
    expect(vm.bestRateProvider, same(fallback));
    expect(vm.noProviderForPair, false);

    fallback.rateFails = true;
    final empty = vm.calculateBestRate();
    provider.pending.last.complete(0);
    await empty;
    expect(vm.bestRateProvider, isNull);
    expect(vm.bestRate, 0);
    expect(vm.noProviderForPair, true);

    provider.pause = false;
    await vm.calculateBestRate();
    expect(vm.bestRateProvider, same(provider));
    expect(vm.noProviderForPair, false);
    expect(flow.posts, 0);
    expect(fallback.orders, 0);
  });

  test('a forced Pegaroute quote recovers on the periodic refresh', () async {
    final flow = DepositFixture(database);
    final provider = PausedRateProvider(flow);
    final (vm, _) = await model(flow, FallbackProvider(), replacement: provider);
    vm.forcedProvider = provider;
    provider.pause = true;
    final failed = vm.calculateForcedProviderRate();
    provider.pending.last.complete(0);
    await failed;
    expect(vm.forcedProviderRate, 0);
    provider.pause = false;
    await Future<void>.delayed(const Duration(seconds: 11));
    expect(vm.forcedProviderRate, greaterThan(0));
    expect(flow.posts, 0);
  });

  test('decentralized-only permits Instaswap best and forced quotes and actual VM creation', () async {
    final flow = DepositFixture(database);
    final preferences = PegarouteProviderPreferences(await SharedPreferences.getInstance());
    final provider = PegaRouteExchangeProvider(request: flow.request, store: flow.store,
        configuration: testPegarouteConfiguration, providerPreferences: preferences);
    final (vm, trades) = await model(flow, FallbackProvider(),
        replacement: provider, decentralizedOnly: true);
    expect(vm.bestRate, greaterThan(0));
    vm.forcedProvider = provider;
    await vm.calculateForcedProviderRate();
    expect(vm.forcedProviderRate, greaterThan(0));
    await vm.createTrade();
    expect(vm.tradeState, isA<TradeIsCreatedSuccessfully>());
    expect(trades.stored, isNotNull);
    expect(flow.posts, 1);
  });

  test('explicit Instaswap disable clears best and forced quotes in decentralized-only', () async {
    final flow = DepositFixture(database);
    final preferences = PegarouteProviderPreferences(await SharedPreferences.getInstance());
    final provider = PegaRouteExchangeProvider(request: flow.request, store: flow.store,
        configuration: testPegarouteConfiguration, providerPreferences: preferences);
    final (vm, _) = await model(flow, FallbackProvider(),
        replacement: provider, decentralizedOnly: true);
    vm.forcedProvider = provider;
    await vm.calculateForcedProviderRate();
    expect(vm.forcedProviderRate, greaterThan(0));
    await preferences.setEnabled('instaswap', false);
    await vm.calculateBestRate();
    await vm.calculateForcedProviderRate();
    expect(vm.bestRate, 0);
    expect(vm.forcedProviderRate, 0);
    await vm.createTrade();
    expect(vm.tradeState, isNot(isA<TradeIsCreatedSuccessfully>()));
    expect(flow.posts, 0);
  });

  test('disabling Instaswap during bound quote prevents POST in decentralized-only', () async {
    final flow = DepositFixture(database);
    final preferences = PegarouteProviderPreferences(await SharedPreferences.getInstance());
    final provider = PegaRouteExchangeProvider(request: flow.request, store: flow.store,
        configuration: testPegarouteConfiguration, providerPreferences: preferences);
    final (vm, _) = await model(flow, FallbackProvider(),
        replacement: provider, decentralizedOnly: true);
    final entered = Completer<void>();
    final release = Completer<void>();
    flow.duringBoundQuote = () { entered.complete(); return release.future; };
    final pending = vm.createTrade();
    await entered.future;
    await preferences.setEnabled('instaswap', false);
    release.complete();
    await pending;
    expect(vm.tradeState, isNot(isA<TradeIsCreatedSuccessfully>()));
    expect(flow.posts, 0);
  });

  test('exact Pegaroute creation does not use another amount\'s aggregate discovery limits', () async {
    final flow = DepositFixture(database);
    final fallback = FallbackProvider();
    final (vm, trades) = await model(flow, fallback);
    vm.limits = Limits(min: 100, max: 101);
    vm.limitsState = LimitsLoadedFailure(error: 'Synthetic one-unit discovery failure');
    await vm.createTrade();
    expect(vm.tradeState, isA<TradeIsCreatedSuccessfully>());
    expect(trades.stored!.amount, flow.principal);
    expect(fallback.orders, 0);
  });

  test('a fresh quote minimum above exact principal stops creation before POST', () async {
    final flow = MinimumFlow(database);
    expect(await flow.provider.fetchRateExact(from: flow.intent.fromCurrency,
        to: flow.intent.toCurrency, amount: flow.principal), greaterThan(0));
    flow.minimum = '2';
    await expectLater(flow.provider.createBoundTrade(request: flow.intent, walletId: 'wallet',
        sender: flow.sender, chainId: 1, isFixedRateMode: false, isSendAll: false,
        isCurrent: () => true), throwsStateError);
    expect(flow.posts, 0);
  });

  for (final changeAmount in [false, true]) {
    test('actual comparison discards older Pegaroute response (changed input: $changeAmount)', () async {
      final flow = DepositFixture(database, source: 'ETH');
      final provider = PausedRateProvider(flow);
      final (vm, _) = await model(flow, FallbackProvider()..minimum = 100, replacement: provider);
      provider.pause = true;
      final older = vm.calculateBestRate();
      if (changeAmount) await vm.changeDepositAmount(amount: '2', isCanonical: true);
      final newer = vm.calculateBestRate();
      expect(provider.pending, hasLength(2));
      provider.pendingLimits.last?.call(Limits(min: 0.002, max: null));
      provider.pending.last.complete(0.2);
      await newer;
      expect(vm.bestRate, 0.2);
      provider.pendingLimits.first?.call(Limits(min: 100, max: null));
      provider.pending.first.complete(0.9);
      await older;
      expect(vm.bestRateProvider, same(provider));
      expect(vm.bestRate, 0.2);
      expect(vm.limits.min, 0.002);
    });
  }

  for (final source in ['ETH', 'XMR']) {
    test('$source actual ExchangeViewModel quote/create flows into actual SendViewModel commit',
        () async {
      final flow = DepositFixture(database, source: source);
      final fallback = FallbackProvider();
      final (vm, trades) = await model(flow, fallback);
      await vm.createTrade();
      expect(vm.tradeState, isA<TradeIsCreatedSuccessfully>());
      final trade = trades.stored!;
      expect(trade.internalId, greaterThan(0));
      expect(trade.amount, flow.principal);
      final send = SendFixture(flow, trade);
      final bridge = ExchangeTradeViewModel(wallet: send.wallet, tradesStore: trades,
          sendViewModel: send.model, feesViewModel: TestFees(),
          fiatConversionStore: FiatConversionStore(), pegarouteProvider: flow.provider);
      addTearDown(() => bridge.timer?.cancel());
      await bridge.confirmSending();
      expect(send.model.pendingTransaction, isNotNull);
      await send.commit();
      expect(send.model.state, isA<TransactionCommitted>());
      expect(flow.notified, [source == 'ETH' ? ethHash : xmrHash]);
      expect(fallback.orders, 0);
    });
  }

  test('final VM installation rechecks intent after the provider has returned', () async {
    final flow = DepositFixture(database); final fallback = FallbackProvider();
    final provider = InstallationMutationProvider(flow);
    final (vm, trades) = await model(flow, fallback, replacement: provider);
    provider.afterCreation = () => runInAction(() => vm.receiveAddress = 'changed-after-provider');
    await vm.createTrade();
    expect(vm.tradeState, isA<TradeIsCreatedFailure>());
    expect(trades.stored, isNull); expect(fallback.orders, 0);
    expect((await flow.store.read('order')).internalId, greaterThan(0));
  });

  test('real foreground periodic refresh preserves the committed funding claim', () async {
    final flow = DepositFixture(database); final fallback = FallbackProvider();
    final (vm, trades) = await model(flow, fallback);
    await vm.createTrade();
    final send = SendFixture(flow, trades.stored!);
    final bridge = ExchangeTradeViewModel(wallet: send.wallet, tradesStore: trades,
        sendViewModel: send.model, feesViewModel: TestFees(),
        fiatConversionStore: FiatConversionStore(), pegarouteProvider: flow.provider);
    addTearDown(() => bridge.timer?.cancel());
    await bridge.confirmSending(); await send.commit();
    flow.status = 'submitted';
    await Future<void>.delayed(const Duration(seconds: 21));
    final persisted = await flow.store.read('order');
    expect(persisted.stateRaw, 'confirming');
    expect(bridge.trade.stateRaw, 'confirming');
    expect(PegarouteTradeRecord.read(persisted).attempt, isNotNull);
    expect(persisted.txId, ethHash);
  });

  for (final change in ['wallet', 'amount', 'recipient']) {
    test('changed $change during address-bound requote prevents order creation', () async {
      final flow = DepositFixture(database);
      final fallback = FallbackProvider();
      final (vm, trades) = await model(flow, fallback);
      flow.duringBoundQuote = () async {
        if (change == 'wallet') when(() => vm.wallet.id).thenReturn('changed-wallet');
        if (change == 'recipient') runInAction(() => vm.receiveAddress = 'changed-recipient');
        if (change == 'amount') await vm.changeDepositAmount(amount: '2', isCanonical: true);
      };
      await vm.createTrade();
      expect(flow.posts, 0);
      expect(fallback.orders, 0);
      expect(trades.stored, isNull);
      expect(vm.tradeState, isA<TradeIsCreatedFailure>());
    });
  }

  test('ordinary other-provider creation still uses its normal Trade save path', () async {
    final flow = DepositFixture(database);
    final fallback = FallbackProvider();
    final (vm, trades) = await model(flow, fallback);
    vm.removeExchangeProvider(flow.provider);
    await vm.calculateBestRate();
    expect(vm.bestRateProvider, same(fallback));
    await vm.createTrade();
    expect(vm.tradeState, isA<TradeIsCreatedSuccessfully>());
    expect(fallback.orders, 1);
    expect(flow.posts, 0);
    expect((await Trade.getByTradeId('fallback'))!.amount, flow.principal);
    expect(trades.stored!.provider, ExchangeProviderDescription.changeNow);
  });

  test('ambiguous POST never falls through to another provider', () async {
    final flow = DepositFixture(database)..ambiguousCreate = true;
    final fallback = FallbackProvider();
    final (vm, trades) = await model(flow, fallback);
    await vm.createTrade();
    expect(vm.tradeState, isA<TradeIsCreatedFailure>());
    expect(flow.posts, 1);
    expect(fallback.orders, 0);
    expect(trades.stored, isNull);
  });
}

import 'dart:async';
import 'dart:convert';
import 'package:cake_wallet/entities/exchange_api_mode.dart';
import 'package:cake_wallet/entities/preferences_key.dart';
import 'package:cake_wallet/exchange/exchange_trade_state.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_currency_mapper.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_terms.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_request.dart';
import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/solana/solana.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/db/sqlite.dart' as sqlite;
import 'package:cw_core/wallet_type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart' show ObservableMap;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'pegaroute_creation_test.dart' show OfflineExchange, CapturedTrades, FallbackProvider;
import 'pegaroute_flow_test.dart';

class SolQuoteFlow extends DepositFixture {
  SolQuoteFlow(super.database) : super(source: 'SOL');
  String input = '0.002';
  String minimum = '0';
  Future<void> Function()? duringQuote;
  @override
  String get principal => input;
  @override
  String get sender => '11111111111111111111111111111111';
  @override
  Map<String, dynamic> get route => {...super.route, 'minAmount': minimum};
  @override
  TradeRequest get intent => TradeRequest(fromCurrency: CryptoCurrency.sol,
      toCurrency: CryptoCurrency.usdcsol, fromAmount: principal,
      toAddress: sender, refundAddress: sender);
  @override
  Future<Map<String, dynamic>> request(String method, Uri uri,
      Map<String, String> headers, String? body) async {
    if (uri.path == '/chains') return {'chains': [{'id': 'SOL'}]};
    if (uri.path == '/tokens') return {'chain': 'SOL', 'tokens': [
      {'id': 'SOL'}, {'id': const PegarouteCurrencyMapper().map(CryptoCurrency.usdcsol).token}]};
    if (uri.path == '/quote' && !uri.queryParameters.containsKey('senderAddress')) {
      await duringQuote?.call();
    }
    if (uri.path == '/swap') {
      posts++;
      expect((jsonDecode(body!) as Map)['amount'], principal);
      if (ambiguousCreate) throw StateError('Synthetic lost POST response');
      return {'transactionId': 'order', 'status': 'pending', 'providerType': 'api-provider',
        'provider': {'name': 'instaswap', 'referenceId': 'reference'}, 'route': route,
        'execution': {'family': 'solana', 'mode': 'deposit-transfer', 'to': sender,
          'memo': null, 'amount': {'display': principal,
            'baseUnits': PegarouteExecutionTerms.toBaseUnits(principal, CryptoCurrency.sol.decimals)}}};
    }
    return super.request(method, uri, headers, body);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database database;
  setUpAll(() {
    registerFallbackValue(WalletType.solana);
    registerFallbackValue(Object());
    S.current = const S();
  });
  setUp(() async {
    database = await openDepositDb();
    await database.execute('CREATE TABLE WalletInfo (sortOrder INTEGER)');
    solana = CWSolana();
    SharedPreferences.setMockInitialValues(
        {PreferencesKey.exchangeProvidersSelection: '{"Trocador":false}'});
  });
  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await database.close();
    sqlite.db = null;
    solana = null;
  });

  Future<(OfflineExchange, CapturedTrades, FallbackProvider)> model(SolQuoteFlow flow) async {
    final environment = SendFixture(flow, Trade(id: 'environment', amount: flow.principal));
    when(() => environment.wallet.type).thenReturn(WalletType.solana);
    when(() => environment.settings.exchangeStatus).thenReturn(ExchangeApiMode.enabled);
    when(() => environment.settings.forceDecentralizedExchanges).thenReturn(false);
    when(() => environment.settings.trocadorProviderStates).thenReturn(ObservableMap<String, bool>());
    final trades = CapturedTrades();
    final vm = OfflineExchange(environment.app, trades,
        await SharedPreferences.getInstance(), environment.unspent);
    addTearDown(vm.dispose);
    for (final provider in vm.selectedProviders.toList()) vm.removeExchangeProvider(provider);
    final fallback = FallbackProvider();
    vm.providerList = [flow.provider, fallback];
    vm.addExchangeProvider(flow.provider);
    vm.addExchangeProvider(fallback);
    vm.depositCurrency = flow.intent.fromCurrency;
    vm.receiveCurrency = flow.intent.toCurrency;
    vm.receiveAddress = flow.sender;
    vm.depositAddress = flow.sender;
    vm.ready = true;
    await vm.loadLimits();
    await vm.changeDepositAmount(amount: flow.principal, isCanonical: true);
    await vm.calculateBestRate();
    expect(vm.bestRateProvider, same(flow.provider));
    return (vm, trades, fallback);
  }

  (Completer<void>, Completer<void>) pause(SolQuoteFlow flow) {
    final entered = Completer<void>();
    final release = Completer<void>();
    flow.duringQuote = () {
      if (!entered.isCompleted) entered.complete();
      return release.future;
    };
    return (entered, release);
  }

  test('SOL preview waits for the exact new 0.001 amount and joins repeated presses', () async {
    final flow = SolQuoteFlow(database);
    final (vm, trades, fallback) = await model(flow);
    flow.input = '0.001';
    await vm.changeDepositAmount(amount: flow.input, isCanonical: true);
    final (entered, release) = pause(flow);
    final first = vm.createTrade();
    await entered.future;
    final second = vm.createTrade();
    expect(vm.tradeState, isA<TradeIsCreating>());
    expect(trades.stored, isNull);
    expect(flow.posts, 0);
    release.complete();
    await Future.wait([first, second]);
    expect(vm.tradeState, isA<TradeIsCreatedSuccessfully>());
    expect(trades.stored!.amount, '0.001');
    expect(trades.stored!.to, CryptoCurrency.usdcsol);
    expect(flow.posts, 1);
    expect(fallback.orders, 0);
  });

  test('preview waits for a background refresh instead of losing its exact route', () async {
    final flow = SolQuoteFlow(database);
    final (vm, trades, _) = await model(flow);
    final (entered, release) = pause(flow);
    final refresh = vm.calculateBestRate();
    await entered.future;
    final preview = vm.createTrade();
    await Future<void>.delayed(Duration.zero);
    expect(vm.tradeState, isA<TradeIsCreating>());
    expect(flow.posts, 0);
    release.complete();
    await Future.wait([refresh, preview]);
    expect(trades.stored, isNotNull);
    expect(flow.posts, 1);
  });

  test('preview waits when the first receive amount is still unavailable', () async {
    final flow = SolQuoteFlow(database);
    final (vm, trades, _) = await model(flow);
    vm.bestRate = 0;
    final (entered, release) = pause(flow);
    final amount = vm.changeDepositAmount(amount: flow.principal, isCanonical: true);
    await entered.future;
    final preview = vm.createTrade();
    await Future<void>.delayed(Duration.zero);
    expect(vm.tradeState, isA<TradeIsCreating>());
    expect(flow.posts, 0);
    release.complete();
    await Future.wait([amount, preview]);
    expect(vm.tradeState, isA<TradeIsCreatedSuccessfully>());
    expect(trades.stored, isNotNull);
    expect(flow.posts, 1);
  });

  for (final change in ['amount', 'wallet', 'recipient']) {
    test('changed $change during the preview quote prevents POST', () async {
      final flow = SolQuoteFlow(database);
      final (vm, trades, fallback) = await model(flow);
      final (entered, release) = pause(flow);
      final preview = vm.createTrade();
      await entered.future;
      if (change == 'amount') await vm.changeDepositAmount(amount: '0.003', isCanonical: true);
      if (change == 'wallet') when(() => vm.wallet.id).thenReturn('changed-wallet');
      if (change == 'recipient') vm.receiveAddress = 'changed-recipient';
      release.complete();
      await preview;
      expect(vm.tradeState, isA<TradeIsCreatedFailure>());
      expect(trades.stored, isNull);
      expect(flow.posts, 0);
      expect(fallback.orders, 0);
    });
  }

  test('an unavailable preview quote cannot create or fall back to another provider', () async {
    final flow = SolQuoteFlow(database);
    final (vm, trades, fallback) = await model(flow);
    flow.minimum = '1';
    await vm.createTrade();
    expect(vm.tradeState, isA<TradeIsCreatedFailure>());
    expect(trades.stored, isNull);
    expect(flow.posts, 0);
    expect(fallback.orders, 0);
  });

  test('concurrent exact quotes share one read and both receive current limits', () async {
    final flow = SolQuoteFlow(database)..minimum = '1';
    final (entered, release) = pause(flow);
    final limits = <double?>[];
    Future<double> rate() => flow.provider.fetchRateExact(from: flow.intent.fromCurrency,
        to: flow.intent.toCurrency, amount: flow.principal,
        onLimits: (value) => limits.add(value.min));
    final first = rate();
    await entered.future;
    final second = rate();
    release.complete();
    expect(await Future.wait([first, second]), [0, 0]);
    expect(limits, [1, 1]);
    expect(flow.quoteAmounts, hasLength(1));
    expect(flow.posts, 0);
  });

  test('bound creation waits for refresh and a failed POST stays consumed', () async {
    final flow = SolQuoteFlow(database)..ambiguousCreate = true;
    Future<double> rate() => flow.provider.fetchRateExact(from: flow.intent.fromCurrency,
        to: flow.intent.toCurrency, amount: flow.principal);
    expect(await rate(), greaterThan(0));
    final (entered, release) = pause(flow);
    final refresh = rate();
    await entered.future;
    Future<Trade> create() => flow.provider.createBoundTrade(request: flow.intent,
        walletId: 'wallet', sender: flow.sender, chainId: null,
        isFixedRateMode: false, isSendAll: false, isCurrent: () => true);
    final creation = create();
    final failure = expectLater(creation, throwsA(isA<PegarouteSwapAttemptException>()));
    expect(await rate(), 0); // A refresh cannot replace the route during creation.
    expect(flow.posts, 0);
    release.complete();
    await refresh;
    await failure;
    await expectLater(create(), throwsStateError);
    expect(flow.posts, 1);
  });
}

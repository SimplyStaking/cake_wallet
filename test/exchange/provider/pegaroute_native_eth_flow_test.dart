// Offline fixtures exercise the actual EVM pending byte/hash implementation.
// ignore_for_file: cw_custom_lints/no_restricted_imports_in_lib

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cake_wallet/core/trade_monitor.dart';
import 'package:cake_wallet/entities/exchange_api_mode.dart';
import 'package:cake_wallet/store/app_store.dart';
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cake_wallet/store/dashboard/trades_store.dart';
import 'package:cake_wallet/view_model/dashboard/trade_list_item.dart';
import 'package:cake_wallet/exchange/trade_state.dart';
import 'package:flutter/foundation.dart';
import 'package:mocktail/mocktail.dart';

import 'package:cake_wallet/evm/evm.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_eth_execution_handler.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_lifecycle_store.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_native_eth.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_provider_preferences.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_provider_label.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_trusted_execution.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_currency_mapper.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_creation_failure.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cake_wallet/exchange/trade_execution_lifecycle.dart';
import 'package:cake_wallet/exchange/trade_request.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/exceptions.dart';
import 'package:cw_core/db/sqlite.dart' as sqlite;
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/evm_call_data_transaction_credentials.dart';
import 'package:cw_core/spl_token.dart';
import 'package:cw_core/output_info.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/transaction_history.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_evm/evm_chain_transaction_credentials.dart';
import 'package:cw_evm/evm_chain_transaction_priority.dart';
import 'package:cw_evm/pending_evm_chain_transaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as very_insecure_http_do_not_use;
import 'package:mobx/mobx.dart' hide when;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_approval.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:web3dart/web3dart.dart' as web3;
import 'package:web3dart/crypto.dart';

// Public synthetic test key; never used with a node or real wallet.
final _key = web3.EthPrivateKey.fromInt(BigInt.one);
const _deposit = '0x0000000000000000000000000000000000000001';
const _calldata = '0x12345678abcdef'; // Opaque synthetic instructions, not a router fixture.

class _MonitorApp extends Mock implements AppStore {}

class _MonitorSettings extends Mock implements SettingsStore {}

class _MonitorTrades extends Mock implements TradesStore {}

const _nativeCurrency = {
  1: CryptoCurrency.eth,
  56: CryptoCurrency.bnb,
  8453: CryptoCurrency.baseEth,
  42161: CryptoCurrency.arbEth,
  137: CryptoCurrency.maticpoly
};
final _usdc = Erc20Token(
    name: 'USD Coin',
    symbol: 'USDC',
    contractAddress: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
    decimal: 6,
    tag: 'ETH',
    chainId: 1);
final _usdt = Erc20Token(
    name: 'Tether',
    symbol: 'USDT',
    contractAddress: '0xdac17f958d2ee523a2206206994597c13d831ec7',
    decimal: 6,
    tag: 'ETH',
    chainId: 1);
const _payout =
    '85s6zfxGAkdCN21h566R8EFDSfThxCrFiEkhw3JEtaXN2DDfahABLXTjRj385Ro7om5saGWJG7iuE6EyW5MYcoz93DLvNqh';
Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/exchange/fixtures/pegaroute/$name.json').readAsStringSync())
        as Map<String, dynamic>;

class _Addresses implements WalletAddresses {
  @override
  String get address => _key.address.hex;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Balance extends Balance {
  _Balance(Money available) : super(available, Money.zero(available.currency));
}

class _Wallet
    extends WalletBase<Balance, TransactionHistoryBase<TransactionInfo>, TransactionInfo> {
  _Wallet()
      : super(
            WalletInfo.external(
              id: 'eth-fixture',
              name: 'eth-fixture',
              type: WalletType.ethereum,
              isRecovery: false,
              restoreHeight: 0,
              date: DateTime.utc(2026),
              dirPath: '',
              path: '',
              address: _key.address.hex,
            ),
            DerivationInfo());

  final selectedChain = Observable(1);
  int builds = 0;
  int broadcasts = 0;
  final signedNonces = <int>[];
  String? mutation;
  bool hardware = false;
  Future<void> Function()? duringBuild;
  Future<void> Function()? duringBroadcast;
  late PendingEVMChainTransaction pending;
  @override
  int get chainId => selectedChain.value;
  @override
  bool get isHardwareWallet => hardware;
  @override
  bool get isSoftwareWallet => !hardware;
  @override
  WalletAddresses get walletAddresses => _Addresses();
  @override
  Future<PendingTransaction> createTransaction(Object credentials) async {
    if (credentials is EvmCallDataTransactionCredentials) {
      expect(credentials.useBlinkProtection, false);
      if (sourceCurrency is Erc20Token) {
        expect(credentials.sourceTokenAddress, (sourceCurrency as Erc20Token).contractAddress);
        expect(credentials.sourceTokenAmount, BigInt.from(10).pow(sourceCurrency.decimals));
        expect(credentials.value.amount, BigInt.zero);
      }
      return build(credentials.to, credentials.value, credentials.data,
          gasLimit: credentials.gasLimit);
    }
    final value = credentials as EVMChainTransactionCredentials;
    final output = value.outputs.single;
    expect(value.currency, sourceCurrency);
    expect(output.sendAll, false);
    expect(output.memo, isNull);
    expect(output.address, _deposit);
    return build(output.address, output.cryptoAmount, '0x');
  }

  CryptoCurrency sourceCurrency = CryptoCurrency.eth;
  Map<CryptoCurrency, Balance>? balances;
  @override
  ObservableMap<CryptoCurrency, Balance> get balance =>
      ObservableMap.of(balances ?? {sourceCurrency: _Balance(Money.parse('100', sourceCurrency))});
  Future<PendingTransaction> build(String to, Money amount, String data,
      {int gasLimit = 21000}) async {
    builds++;
    final typed = chainId == 1;
    signedNonces.add(7 + broadcasts);
    final transaction = web3.Transaction(
      to: web3.EthereumAddress.fromHex(mutation == 'to' ? _key.address.hex : to),
      value:
          web3.EtherAmount.inWei(amount.amount + (mutation == 'amount' ? BigInt.one : BigInt.zero)),
      data: Uint8List.fromList(mutation == 'data' ? [1] : hexToBytes(data)),
      nonce: 7 + broadcasts,
      maxGas: mutation == 'gas' ? 21000 : gasLimit,
      gasPrice: typed ? null : web3.EtherAmount.inWei(BigInt.two),
      maxPriorityFeePerGas: typed ? web3.EtherAmount.inWei(BigInt.one) : null,
      maxFeePerGas: typed ? web3.EtherAmount.inWei(BigInt.from(2)) : null,
    );
    final signed = await web3.signTransactionRaw(
        transaction, mutation == 'signer' ? web3.EthPrivateKey.fromInt(BigInt.two) : _key,
        chainId: mutation == 'chain' ? 100 : chainId);
    await duringBuild?.call();
    pending = PendingEVMChainTransaction(
      signedTransaction: typed ? web3.prependTransactionType(2, signed) : signed,
      amount: amount,
      fee: Money(BigInt.from(gasLimit * 2), _nativeCurrency[chainId]!),
      sendTransaction: () async {
        broadcasts++;
        await duringBroadcast?.call();
      },
    );
    return pending;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Evm implements EVM {
  _Evm(this.original);
  final EVM original;
  BigInt? allowance = BigInt.zero;
  bool? receipt = true;
  final approvalAmounts = <BigInt>[];
  TransactionWrongBalanceException? approvalBalanceError;
  void Function()? duringReceipt;
  @override
  Future<BigInt?> getAllowance(WalletBase wallet, String tokenContract, String spender) async {
    expect(
        tokenContract,
        (wallet as _Wallet).sourceCurrency is Erc20Token
            ? (wallet.sourceCurrency as Erc20Token).contractAddress
            : _usdc.contractAddress);
    expect(spender, _deposit);
    return allowance;
  }

  @override
  Future<bool?> getTransactionReceipt(WalletBase wallet, String txHash) async {
    duringReceipt?.call();
    return receipt;
  }

  @override
  Future<PendingTransaction> createTokenApproval(
      WalletBase wallet, Money amount, String spender, TransactionPriority? priority,
      {bool useBlinkProtection = true}) async {
    expect(useBlinkProtection, false);
    approvalAmounts.add(amount.amount);
    if (approvalBalanceError != null) throw approvalBalanceError!;
    final current = wallet as _Wallet;
    final data = '0x095ea7b3${spender.substring(2).padLeft(64, '0')}'
        '${amount.amount.toRadixString(16).padLeft(64, '0')}';
    final pending = await current.build(
        (amount.currency as Erc20Token).contractAddress, Money.zero(CryptoCurrency.eth), data);
    current.duringBroadcast = () async {
      allowance = amount.amount;
    };
    return pending;
  }

  @override
  Object createEVMTransactionCredentialsRaw(
    List<OutputInfo> outputs, {
    TransactionPriority? priority,
    required CryptoCurrency currency,
    required int feeRate,
    bool useBlinkProtection = true,
  }) =>
      original.createEVMTransactionCredentialsRaw(outputs,
          priority: priority,
          currency: currency,
          feeRate: feeRate,
          useBlinkProtection: useBlinkProtection);
  @override
  Future<PendingTransaction> createRawCallDataTransaction(
      WalletBase wallet, String to, String dataHex, Money valueWei, TransactionPriority? priority,
      {bool useBlinkProtection = true, String? sourceTokenAddress, BigInt? sourceTokenAmount}) {
    expect(useBlinkProtection, false);
    return (wallet as _Wallet).build(to, valueWei, dataHex);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<Database> _database() async {
  sqfliteFfiInit();
  final database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  // Exercise Trade's complete SQLite serialization and initial-insert boundary.
  final columns = Trade(id: '', amount: '').toSqliteMap().keys;
  await database.execute('CREATE TABLE Trade ('
      'tradeId INTEGER PRIMARY KEY AUTOINCREMENT, '
      '${columns.where((key) => key != 'tradeId').map((key) => '"$key"').join(', ')}, '
      'fromAssetIdentityJson TEXT, toAssetIdentityJson TEXT)');
  await database.execute('CREATE UNIQUE INDEX idx_trade_id_unique ON Trade (id)');
  sqlite.db = database;
  return database;
}

void main() {
  late Database database;
  late _Wallet wallet;
  late Observable<WalletBase?> active;
  late PegarouteActiveWalletContext context;
  late PegarouteExchangeProvider provider;
  late PegarouteProviderPreferences preferences;
  bool decentralizedOnly = false;
  late RegistryTradeExecutionDispatcher dispatcher;
  late Map<String, dynamic> quote;
  late Map<String, dynamic> swap;
  late List<String> calls;
  late EVM originalEvm;
  CryptoCurrency receiveCurrency = CryptoCurrency.xmr;
  String sourceAmount = '1';
  String payoutAddress() => receiveCurrency == CryptoCurrency.xmr
      ? _payout
      : receiveCurrency == CryptoCurrency.usdcsol
          ? '11111111111111111111111111111111'
          : _key.address.hex;
  String? sourceHash;
  String? ackHash;
  String? ackId;
  bool failCreation = false;
  bool failCallback = false;
  bool storeHash = true;
  bool completed = false;
  void Function()? afterQuote;
  void Function()? afterPost;
  void Function(Map<String, dynamic>)? mutateStatus;

  TradeRequest request({CryptoCurrency? from, String? sender, String extra = ''}) => TradeRequest(
      fromCurrency: from ?? wallet.sourceCurrency,
      toCurrency: receiveCurrency,
      fromAmount: sourceAmount,
      toAddress: payoutAddress(),
      senderAddress: sender ?? _key.address.hex,
      refundAddress: _key.address.hex,
      toAddressExtraId: extra);

  Future<Trade> create() async {
    final trade =
        await provider.createTrade(request: request(), isFixedRateMode: false, isSendAll: false);
    await trade.save();
    return trade;
  }

  for (final afterQuoteRequest in [false, true]) {
    test(
        'insufficient source balance ${afterQuoteRequest ? "after quote" : "before quote"} prevents order creation',
        () async {
      sourceAmount = '0.001';
      void lowerBalance() {
        wallet.balances = {
          CryptoCurrency.eth: _Balance(Money.parse('0.000836033134785206', CryptoCurrency.eth))
        };
      }

      if (afterQuoteRequest) {
        afterQuote = lowerBalance;
      } else {
        lowerBalance();
      }
      await expectLater(
          create(),
          throwsA(isA<TransactionWrongBalanceException>()
              .having((error) => error.currency, 'currency', CryptoCurrency.eth)
              .having((error) => error.requiredBalance, 'exact principal',
                  Money.parse('0.001', CryptoCurrency.eth))
              .having((error) => error.availableBalance, 'exact spendable balance',
                  Money.parse('0.000836033134785206', CryptoCurrency.eth))
              .having((error) => error.fee, 'no executable fee yet', isNull)));
      expect(calls, afterQuoteRequest ? ['GET /quote'] : isEmpty);
      expect(await database.query(Trade.tableName), isEmpty);
      expect(wallet.builds, 0);
      expect(wallet.broadcasts, 0);
    });
  }

  test('source balance check resolves catalog aliases without borrowing another chain balance',
      () async {
    wallet.sourceCurrency = _usdc;
    wallet.balances = {
      _usdc: _Balance(Money.parse('0.999999', _usdc)),
      CryptoCurrency.eth: _Balance(Money.parse('100', CryptoCurrency.eth)),
      CryptoCurrency.usdcsol: _Balance(Money.parse('100', CryptoCurrency.usdcsol)),
    };
    await expectLater(
        provider.createTrade(
            request: request(from: CryptoCurrency.usdc), isFixedRateMode: false, isSendAll: false),
        throwsA(isA<TransactionWrongBalanceException>().having(
            (error) => (error.currency as Erc20Token).contractAddress,
            'source contract',
            _usdc.contractAddress)));
    expect(calls, isEmpty);
    expect(wallet.builds, 0);
  });

  test('a same-ticker token cannot supply balance for a different canonical contract', () async {
    final impostor = Erc20Token(
        name: 'Unrelated token',
        symbol: 'USDC',
        contractAddress: '0x1111111111111111111111111111111111111111',
        decimal: 6,
        chainId: 1,
        tag: 'ETH');
    wallet.sourceCurrency = _usdc;
    wallet.balances = {impostor: _Balance(Money.parse('100', impostor))};
    await expectLater(create(), throwsA(isA<PegarouteUnavailableException>()));
    expect(calls, isEmpty);
    expect(wallet.builds, 0);
  });

  test('source balance equal to the amount permits creation without claiming gas affordability',
      () async {
    wallet.balances = {CryptoCurrency.eth: _Balance(Money.parse('1', CryptoCurrency.eth))};
    final trade = await create();
    expect(trade.executionJson, isNotNull);
    expect(calls, ['GET /quote', 'POST /swap']);
    expect(wallet.builds, 0);
  });

  test('one wei of source shortage prevents creation despite double precision equality', () async {
    wallet.balances = {
      CryptoCurrency.eth: _Balance(Money.parse('0.999999999999999999', CryptoCurrency.eth))
    };
    await expectLater(
        create(),
        throwsA(isA<TransactionWrongBalanceException>().having(
            (error) => error.requiredBalance! - error.availableBalance!,
            'one wei shortfall',
            Money.fromInt(1, CryptoCurrency.eth))));
    expect(calls, isEmpty);
    expect(wallet.builds, 0);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = PegarouteProviderPreferences(await SharedPreferences.getInstance());
    decentralizedOnly = false;
    receiveCurrency = CryptoCurrency.xmr;
    sourceAmount = '1';
    database = await _database();
    wallet = _Wallet();
    originalEvm = evm!;
    evm = _Evm(originalEvm);
    active = Observable<WalletBase?>(wallet);
    context =
        PegarouteActiveWalletContext(() => active.value, supportsWallet: pegarouteTrustedWallet);
    quote = _fixture('quote')..['expiresAt'] = '2099-01-01T00:00:00.000Z';
    swap = _fixture('swap');
    (swap['execution'] as Map)['value'] = {'display': '1', 'baseUnits': '1000000000000000000'};
    ((swap['provider'] as Map)['details']['instaswapSwapLite'] as Map)['expiresAt'] = null;
    calls = [];
    sourceHash = ackHash = ackId = null;
    failCreation = failCallback = completed = false;
    afterQuote = afterPost = null;
    mutateStatus = null;
    storeHash = true;
    final api = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://fixture.invalid'),
      get: (uri, headers) async {
        expect(headers, isEmpty);
        calls.add('GET ${uri.path}');
        if (uri.path == '/quote') {
          if (uri.queryParameters.containsKey('destinationAddress')) {
            expect(uri.queryParameters['destinationAddress'], payoutAddress());
            expect(uri.queryParameters['senderAddress'], _key.address.hex);
          }
          afterQuote?.call();
          return very_insecure_http_do_not_use.Response(jsonEncode(quote), 200);
        }
        expect(uri.path, '/swap/transaction-fixture');
        final body = <String, dynamic>{
          'transactionId': 'transaction-fixture',
          'status': completed
              ? 'success'
              : sourceHash == null
                  ? 'pending'
                  : 'executing',
          'internalStatus': completed
              ? 'completed'
              : sourceHash == null
                  ? 'pending'
                  : 'submitted',
          'route': swap['route'],
          'execution': swap['execution'],
          'provider': swap['provider'],
          'input': {
            'chain': const PegarouteCurrencyMapper().map(wallet.sourceCurrency).chain,
            'token': const PegarouteCurrencyMapper().map(wallet.sourceCurrency).token,
            'amount': sourceAmount,
            'address': _key.address.hex,
            'refundAddress': _key.address.hex,
            if (sourceHash != null) 'txHash': sourceHash
          },
          'output': {
            'chain': const PegarouteCurrencyMapper().map(receiveCurrency).chain,
            'token': const PegarouteCurrencyMapper().map(receiveCurrency).token,
            'address': payoutAddress(),
            if (completed) 'amount': '0.99',
            if (completed) 'txHash': 'xmr-output-fixture'
          },
          'fees': (swap['route'] as Map)['fees'],
          'timestamps': {'created': '2026-01-01T00:00:00.000Z'},
          'error': null,
          'refund': null,
          'streamingProgress': null,
        };
        mutateStatus?.call(body);
        return very_insecure_http_do_not_use.Response(jsonEncode(body), 200);
      },
      post: (uri, headers, body) async {
        calls.add('POST ${uri.path}');
        expect(headers, {'Content-Type': 'application/json'});
        final value = jsonDecode(body);
        if (uri.path == '/swap') {
          expect(value['quoteId'], 'quote-fixture');
          expect(value['routeProvider'], swap['route']['provider']);
          expect(value['senderAddress'], _key.address.hex);
          expect(value['destinationAddress'], payoutAddress());
          expect(value.containsKey('private'), false);
          if (failCreation) throw const SocketException('Lost creation response');
          afterPost?.call();
          return very_insecure_http_do_not_use.Response(jsonEncode(swap), 202);
        }
        expect(uri.path, '/swap/transaction-fixture/txhash');
        expect(value['txHash'], wallet.pending.evmTxHashFromRawHex);
        if (failCallback) throw const SocketException('Lost notification response');
        if (storeHash) sourceHash = value['txHash'] as String;
        return very_insecure_http_do_not_use.Response(
            jsonEncode({
              'transactionId': ackId ?? 'transaction-fixture',
              'status': 'submitted',
              'txHash': ackHash ?? value['txHash']
            }),
            200);
      },
    );
    provider = PegarouteExchangeProvider(
      apiClient: api,
      currentWallet: () => active.value,
      providerPreferences: preferences,
      decentralizedOnly: () => decentralizedOnly,
      executableQuotesOnly: true,
      currencyLookup: (chain, token) async =>
          token == const PegarouteCurrencyMapper().map(wallet.sourceCurrency).token
              ? wallet.sourceCurrency
              : receiveCurrency,
    );
    dispatcher = RegistryTradeExecutionDispatcher([
      PegarouteTrustedExecutionHandler(
        walletContext: context,
        adapter: PegarouteTrustedWalletAdapter(priority: (_) => EVMChainTransactionPriority.medium),
        lifecycle: PegarouteExecutionLifecycleStore(),
        onSourceCommitted: provider.notifyCommitted,
        approvalFlow: const PegarouteApprovalFlow(pollAttempts: 1),
      ),
    ]);
  });

  tearDown(() async {
    context.dispose();
    evm = originalEvm;
    await database.close();
    sqlite.db = null;
  });

  void contractRoute(String routeProvider) {
    receiveCurrency = _usdc;
    final route = Map<String, dynamic>.from(quote['routes'][0] as Map)
      ..['provider'] = routeProvider
      // Direct routes omit this optional field in the real API.
      ..remove('subprovider');
    route['providerType'] = routeProvider == 'openocean' ? 'dex-aggregator' : 'cross-chain-amm';
    swap['providerType'] = route['providerType'];
    if (routeProvider != 'openocean') {
      route['router'] = _deposit;
      route['memo'] = '=:BTC:trusted-payout:123';
      route['expiry'] = 4070908800;
    }
    quote['routes'] = [route];
    swap['route'] = {
      for (final key in ['provider', 'private', 'expectedOutput', 'fees', 'estimatedTimeSeconds'])
        key: route[key],
    };
    swap['provider'] = {'name': routeProvider, 'referenceId': null};
    swap['execution'] = {
      'family': 'evm',
      'mode': 'contract-call',
      'chainId': wallet.chainId,
      'to': _deposit,
      'data': _calldata,
      'memo': route['memo'],
      'value': {'display': '1', 'baseUnits': '1000000000000000000'},
      'gasLimit': null,
      'approval': null,
      'transferAmount': null,
    };
  }

  void approvalRoute({Erc20Token? token}) {
    final source = token ?? _usdc;
    runInAction(() => wallet.selectedChain.value = source.chainId!);
    wallet.sourceCurrency = source;
    contractRoute('openocean');
    receiveCurrency = _nativeCurrency[source.chainId]!;
    swap['execution']['value'] = {'display': '0', 'baseUnits': '0'};
    swap['execution']['approval'] = {
      'tokenAddress': source.contractAddress,
      'spender': _deposit,
      'amount': {'display': '1', 'baseUnits': BigInt.from(10).pow(source.decimals).toString()}
    };
    swap['execution']['gasLimit'] = '351834';
  }

  for (final routeProvider in ['thorchain', 'openocean']) {
    test('$routeProvider 0.001 ETH to USDC survives optional metadata and status enrichment',
        () async {
      contractRoute(routeProvider);
      sourceAmount = '0.001';
      final route = quote['routes'][0] as Map;
      final output = routeProvider == 'openocean' ? '2.491093' : '2.18850384';
      route['expectedOutput'] = swap['route']['expectedOutput'] = output;
      route['minAmount'] = null;
      route['futureInfo'] = 'quote metadata';
      swap['futureInfo'] = {'new': 'response metadata'};
      (swap['route'] as Map)
        ..remove('private')
        ..['futureInfo'] = 'order metadata';
      swap['execution']['value'] = {'display': sourceAmount, 'baseUnits': '1000000000000000'};
      if (routeProvider == 'openocean') {
        route['openOceanRoute'] = {
          'dexes': [
            {'dexId': 5, 'dexCode': 'UniswapV3'}
          ]
        };
        swap['route']['openOceanRoute'] = {
          ...route['openOceanRoute'] as Map,
          'dexId': 5,
          'dexCode': 'UniswapV3',
        };
      }

      final trade = await create();
      final restored = (await Trade.getByTradeId(trade.id))!;
      expect(restored.receiveAmount, output);
      expect(TradeExecution.fromJsonString(restored.executionJson!).subprovider, isNull);
      expect(tradeProviderDisplayName(restored),
          'Pegaroute via ${routeProvider == 'openocean' ? 'OpenOcean' : 'THORChain'}');
      final pending = (await dispatcher.prepare(wallet: wallet, trade: restored))!;
      expect(inspectPegarouteEvm(pending.hex, context.snapshot(wallet)).valueBaseUnits,
          '1000000000000000');
      expect(wallet.broadcasts, 0);
      // Later informational observations cannot block successful funding/status.
      swap['route']['subprovider'] = 'later-label';
      swap['route']['openOceanRoute'] = {'dexId': 9, 'dexCode': 'later-dex'};
      await pending.commit();
      final stored = (await Trade.getByTradeId(trade.id))!;
      expect(stored.txId, pending.id);
      expect(TradeExecutionLifecycle.fromJsonString(stored.executionLifecycleJson!).callbackState,
          TradeExecutionCallbackState.accepted);
      await expectLater(pending.commit(), throwsA(isA<PegarouteBindingException>()));
      expect(calls.where((call) => call == 'POST /swap'), hasLength(1));
      expect(wallet.broadcasts, 1);
    });
  }

  test('equivalent external amounts preserve original funding and execution bytes', () async {
    sourceAmount = '1.0';
    final trade = await create();
    final raw = trade.executionJson;
    mutateStatus = (body) => body['input']['amount'] = '1.000000';
    final updated = await provider.refreshTradeStatus(trade: trade);
    expect(updated.amount, '1.0');
    expect(updated.executionJson, raw);
    expect(
        TradeExecution.fromJsonString(raw!).binding.sourceAmountBaseUnits, '1000000000000000000');
    mutateStatus = (body) => body['input']['amount'] = '1.000000000000000001';
    await expectLater(
        provider.refreshTradeStatus(trade: updated), throwsA(isA<PegarouteBindingException>()));
  });

  test('bare output ticker never substitutes for canonical USDC on completed status', () async {
    contractRoute('openocean');
    final trade = await create();
    completed = true;
    mutateStatus = (body) => body['output']['token'] = 'USDC';
    await expectLater(
        provider.refreshTradeStatus(trade: trade), throwsA(isA<PegarouteBindingException>()));
    expect((await Trade.getByTradeId(trade.id))!.state, isNot(TradeState.success));
  });

  for (final scenario in [
    'funded',
    'unfunded',
    'disabled',
    'tor',
    'terminal',
    'recent',
    'bad-lifecycle'
  ]) {
    test('monitor reopens old Pegaroute trade: $scenario', () async {
      final trade = await create();
      if (scenario != 'unfunded') {
        final pending = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
        await pending.commit();
      }
      final stored = (await Trade.getByTradeId(trade.id))!;
      final now = DateTime.utc(2026, 9, 14);
      stored.createdAt = now.subtract(const Duration(days: 3));
      if (scenario == 'terminal') stored.stateRaw = TradeState.success.raw;
      if (scenario == 'bad-lifecycle') stored.executionLifecycleJson = '{}';
      await database.update(
          'Trade',
          {
            'createdAt': stored.createdAt!.millisecondsSinceEpoch,
            'stateRaw': stored.stateRaw,
            'executionLifecycleJson': stored.executionLifecycleJson,
          },
          where: 'id = ?',
          whereArgs: [stored.id]);
      final app = _MonitorApp();
      final settings = _MonitorSettings();
      final trades = _MonitorTrades();
      when(() => app.wallet).thenReturn(wallet);
      when(() => app.settingsStore).thenReturn(settings);
      when(() => settings.disableAutomaticExchangeStatusUpdates).thenReturn(scenario == 'disabled');
      when(() => settings.exchangeStatus)
          .thenReturn(scenario == 'tor' ? ExchangeApiMode.torOnly : ExchangeApiMode.enabled);
      when(() => trades.trades)
          .thenReturn([TradeListItem(trade: stored, appStore: app, key: const ValueKey('trade'))]);
      final prefs = await SharedPreferences.getInstance();
      if (scenario == 'recent')
        await prefs.setString('trade_${trade.id}_updated_at', now.toIso8601String());
      final monitor = TradeMonitor(
          tradesStore: trades,
          appStore: app,
          preferences: prefs,
          clock: () => now,
          providerFactory: (_) => provider);
      addTearDown(monitor.stopTradeMonitoring);
      completed = true;
      calls.clear();
      monitor.resumeTradeMonitoring();
      monitor.resumeTradeMonitoring();
      // Drain the mocked HTTP + in-memory SQLite work without advancing the timer.
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(calls.where((call) => call == 'GET /swap/transaction-fixture').length,
          scenario == 'funded' ? 1 : 0);
      expect(wallet.broadcasts, scenario == 'unfunded' ? 0 : 1);
      if (scenario == 'funded') {
        expect((await Trade.getByTradeId(trade.id))!.state, TradeState.success);
        expect(prefs.getString('trade_${trade.id}_updated_at'), now.toIso8601String());
      }
    });
  }

  for (final routeProvider in ['instaswap', 'thorchain', 'maya', 'openocean']) {
    test('$routeProvider history retains the created-order subprovider, not the quote label',
        () async {
      if (routeProvider != 'instaswap') contractRoute(routeProvider);
      quote['routes'][0]['subprovider'] = 'quote-label';
      swap['route']['subprovider'] = 'created-label';
      final trade = await create();
      final restored = (await Trade.getByTradeId(trade.id))!;
      expect(TradeExecution.fromJsonString(restored.executionJson!).subprovider, 'created-label');
      expect(tradeProviderDisplayName(restored), endsWith(' (via created-label)'));
      expect(await dispatcher.prepare(wallet: wallet, trade: restored), isNotNull);
      expect(wallet.broadcasts, 0);
    });
  }

  test('Instaswap transfer can use authenticated execution without optional provider details',
      () async {
    (swap['provider'] as Map).remove('details');
    final trade = await create();
    expect(
        TradeExecution.fromJsonString(trade.executionJson!).binding.providerDepositAddress, isNull);
    expect(await dispatcher.prepare(wallet: wallet, trade: trade), isNotNull);
    expect(wallet.broadcasts, 0);
  });

  test('post-creation failure reports the order ID and a bounded validation reason', () async {
    contractRoute('thorchain');
    swap['execution']['chainId'] = 100;
    await expectLater(
      create(),
      throwsA(isA<PegarouteSwapAttemptException>()
          .having((error) => error.providerTransactionId, 'order ID', 'transaction-fixture')
          .having((error) => error.userMessage, 'visible order ID', contains('transaction-fixture'))
          .having((error) => error.diagnosticMessage, 'reason', 'execution EVM chain is not bound')
          .having((error) => error.boundary, 'no fallback',
              TradeCreationFailureBoundary.requestMayHaveReached)),
    );
    expect(calls.where((call) => call == 'POST /swap'), hasLength(1));
    expect(wallet.builds, 0);
    expect(wallet.broadcasts, 0);
  });

  for (final chain in {
    1: CryptoCurrency.eth,
    56: CryptoCurrency.bnb,
    8453: CryptoCurrency.baseEth,
    42161: CryptoCurrency.arbEth,
    137: CryptoCurrency.maticpoly,
  }.entries) {
    for (final routeProvider in ['instaswap', 'thorchain', 'maya', 'openocean']) {
      test('$routeProvider single native transaction on chain ${chain.key}, restored and committed',
          () async {
        runInAction(() => wallet.selectedChain.value = chain.key);
        wallet.sourceCurrency = chain.value;
        swap['execution']['chainId'] = chain.key;
        if (routeProvider != 'instaswap') contractRoute(routeProvider);
        swap['execution']['gasLimit'] = '351834';
        final trade = await create();
        final restored = (await Trade.getByTradeId(trade.id))!;
        final pending = (await dispatcher.prepare(wallet: wallet, trade: restored))!;
        final evidence = inspectPegarouteEvm(pending.hex, context.snapshot(wallet));
        expect(evidence.chainId, chain.key);
        expect(evidence.data, routeProvider == 'instaswap' ? isNull : _calldata);
        expect(evidence.valueBaseUnits, '1000000000000000000');
        expect(evidence.gasLimit, '351834');
        await pending.commit();
        final stored = (await Trade.getByTradeId(trade.id))!;
        expect(stored.txId, pending.id);
        expect(TradeExecutionLifecycle.fromJsonString(stored.executionLifecycleJson!).callbackState,
            TradeExecutionCallbackState.accepted);
        await expectLater(pending.commit(), throwsA(isA<PegarouteBindingException>()));
        expect(wallet.broadcasts, 1);
      });
    }
  }

  test('rejects signed bytes below the supplied gas limit before broadcasting', () async {
    contractRoute('openocean');
    swap['execution']['gasLimit'] = '351834';
    final trade = await create();
    wallet.mutation = 'gas';
    expect(await dispatcher.prepare(wallet: wallet, trade: trade), isNull);
    expect(wallet.broadcasts, 0);
  });

  void revertedStatus(Map<String, dynamic> body) {
    body['status'] = 'fail';
    body['internalStatus'] = 'failed';
    body['input']['amount'] = '0';
    body['output']['amount'] = '0';
    if (sourceHash != null) body['output']['txHash'] = sourceHash;
    body['error'] = {
      'code': 'TRANSACTION_FAILED',
      'message': 'Transaction failed on-chain',
      'userMessage': 'Transaction failed on-chain',
      'retryable': false
    };
  }

  for (final zero in ['0', '0.000000']) {
    test(
        'reverted OpenOcean $zero amounts settle the saved broadcast as failed, never refund/retry',
        () async {
      contractRoute('openocean');
      final trade = await create();
      final raw = trade.executionJson;
      final pending = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
      await pending.commit();
      final funded = (await Trade.getByTradeId(trade.id))!;
      final lifecycle = funded.executionLifecycleJson;
      mutateStatus = (body) {
        revertedStatus(body);
        body['input']['amount'] = zero;
        body['output']['amount'] = zero;
      };
      await provider.refreshTradeStatus(trade: funded);
      final restored = (await Trade.getByTradeId(trade.id))!;
      expect(restored.stateRaw, 'failed');
      expect(restored.amount, '1');
      expect(restored.receiveAmount, zero);
      expect(restored.txId, pending.id);
      expect(restored.executionJson, raw);
      expect(restored.executionLifecycleJson, lifecycle);
      expect(restored.isRefund, isNot(true));
      final reopened = await dispatcher.prepare(wallet: wallet, trade: restored);
      if (reopened != null) {
        await expectLater(reopened.commit(), throwsA(isA<PegarouteBindingException>()));
      }
      await expectLater(pending.commit(), throwsA(isA<PegarouteBindingException>()));
      expect(wallet.broadcasts, 1);
      expect(calls.where((call) => call == 'POST /swap'), hasLength(1));
    });
  }

  for (final mutation in [
    'hash',
    'missing hash',
    'pending',
    'success',
    'nonzero input',
    'destination',
    'provider',
    'unfunded'
  ]) {
    test('zero-amount failure does not relax $mutation binding', () async {
      contractRoute('openocean');
      final trade = await create();
      if (mutation != 'unfunded') {
        final pending = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
        await pending.commit();
      }
      final stored = (await Trade.getByTradeId(trade.id))!;
      final before = stored.toSqliteMap();
      mutateStatus = (body) {
        revertedStatus(body);
        switch (mutation) {
          case 'hash':
            body['input']['txHash'] = '0x${'a' * 64}';
          case 'missing hash':
            (body['input'] as Map).remove('txHash');
          case 'pending':
            body['status'] = body['internalStatus'] = 'pending';
          case 'success':
            body['status'] = 'success';
            body['internalStatus'] = 'completed';
          case 'nonzero input':
            body['input']['amount'] = '0.5';
          case 'destination':
            body['output']['address'] = _deposit;
          case 'provider':
            body['route'] = {...body['route'] as Map, 'provider': 'thorchain'};
            body['provider'] = {...body['provider'] as Map, 'name': 'thorchain'};
          case 'unfunded':
            body['input']['txHash'] = '0x${'a' * 64}';
        }
      };
      await expectLater(
          provider.refreshTradeStatus(trade: stored), throwsA(isA<PegarouteBindingException>()));
      expect((await Trade.getByTradeId(trade.id))!.toSqliteMap(), before);
    });
  }

  for (final chain in [1, 56]) {
    for (final mutation in ['amount', 'to', 'data', 'chain', 'signer']) {
      test(
          'contract $mutation mismatch in ${chain == 1 ? 'type-2' : 'legacy'} signed bytes rejects',
          () async {
        runInAction(() => wallet.selectedChain.value = chain);
        wallet.sourceCurrency = chain == 1 ? CryptoCurrency.eth : CryptoCurrency.bnb;
        contractRoute('openocean');
        final trade = await create();
        wallet.mutation = mutation;
        expect(await dispatcher.prepare(wallet: wallet, trade: trade), isNull);
        expect(wallet.broadcasts, 0);
      });
    }
  }

  for (final token in [
    _usdc,
    Erc20Token(
        name: 'USD Coin',
        symbol: 'USDC',
        decimal: 18,
        chainId: 56,
        tag: 'BSC',
        contractAddress: '0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d'),
    Erc20Token(
        name: 'USD Coin',
        symbol: 'USDC',
        decimal: 6,
        chainId: 8453,
        tag: 'BASE',
        contractAddress: '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913'),
    Erc20Token(
        name: 'USD Coin',
        symbol: 'USDC',
        decimal: 6,
        chainId: 42161,
        tag: 'ARB',
        contractAddress: '0xaf88d065e77c8cc2239327c5edb3a432268e5831'),
    Erc20Token(
        name: 'USD Coin',
        symbol: 'USDC',
        decimal: 6,
        chainId: 137,
        tag: 'POL',
        contractAddress: '0x3c499c542cef5e3811e1192ce70d8cc03d5c3359'),
  ]) {
    test('USDC deposit on ${token.chainId} builds one exact ERC20 transfer with zero native value',
        () async {
      wallet.sourceCurrency = token;
      runInAction(() => wallet.selectedChain.value = token.chainId!);
      final units = BigInt.from(10).pow(token.decimals);
      swap['execution'] = {
        'family': 'evm',
        'mode': 'erc20-transfer',
        'chainId': token.chainId,
        'to': _deposit,
        'value': null,
        'transferAmount': {'display': '1', 'baseUnits': units.toString()},
        'data': null,
        'gasLimit': null,
        'memo': null,
        'approval': null,
      };
      final trade = await create();
      final restored = (await Trade.getByTradeId(trade.id))!;
      expect(restored.from, isA<Erc20Token>());
      final pending = (await dispatcher.prepare(wallet: wallet, trade: restored))!;
      final evidence = inspectPegarouteEvm(pending.hex, context.snapshot(wallet));
      expect(evidence.to, token.contractAddress);
      expect(evidence.valueBaseUnits, '0');
      expect(
          evidence.data,
          '0xa9059cbb${_deposit.substring(2).padLeft(64, '0')}'
          '${units.toRadixString(16).padLeft(64, '0')}');
      expect(pending.amount.amount, units);
      expect(pending.amount.currency.decimals, token.decimals);
      expect(pending.amount.currency.tag, token.tag);
      await pending.commit();
      expect(wallet.builds, 1);
      expect(wallet.broadcasts, 1);
    });
    test('USDC approval and final swap on ${token.chainId} use exact units and native gas',
        () async {
      approvalRoute(token: token);
      final trade = await create();
      final approval = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
      expect(tradeExecutionPrerequisiteDescription(approval), startsWith('Approve'));
      expect(approval.amount.amount, BigInt.from(10).pow(token.decimals));
      expect(approval.fee.currency, _nativeCurrency[token.chainId]);
      await approval.commit();
      final payment =
          (await dispatcher.prepare(wallet: wallet, trade: (await Trade.getByTradeId(trade.id))!))!;
      expect(tradeExecutionPrerequisiteDescription(payment), isNull);
      await payment.commit();
      expect(wallet.signedNonces, [7, 8]);
      expect(wallet.broadcasts, 2);
      expect((await Trade.getByTradeId(trade.id))!.txId, payment.id);
    });
  }

  test('trusted handler enforces supplied contract expiry at the funding boundary', () async {
    contractRoute('thorchain');
    final trade = await create();
    final validated =
        const PegarouteExecutionBindingValidator().validatePersisted(trade: trade, wallet: wallet);
    expect(
        () => dispatcher.handlers.single
            .validateForExecution(execution: validated, now: DateTime.utc(2100)),
        throwsA(isA<PegarouteBindingException>()));
    expect(wallet.builds, 0);
  });

  for (final destination in [CryptoCurrency.usdc, CryptoCurrency.usdcsol]) {
    test(
        'catalog ${destination.name} destination alias retains identity through creation and restore',
        () async {
      if (destination == CryptoCurrency.usdc) contractRoute('openocean');
      receiveCurrency = destination;
      final trade = await create();
      final restored = (await Trade.getByTradeId(trade.id))!;
      expect(restored.to, destination == CryptoCurrency.usdc ? isA<Erc20Token>() : isA<SPLToken>());
      final pending = (await dispatcher.prepare(wallet: wallet, trade: restored))!;
      await pending.commit();
      expect(wallet.broadcasts, 1);
    });
  }

  test('catalog USDC source alias is resolved before persisting its deposit order', () async {
    wallet.sourceCurrency = CryptoCurrency.usdc;
    swap['execution']['mode'] = 'erc20-transfer';
    swap['execution']['value'] = null;
    swap['execution']['transferAmount'] = {'display': '1', 'baseUnits': '1000000'};
    final trade = await create();
    expect(trade.from, isA<Erc20Token>());
    final restored = (await Trade.getByTradeId(trade.id))!;
    expect((restored.from as Erc20Token).contractAddress, _usdc.contractAddress);
    final pending = (await dispatcher.prepare(wallet: wallet, trade: restored))!;
    await pending.commit();
    expect(wallet.broadcasts, 1);
  });

  test('restored native orders cannot acquire extra transfer or approval instructions', () async {
    contractRoute('openocean');
    final trade = await create();
    for (final extra in ['approval', 'transferAmount']) {
      final value = jsonDecode(trade.executionJson!) as Map<String, dynamic>;
      if (extra == 'approval') {
        value['payload'][extra] = {
          'spender': _deposit,
          'tokenAddress': _usdc.contractAddress,
          'amount': {'display': '1', 'baseUnits': '1000000'},
        };
        expect(dispatcher.supports(TradeExecution.fromJson(value)), false);
      } else {
        value['payload'][extra] = {'display': '1', 'baseUnits': '1'};
        expect(() => TradeExecution.fromJson(value), throwsFormatException);
      }
    }
    expect(wallet.builds, 0);
  });

  test('creation chooses the highest enabled executable quote, independent of response order',
      () async {
    final deposit = quote['routes'][0];
    contractRoute('openocean');
    final dex = {...(quote['routes'][0] as Map<String, dynamic>), 'expectedOutput': '1.01'};
    swap['route']['expectedOutput'] = '1.01';
    quote['routes'] = [deposit, dex];
    final trade = await create();
    expect(trade.providerName, 'openocean');
    expect(trade.receiveAmount, '1.01');
  });

  test('DEX disabled during the quote never reaches POST', () async {
    contractRoute('openocean');
    afterQuote = () => preferences.setEnabled('openocean', false);
    await expectLater(create(), throwsA(isA<PegarouteUnavailableException>()));
    expect(calls, ['GET /quote']);
  });

  test('approval instructions after creation block fallback without signing', () async {
    contractRoute('openocean');
    swap['execution']['approval'] = {
      'spender': _deposit,
      'tokenAddress': _usdc.contractAddress,
      'amount': {'display': '1', 'baseUnits': '1000000'},
    };
    await expectLater(create(), throwsA(isA<PegarouteSwapAttemptException>()));
    expect(calls, ['GET /quote', 'POST /swap']);
    expect(wallet.builds, 0);
  });

  test('expired contract quote blocks POST and wallet use', () async {
    contractRoute('thorchain');
    quote['routes'][0]['expiry'] = 1;
    await expectLater(create(), throwsA(isA<PegarouteBindingException>()));
    expect(calls, ['GET /quote']);
    expect(wallet.builds, 0);
  });

  test('fresh ETH -> XMR quote, nullable-expiry order, persisted deposit, callback and status',
      () async {
    final trade = await create();
    expect(wallet.builds, 0);
    expect(trade.inputAddress, _deposit);
    expect(trade.expiredAt, isNull);
    final binding = TradeExecution.fromJsonString(trade.executionJson!).binding;
    expect(binding.walletId, wallet.id);
    expect(binding.providerTransactionId, 'transaction-fixture');
    expect(binding.providerDepositExpiry, isNull);
    final restored = (await Trade.getByTradeId(trade.id))!;
    final pending = await dispatcher.prepare(wallet: wallet, trade: restored);
    expect(pending, isNotNull);
    expect(wallet.broadcasts, 0);
    expect(pending!.id, wallet.pending.evmTxHashFromRawHex);
    expect(pending.id, isNot(wallet.pending.id));
    expect(pending.fee.amount, BigInt.from(42000));
    await pending.commit();
    expect(wallet.broadcasts, 1);
    final funded = (await Trade.getByTradeId(trade.id))!;
    expect(funded.txId, pending.id);
    final lifecycle = TradeExecutionLifecycle.fromJsonString(funded.executionLifecycleJson!);
    expect(lifecycle.state, TradeExecutionLifecycleState.broadcasted);
    expect(lifecycle.callbackState, TradeExecutionCallbackState.accepted);
    expect(calls, [
      'GET /quote',
      'POST /swap',
      'POST /swap/transaction-fixture/txhash',
      'GET /swap/transaction-fixture'
    ]);
    completed = true;
    await provider.refreshTradeStatus(trade: restored);
    expect(restored.stateRaw, 'success');
    expect(restored.outputTransaction, 'xmr-output-fixture');
    expect(restored.executionJson, trade.executionJson);
    await expectLater(pending.commit(), throwsA(isA<PegarouteBindingException>()));
    expect(wallet.broadcasts, 1);
  });

  for (final mode in ['amount', 'to', 'data', 'chain', 'signer']) {
    test('rejects signed $mode mismatch before broadcast', () async {
      final trade = await create();
      wallet.mutation = mode;
      expect(await dispatcher.prepare(wallet: wallet, trade: trade), isNull);
      expect(wallet.broadcasts, 0);
    });
  }

  test('prepared byte mutation and active wallet ABA cannot commit', () async {
    final trade = await create();
    final pending = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    wallet.pending.signedTransaction[10] ^= 1;
    await expectLater(pending.commit(), throwsA(isA<PegarouteBindingException>()));
    expect(wallet.broadcasts, 0);
    final second = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    runInAction(() => active.value = _Wallet());
    runInAction(() => active.value = wallet);
    await expectLater(second.commit(), throwsA(isA<PegarouteBindingException>()));
    expect(wallet.broadcasts, 0);
  });

  test('chain ABA during wallet construction discards signed transaction', () async {
    final trade = await create();
    wallet.duringBuild = () async {
      runInAction(() => wallet.selectedChain.value = 56);
      runInAction(() => wallet.selectedChain.value = 1);
    };
    expect(await dispatcher.prepare(wallet: wallet, trade: trade), isNull);
    expect(wallet.broadcasts, 0);
  });

  test('ambiguous creation blocks provider fallback', () async {
    failCreation = true;
    try {
      await create();
      fail('Expected ambiguous POST failure');
    } catch (error) {
      expect(error, isA<PegarouteSwapAttemptException>());
      expect(blocksTradeCreationFallback(error), true);
    }
    expect(calls, ['GET /quote', 'POST /swap']);
    expect(wallet.builds, 0);
  });

  test('wallet changes before POST abort; changes after POST block fallback', () async {
    void changeWallet() => runInAction(() => active.value = _Wallet());
    afterQuote = changeWallet;
    await expectLater(create(), throwsA(isA<PegarouteBindingException>()));
    expect(calls, ['GET /quote']);
    afterQuote = null;
    runInAction(() => active.value = wallet);
    calls.clear();
    afterPost = changeWallet;
    await expectLater(create(), throwsA(isA<PegarouteSwapAttemptException>()));
    expect(calls, ['GET /quote', 'POST /swap']);
    expect(wallet.builds, 0);
  });

  test('malformed signed network bytes fail closed', () async {
    final trade = await create();
    await dispatcher.prepare(wallet: wallet, trade: trade);
    final raw = wallet.pending.hex;
    for (final invalid in [
      '0x',
      '0x0102',
      '${raw}00',
      raw.substring(0, raw.length - 2),
      '0x02${raw.substring(2)}',
      '0xzz'
    ]) {
      expect(() => inspectPegarouteNativeEth(invalid, context.snapshot(wallet)),
          throwsA(isA<PegarouteBindingException>()));
    }
    expect(wallet.broadcasts, 0);
  });

  test('two separately prepared instances share the durable one-shot boundary', () async {
    final trade = await create();
    final first = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    final second = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    await first.commit();
    await expectLater(
        second.commit(), throwsA(anyOf(isA<StateError>(), isA<PegarouteBindingException>())));
    expect(wallet.broadcasts, 1);
  });

  test('an OpenOcean native-transfer envelope is not an Instaswap deposit', () async {
    final trade = await create();
    final value = jsonDecode(trade.executionJson!) as Map<String, dynamic>;
    value['routeProvider'] = 'openocean';
    final execution = TradeExecution.fromJson(value);
    final handler = PegarouteEthExecutionHandler(
      nativeDepositsOnly: true,
      walletContext: context,
      adapter: PegarouteNativeEthWalletAdapter(priority: (_) => EVMChainTransactionPriority.medium),
      lifecycleHandler: PegarouteExecutionLifecycleStore(),
    );
    expect(pegarouteNativeEthDeposit(execution), false);
    expect(handler.supports(execution), false);
    expect(wallet.builds, 0);
    expect(wallet.broadcasts, 0);
  });

  for (final failure in ['transport', 'wrong-id', 'wrong-hash', 'ack-without-storage']) {
    test('callback $failure preserves successful one-shot funding', () async {
      final trade = await create();
      failCallback = failure == 'transport';
      ackId = failure == 'wrong-id' ? 'other-id' : null;
      ackHash = failure == 'wrong-hash' ? '0x${'aa' * 32}' : null;
      storeHash = failure != 'ack-without-storage';
      final pending = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
      await pending.commit();
      final stored = (await Trade.getByTradeId(trade.id))!;
      final lifecycle = TradeExecutionLifecycle.fromJsonString(stored.executionLifecycleJson!);
      expect(lifecycle.state, TradeExecutionLifecycleState.broadcasted);
      expect(lifecycle.callbackState, isNot(TradeExecutionCallbackState.accepted));
      expect(stored.txId, pending.id);
      await expectLater(pending.commit(), throwsA(isA<PegarouteBindingException>()));
      expect(wallet.broadcasts, 1);
      // A later authenticated status observation can confirm the notification.
      sourceHash = pending.id;
      await provider.refreshTradeStatus(trade: stored);
      expect(TradeExecutionLifecycle.fromJsonString(stored.executionLifecycleJson!).callbackState,
          TradeExecutionCallbackState.accepted);
    });
  }

  test('wrong observed source hash cannot replace local funding evidence', () async {
    final trade = await create();
    failCallback = true;
    final pending = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    await pending.commit();
    sourceHash = '0x${'aa' * 32}';
    await expectLater(
        provider.refreshTradeStatus(trade: trade), throwsA(isA<PegarouteBindingException>()));
    expect((await Trade.getByTradeId(trade.id))!.txId, pending.id);
  });

  test('private and contract quotes never create an order', () async {
    (quote['routes'][0] as Map)['private'] = true;
    await expectLater(create(), throwsA(isA<PegarouteUnavailableException>()));
    (quote['routes'][0] as Map)['private'] = false;
    (quote['routes'][0] as Map)['memo'] = 'memo';
    await expectLater(create(), throwsA(isA<PegarouteUnavailableException>()));
    expect(calls.where((call) => call.startsWith('POST')), isEmpty);
  });

  test('exchange comparison includes enabled executable DEX calls', () async {
    final deposit = Map<String, dynamic>.from(quote['routes'][0] as Map)
      ..['expectedOutput'] = '11.66'
      ..['minAmount'] = '0.004';
    quote['routes'] = [
      {...deposit, 'provider': 'openocean', 'expectedOutput': '12.33', 'minAmount': '0.0001'},
      deposit,
    ];
    expect(
        await provider.fetchRate(
          from: CryptoCurrency.eth,
          to: CryptoCurrency.usdc,
          amount: 0.005,
          isFixedRateMode: false,
          isReceiveAmount: false,
        ),
        closeTo(12.33 / 0.005, 0.000001));
    expect(
        (await provider.fetchLimits(
          from: CryptoCurrency.eth,
          to: CryptoCurrency.usdc,
          isFixedRateMode: false,
        ))!
            .min,
        0.0001);
    await preferences.setEnabled('instaswap', false);
    expect(provider.isExecutionAvailable, true);
    expect(
        await provider.fetchRate(
          from: CryptoCurrency.eth,
          to: CryptoCurrency.usdc,
          amount: 0.005,
          isFixedRateMode: false,
          isReceiveAmount: false,
        ),
        closeTo(12.33 / 0.005, 0.000001));
    expect(calls, ['GET /quote', 'GET /quote', 'GET /quote']);
    expect(wallet.builds, 0);
  });

  test('an enabled route without a minimum does not inherit another route minimum', () async {
    final route = Map<String, dynamic>.from(quote['routes'][0] as Map);
    quote['routes'] = [
      {...route, 'provider': 'instaswap', 'minAmount': '12'},
      {...route, 'provider': 'openocean', 'minAmount': null},
    ];
    Future<double?> minimum() async =>
        (await provider.fetchLimits(from: _usdc, to: CryptoCurrency.eth, isFixedRateMode: false))
            ?.min;
    expect(await minimum(), 0);
    await preferences.setEnabled('openocean', false);
    expect(await minimum(), 12);
    await preferences.setEnabled('instaswap', false);
    await preferences.setEnabled('openocean', true);
    expect(await minimum(), 0);
    expect(calls.where((call) => call.startsWith('POST')), isEmpty);
  });

  test('disabled or decentralized-only Instaswap cannot create an order', () async {
    await preferences.setEnabled('instaswap', false);
    await expectLater(create(), throwsA(isA<PegarouteUnavailableException>()));
    await preferences.setEnabled('instaswap', true);
    decentralizedOnly = true;
    await expectLater(create(), throwsA(isA<PegarouteUnavailableException>()));
    expect(calls, ['GET /quote', 'GET /quote']);
    decentralizedOnly = false;
    calls.clear();
    afterQuote = () => preferences.setEnabled('instaswap', false);
    await expectLater(create(), throwsA(isA<PegarouteUnavailableException>()));
    expect(calls, ['GET /quote']);
    expect(wallet.builds, 0);
  });

  test('token source comparison includes supported single-call DEX candidates', () async {
    final deposit = quote['routes'][0] as Map<String, dynamic>;
    quote['routes'] = [
      {...deposit, 'provider': 'openocean', 'expectedOutput': '200'},
      deposit
    ];
    expect(
        await provider.fetchRate(
          from: _usdc,
          to: CryptoCurrency.xmr,
          amount: 100,
          isFixedRateMode: false,
          isReceiveAmount: false,
        ),
        200 / 100);
    expect(calls, ['GET /quote']);
  });

  for (final withApprovalMetadata in [false, true]) {
    test(
        'USDC contract swap uses zero native value and ${withApprovalMetadata ? 'existing allowance' : 'no approval'}',
        () async {
      wallet.sourceCurrency = _usdc;
      contractRoute('openocean');
      receiveCurrency = CryptoCurrency.eth;
      swap['execution']['value'] = {'display': '0', 'baseUnits': '0'};
      if (withApprovalMetadata) {
        swap['execution']['approval'] = {
          'tokenAddress': _usdc.contractAddress,
          'spender': _deposit,
          'amount': {'display': '1', 'baseUnits': '1000000'},
        };
        (evm as _Evm).allowance = BigInt.from(1000000);
      }
      final trade = await create();
      final pending = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
      final evidence = inspectPegarouteEvm(pending.hex, context.snapshot(wallet));
      expect(evidence.valueBaseUnits, '0');
      expect(evidence.to, _deposit);
      expect(evidence.data, _calldata);
      expect(pending.amount.amount, BigInt.from(1000000));
      await pending.commit();
      expect(wallet.builds, 1);
      expect(wallet.broadcasts, 1);
    });
  }
  test('approval gas shortage survives guarded preparation without signing or swap funding',
      () async {
    approvalRoute();
    final trade = await create();
    final error = TransactionWrongBalanceException(CryptoCurrency.eth,
        requiredBalance: Money.parse('0.000455', CryptoCurrency.eth),
        availableBalance: Money.parse('0.0001', CryptoCurrency.eth),
        fee: Money.parse('0.000455', CryptoCurrency.eth));
    (evm as _Evm).approvalBalanceError = error;
    await expectLater(dispatcher.prepare(wallet: wallet, trade: trade), throwsA(same(error)));
    expect(wallet.builds, 0);
    expect(wallet.broadcasts, 0);
    expect(sourceHash, isNull);
    expect(
        await PegarouteApprovalFlow.store.read(const PegarouteExecutionBindingValidator()
            .validatePersisted(trade: trade, wallet: wallet)),
        isEmpty);
  });

  test('approval-required order is saved before preparing a separately confirmed approval',
      () async {
    wallet.sourceCurrency = _usdc;
    contractRoute('openocean');
    receiveCurrency = CryptoCurrency.eth;
    swap['execution']['value'] = {'display': '0', 'baseUnits': '0'};
    swap['execution']['approval'] = {
      'tokenAddress': _usdc.contractAddress,
      'spender': _deposit,
      'amount': {'display': '1', 'baseUnits': '1000000'},
    };
    final trade = await create();
    expect(calls, ['GET /quote', 'POST /swap']);
    expect(wallet.builds, 0);
    final approval = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    expect(tradeExecutionPrerequisiteDescription(approval), contains('Approve'));
    expect(wallet.broadcasts, 0);
    await approval.commit();
    final row = (await Trade.getByTradeId(trade.id))!;
    expect(row.txId, isNull);
    expect(row.executionLifecycleJson, isNull);
    expect(calls, ['GET /quote', 'POST /swap']);
    final swapPending = (await dispatcher.prepare(wallet: wallet, trade: row))!;
    expect(tradeExecutionPrerequisiteDescription(swapPending), isNull);
    expect(swapPending.id, isNot(approval.id));
    await swapPending.commit();
    expect((await Trade.getByTradeId(trade.id))!.txId, swapPending.id);
    expect(wallet.broadcasts, 2);
    expect(
        calls.where((call) => call.startsWith('POST') && call.endsWith('/txhash')), hasLength(1));
  });

  test('USDT reset, approval and final swap each confirm separately across SQLite restoration',
      () async {
    approvalRoute(token: _usdt);
    final api = evm as _Evm;
    api.allowance = BigInt.from(10);
    final trade = await create();
    final reset = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    expect(tradeExecutionPrerequisiteDescription(reset), contains('Reset USDT'));
    await reset.commit();
    expect(api.allowance, BigInt.zero);
    final afterReset = (await Trade.getByTradeId(trade.id))!;
    expect(afterReset.txId, isNull);
    final approval = (await dispatcher.prepare(wallet: wallet, trade: afterReset))!;
    expect(tradeExecutionPrerequisiteDescription(approval), contains('Approve'));
    expect(wallet.broadcasts, 1);
    await approval.commit();
    final afterApproval = (await Trade.getByTradeId(trade.id))!;
    expect(afterApproval.txId, isNull);
    final payment = (await dispatcher.prepare(wallet: wallet, trade: afterApproval))!;
    expect(tradeExecutionPrerequisiteDescription(payment), isNull);
    await payment.commit();
    expect(api.approvalAmounts, [BigInt.zero, BigInt.from(1000000)]);
    expect(wallet.signedNonces, [7, 8, 9]);
    expect(wallet.broadcasts, 3);
    final progress = await database.query('PegarouteApproval');
    expect(progress.map((row) => row['state']), everyElement('confirmed'));
    expect(progress.map((row) => row['transactionHash']), containsAll([reset.id, approval.id]));
    expect((await Trade.getByTradeId(trade.id))!.txId, payment.id);
  });

  test('USDT with zero allowance skips the reset', () async {
    approvalRoute(token: _usdt);
    final trade = await create();
    final approval = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    expect(tradeExecutionPrerequisiteDescription(approval), startsWith('Approve'));
    expect((evm as _Evm).approvalAmounts, [BigInt.from(1000000)]);
    expect(wallet.broadcasts, 0);
  });

  test('pending approval survives timeout and cannot be duplicated, even with sufficient allowance',
      () async {
    approvalRoute();
    final api = evm as _Evm;
    api.receipt = null;
    final trade = await create();
    final first = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    final duplicate = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    await expectLater(first.commit(), throwsA(isA<TradeExecutionPrerequisiteException>()));
    await expectLater(duplicate.commit(), throwsA(isA<TradeExecutionPrerequisiteException>()));
    final restored = (await Trade.getByTradeId(trade.id))!;
    await expectLater(dispatcher.prepare(wallet: wallet, trade: restored),
        throwsA(isA<TradeExecutionPrerequisiteException>()));
    expect(wallet.broadcasts, 1);
    expect(restored.txId, isNull);
    expect(restored.executionLifecycleJson, isNull);
    api.receipt = true;
    final payment = (await dispatcher.prepare(wallet: wallet, trade: restored))!;
    expect(tradeExecutionPrerequisiteDescription(payment), isNull);
    expect(wallet.broadcasts, 1);
    await payment.commit();
    expect(wallet.broadcasts, 2);
    expect(api.approvalAmounts, hasLength(2)); // Two prepared, only one broadcast.
  });

  test('lost approval broadcast response is reconciled from its saved hash', () async {
    approvalRoute();
    final trade = await create();
    final approval = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    wallet.duringBroadcast = () async {
      (evm as _Evm).allowance = BigInt.from(1000000);
      throw const SocketException('Lost broadcast response');
    };
    await expectLater(approval.commit(), throwsA(isA<TradeExecutionPrerequisiteException>()));
    expect((await database.query('PegarouteApproval')).single['transactionHash'], approval.id);
    wallet.duringBroadcast = null;
    final payment =
        (await dispatcher.prepare(wallet: wallet, trade: (await Trade.getByTradeId(trade.id))!))!;
    expect(tradeExecutionPrerequisiteDescription(payment), isNull);
    expect(wallet.broadcasts, 1);
    await payment.commit();
    expect(wallet.broadcasts, 2);
  });

  test('failed approval receipt never funds the swap or automatically repeats approval', () async {
    approvalRoute();
    (evm as _Evm).receipt = false;
    final trade = await create();
    final approval = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    await expectLater(approval.commit(), throwsA(isA<TradeExecutionPrerequisiteException>()));
    final restored = (await Trade.getByTradeId(trade.id))!;
    await expectLater(dispatcher.prepare(wallet: wallet, trade: restored),
        throwsA(isA<TradeExecutionPrerequisiteException>()));
    expect(restored.txId, isNull);
    expect(wallet.broadcasts, 1);
    expect((await database.query('PegarouteApproval')).single['state'], 'failed');
    expect(calls, ['GET /quote', 'POST /swap']);
  });

  test('approval persistence failure prevents broadcast', () async {
    approvalRoute();
    final trade = await create();
    final approval = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    await database.execute("CREATE TRIGGER reject_approval BEFORE INSERT ON PegarouteApproval "
        "BEGIN SELECT RAISE(ABORT, 'fixture unavailable'); END");
    await expectLater(approval.commit(), throwsA(anything));
    expect(wallet.broadcasts, 0);
  });

  for (final mutation in ['to', 'data', 'amount', 'signer', 'chain']) {
    test('signed approval $mutation mismatch rejects before broadcasting', () async {
      approvalRoute();
      final trade = await create();
      wallet.mutation = mutation;
      expect(await dispatcher.prepare(wallet: wallet, trade: trade), isNull);
      expect(wallet.broadcasts, 0);
      expect(await database.query('PegarouteApproval'), isEmpty);
    });
  }

  test('wallet switch while waiting for approval stops progression to swap', () async {
    approvalRoute();
    final trade = await create();
    final approval = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    (evm as _Evm).duringReceipt = () => runInAction(() => active.value = _Wallet());
    await expectLater(approval.commit(), throwsA(isA<PegarouteBindingException>()));
    expect(wallet.builds, 1);
    expect(wallet.broadcasts, 1);
    expect((await Trade.getByTradeId(trade.id))!.txId, isNull);
  });

  test('an older prepared swap cannot race a pending approval', () async {
    approvalRoute();
    final api = evm as _Evm;
    api.allowance = BigInt.from(1000000);
    final trade = await create();
    final payment = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    api.allowance = BigInt.zero;
    final approval = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    api.receipt = null;
    await expectLater(approval.commit(), throwsA(isA<TradeExecutionPrerequisiteException>()));
    await expectLater(payment.commit(), throwsA(isA<TradeExecutionPrerequisiteException>()));
    expect(wallet.broadcasts, 1);
    expect((await Trade.getByTradeId(trade.id))!.txId, isNull);
  });

  for (final mutation in ['amount', 'address', 'memo', 'approval', 'call']) {
    test('unsupported order $mutation cannot reach wallet construction', () async {
      final execution = swap['execution'] as Map;
      switch (mutation) {
        case 'amount':
          execution['value'] = {'display': '1', 'baseUnits': '2'};
        case 'address':
          execution['to'] = _key.address.hex;
        case 'memo':
          execution['memo'] = 'unexpected';
        case 'approval':
          execution['approval'] = {
            'spender': _deposit,
            'tokenAddress': _deposit,
            'amount': {'display': '1', 'baseUnits': '1000000000000000000'}
          };
        case 'call':
          execution['mode'] = 'contract-call';
          execution['data'] = '0x12345678';
      }
      await expectLater(create(), throwsA(isA<PegarouteSwapAttemptException>()));
      expect(wallet.builds, 0);
      expect(wallet.broadcasts, 0);
    });
  }

  test('hardware, unsupported source, fixed, extra-id and send-all reject before quote', () async {
    wallet.hardware = true;
    await expectLater(create(), throwsA(isA<PegarouteUnavailableException>()));
    wallet.hardware = false;
    for (final req in [request(from: CryptoCurrency.btc), request(extra: 'memo')]) {
      await expectLater(
          provider.createTrade(request: req, isFixedRateMode: false, isSendAll: false),
          throwsA(isA<PegarouteUnavailableException>()));
    }
    for (final fixed in [true, false]) {
      await expectLater(
          provider.createTrade(request: request(), isFixedRateMode: fixed, isSendAll: !fixed),
          throwsA(isA<PegarouteUnavailableException>()));
    }
    expect(calls, isEmpty);
  });
}

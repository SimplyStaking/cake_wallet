// Offline fixtures exercise the actual EVM pending byte/hash implementation.
// ignore_for_file: cw_custom_lints/no_restricted_imports_in_lib

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_eth_execution_handler.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_lifecycle_store.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_native_eth.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_provider_preferences.dart';
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
import 'package:cw_core/db/sqlite.dart' as sqlite;
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
import 'package:mobx/mobx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:web3dart/web3dart.dart' as web3;

// Public synthetic test key; never used with a node or real wallet.
final _key = web3.EthPrivateKey.fromInt(BigInt.one);
const _deposit = '0x0000000000000000000000000000000000000001';
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
  String? mutation;
  bool hardware = false;
  Future<void> Function()? duringBuild;
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
    builds++;
    final value = credentials as EVMChainTransactionCredentials;
    final output = value.outputs.single;
    expect(value.currency, CryptoCurrency.eth);
    expect(output.sendAll, false);
    expect(output.memo, isNull);
    expect(output.address, _deposit);
    final transaction = web3.Transaction(
      to: web3.EthereumAddress.fromHex(mutation == 'to' ? _key.address.hex : output.address),
      value: web3.EtherAmount.inWei(
          output.cryptoAmount.amount + (mutation == 'amount' ? BigInt.one : BigInt.zero)),
      data: Uint8List.fromList(mutation == 'data' ? [1] : []),
      nonce: 7,
      maxGas: 21000,
      maxPriorityFeePerGas: web3.EtherAmount.inWei(BigInt.one),
      maxFeePerGas: web3.EtherAmount.inWei(BigInt.from(2)),
    );
    final signed = await web3.signTransactionRaw(
        transaction, mutation == 'signer' ? web3.EthPrivateKey.fromInt(BigInt.two) : _key,
        chainId: mutation == 'chain' ? 56 : 1);
    await duringBuild?.call();
    pending = PendingEVMChainTransaction(
      signedTransaction: web3.prependTransactionType(2, signed),
      amount: output.cryptoAmount,
      fee: Money(BigInt.from(42000), CryptoCurrency.eth),
      sendTransaction: () async {
        broadcasts++;
      },
    );
    return pending;
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
  String? sourceHash;
  String? ackHash;
  String? ackId;
  bool failCreation = false;
  bool failCallback = false;
  bool storeHash = true;
  bool completed = false;
  void Function()? afterQuote;
  void Function()? afterPost;

  TradeRequest request(
          {CryptoCurrency from = CryptoCurrency.eth, String? sender, String extra = ''}) =>
      TradeRequest(
          fromCurrency: from,
          toCurrency: CryptoCurrency.xmr,
          fromAmount: '1',
          toAddress: _payout,
          senderAddress: sender ?? _key.address.hex,
          refundAddress: _key.address.hex,
          toAddressExtraId: extra);

  Future<Trade> create() async {
    final trade =
        await provider.createTrade(request: request(), isFixedRateMode: false, isSendAll: false);
    await trade.save();
    return trade;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = PegarouteProviderPreferences(await SharedPreferences.getInstance());
    decentralizedOnly = false;
    database = await _database();
    wallet = _Wallet();
    active = Observable<WalletBase?>(wallet);
    context = PegarouteActiveWalletContext(() => active.value);
    quote = _fixture('quote')..['expiresAt'] = '2099-01-01T00:00:00.000Z';
    swap = _fixture('swap');
    (swap['execution'] as Map)['value'] = {'display': '1', 'baseUnits': '1000000000000000000'};
    ((swap['provider'] as Map)['details']['instaswapSwapLite'] as Map)['expiresAt'] = null;
    calls = [];
    sourceHash = ackHash = ackId = null;
    failCreation = failCallback = completed = false;
    afterQuote = afterPost = null;
    storeHash = true;
    final api = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://fixture.invalid'),
      get: (uri, headers) async {
        expect(headers, isEmpty);
        calls.add('GET ${uri.path}');
        if (uri.path == '/quote') {
          if (uri.queryParameters.containsKey('destinationAddress')) {
            expect(uri.queryParameters['destinationAddress'], _payout);
            expect(uri.queryParameters['senderAddress'], _key.address.hex);
          }
          afterQuote?.call();
          return very_insecure_http_do_not_use.Response(jsonEncode(quote), 200);
        }
        expect(uri.path, '/swap/transaction-fixture');
        return very_insecure_http_do_not_use.Response(
            jsonEncode({
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
                'chain': 'ETH',
                'token': 'ETH',
                'amount': '1',
                'address': _key.address.hex,
                'refundAddress': _key.address.hex,
                if (sourceHash != null) 'txHash': sourceHash
              },
              'output': {
                'chain': 'XMR',
                'token': 'XMR',
                'address': _payout,
                if (completed) 'amount': '0.99',
                if (completed) 'txHash': 'xmr-output-fixture'
              },
              'fees': (swap['route'] as Map)['fees'],
              'timestamps': {'created': '2026-01-01T00:00:00.000Z'},
              'error': null,
              'refund': null,
              'streamingProgress': null,
            }),
            200);
      },
      post: (uri, headers, body) async {
        calls.add('POST ${uri.path}');
        expect(headers, {'Content-Type': 'application/json'});
        final value = jsonDecode(body);
        if (uri.path == '/swap') {
          expect(value['quoteId'], 'quote-fixture');
          expect(value['routeProvider'], 'instaswap');
          expect(value['senderAddress'], _key.address.hex);
          expect(value['destinationAddress'], _payout);
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
    );
    dispatcher = RegistryTradeExecutionDispatcher([
      PegarouteEthExecutionHandler(
        nativeDepositsOnly: true,
        walletContext: context,
        adapter:
            PegarouteNativeEthWalletAdapter(priority: (_) => EVMChainTransactionPriority.medium),
        lifecycleHandler: PegarouteExecutionLifecycleStore(),
        onDepositCommitted: provider.notifyCommitted,
      ),
    ]);
  });

  tearDown(() async {
    context.dispose();
    await database.close();
    sqlite.db = null;
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

  test('exchange comparison uses the executable deposit quote instead of a better DEX quote',
      () async {
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
        closeTo(11.66 / 0.005, 0.000001));
    expect(
        (await provider.fetchLimits(
          from: CryptoCurrency.eth,
          to: CryptoCurrency.usdc,
          isFixedRateMode: false,
        ))!
            .min,
        0.004);
    await preferences.setEnabled('instaswap', false);
    expect(provider.isExecutionAvailable, false);
    expect(
        await provider.fetchRate(
          from: CryptoCurrency.eth,
          to: CryptoCurrency.usdc,
          amount: 0.005,
          isFixedRateMode: false,
          isReceiveAmount: false,
        ),
        0);
    expect(calls, ['GET /quote', 'GET /quote']);
    expect(wallet.builds, 0);
  });

  test('disabled or decentralized-only Instaswap cannot create an order', () async {
    await preferences.setEnabled('instaswap', false);
    await expectLater(create(), throwsA(isA<PegarouteUnavailableException>()));
    await preferences.setEnabled('instaswap', true);
    decentralizedOnly = true;
    await expectLater(create(), throwsA(isA<PegarouteUnavailableException>()));
    expect(calls, isEmpty);
    decentralizedOnly = false;
    afterQuote = () => preferences.setEnabled('instaswap', false);
    await expectLater(create(), throwsA(isA<PegarouteUnavailableException>()));
    expect(calls, ['GET /quote']);
    expect(wallet.builds, 0);
  });

  test('a quote-only token source does not enter executable exchange comparison', () async {
    expect(
        await provider.fetchRate(
          from: CryptoCurrency.usdc,
          to: CryptoCurrency.xmr,
          amount: 100,
          isFixedRateMode: false,
          isReceiveAmount: false,
        ),
        0);
    expect(calls, isEmpty);
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

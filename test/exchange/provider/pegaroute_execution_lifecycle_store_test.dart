import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_lifecycle_store.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_execution_lifecycle.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/db/sqlite.dart' as sqlite;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openDatabase() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await database.execute('''
CREATE TABLE Trade (
  tradeId INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL,
  providerRaw INTEGER NOT NULL DEFAULT 0,
  fromTitle TEXT, fromName TEXT, fromTag TEXT, fromFullName TEXT,
  fromDecimals INTEGER, fromRaw INTEGER, fromIconPath TEXT,
  fromFlatIconPath TEXT, fromChainIconPath TEXT,
  toTitle TEXT, toName TEXT, toTag TEXT, toFullName TEXT,
  toDecimals INTEGER, toRaw INTEGER, toIconPath TEXT,
  toFlatIconPath TEXT, toChainIconPath TEXT,
  stateRaw TEXT NOT NULL DEFAULT '', createdAt INTEGER, expiredAt INTEGER,
  amount TEXT NOT NULL DEFAULT '', receiveAmount TEXT, inputAddress TEXT,
  extraId TEXT, outputTransaction TEXT, refundAddress TEXT, senderAddress TEXT,
  walletId TEXT, payoutAddress TEXT, toAddressExtraId TEXT, password TEXT,
  providerId TEXT, providerName TEXT, fromWalletAddress TEXT, memo TEXT,
  txId TEXT, isRefund INTEGER DEFAULT 0, isSendAll INTEGER DEFAULT 0,
  router TEXT, needToRegisterInSwapXyz INTEGER DEFAULT 0,
  sourceTokenAddress TEXT, sourceTokenDecimals INTEGER, routerData TEXT,
  routerValue TEXT, routerChainId INTEGER, sourceTokenAmountRaw TEXT,
  requiresTokenApproval INTEGER DEFAULT 0, chainId INTEGER, fee REAL,
  executionJson TEXT, refundJson TEXT, executionLifecycleJson TEXT
)
''');
  await database.execute('CREATE UNIQUE INDEX idx_trade_id_unique ON Trade (id)');
  sqlite.db = database;
  return database;
}

Trade _trade() {
  const sender = '0x0000000000000000000000000000000000000002';
  const target = '0x0000000000000000000000000000000000000001';
  final execution = TradeExecution(
    family: 'evm',
    mode: 'native-transfer',
    sourceChain: 'ETH',
    sourceToken: 'ETH',
    nativeToken: 'ETH',
    destinationChain: 'BTC',
    destinationToken: 'BTC',
    routeProvider: 'instaswap',
    binding: TradeExecutionBinding(
      tradeId: 'lifecycle-fixture',
      providerRaw: 17,
      quoteId: 'quote-fixture',
      quoteExpiresAt: DateTime.utc(2099),
      routeExpiry: null,
      sourceAmount: '1',
      sourceAmountBaseUnits: '1000000000000000000',
      sourceDecimals: 18,
      destinationDecimals: 8,
      senderAddress: sender,
      refundAddress: null,
      destinationAddress: 'bc1qfixture',
      isSendAll: false,
      walletId: 'wallet-fixture',
      walletChainId: 1,
      walletAddress: sender,
      reviewedRouteJson:
          '{"provider":"instaswap","providerType":"fixture","subprovider":null,"private":false,"expectedOutput":"0.99","fees":null,"estimatedTimeSeconds":0,"memo":null,"inboundAddress":"$target","router":null,"minAmount":null,"expiry":null,"gasRate":null,"resolvedFee":null,"openOceanRoute":null}',
      providerReferenceId: null,
    ),
    payload: const {
      'chainId': 1,
      'to': target,
      'data': null,
      'value': {'display': '1', 'baseUnits': '1000000000000000000'},
      'gasLimit': null,
      'memo': null,
      'approval': null,
      'transferAmount': null,
    },
  );
  return Trade(
    id: 'lifecycle-fixture',
    amount: '1',
    from: CryptoCurrency.eth,
    to: CryptoCurrency.btc,
    provider: ExchangeProviderDescription.pegaroute,
    senderAddress: sender,
    payoutAddress: 'bc1qfixture',
    walletId: 'wallet-fixture',
    fromWalletAddress: sender,
    chainId: 1,
    providerName: 'instaswap',
    executionJson: execution.encode(),
  );
}

void main() {
  late Database database;
  late Trade trade;
  late ValidatedTradeExecution execution;
  final store = PegarouteExecutionLifecycleStore(clock: () => DateTime.utc(2026, 9, 3));

  setUp(() async {
    database = await _openDatabase();
    trade = _trade();
    await trade.save();
    execution = const PegarouteExecutionBindingValidator().validatePersisted(trade: trade);
  });

  tearDown(() async {
    await database.close();
    sqlite.db = null;
  });

  test('persists one-shot broadcast transitions against the exact row', () async {
    await store.beforeBroadcast(
      execution: execution,
      executionHash: '0xhash',
      tradeInternalId: trade.internalId,
    );
    var persisted = await Trade.getByTradeId(trade.id);
    expect(
      TradeExecutionLifecycle.fromJsonString(persisted!.executionLifecycleJson!).state,
      TradeExecutionLifecycleState.broadcasting,
    );
    await expectLater(
      store.beforeBroadcast(
        execution: execution,
        executionHash: '0xhash',
        tradeInternalId: trade.internalId,
      ),
      throwsA(isA<StateError>()),
    );

    await store.onBroadcasted(
      execution: execution,
      executionHash: '0xhash',
      tradeInternalId: trade.internalId,
    );
    persisted = await Trade.getByTradeId(trade.id);
    var lifecycle = TradeExecutionLifecycle.fromJsonString(persisted!.executionLifecycleJson!);
    expect(lifecycle.state, TradeExecutionLifecycleState.broadcasted);
    await store.markCallbackAttempted(
      execution: execution,
      executionHash: '0xhash',
      tradeInternalId: trade.internalId,
    );
    await store.markCallbackAccepted(
      execution: execution,
      executionHash: '0xhash',
      tradeInternalId: trade.internalId,
    );
    persisted = await Trade.getByTradeId(trade.id);
    lifecycle = TradeExecutionLifecycle.fromJsonString(persisted!.executionLifecycleJson!);
    expect(lifecycle.callbackState, TradeExecutionCallbackState.accepted);
  });

  test('rejects a deleted and recreated trade with the same public id', () async {
    final staleInternalId = trade.internalId;
    await database
        .delete(Trade.tableName, where: '${Trade.selfIdColumn} = ?', whereArgs: [staleInternalId]);
    final replacement = _trade();
    await replacement.save();

    await expectLater(
      store.beforeBroadcast(
        execution: execution,
        executionHash: '0xhash',
        tradeInternalId: staleInternalId,
      ),
      throwsA(isA<PegarouteBindingException>()),
    );
    expect((await Trade.getByTradeId(replacement.id))!.executionLifecycleJson, isNull);
  });

  test('durably records an ambiguous broadcast outcome', () async {
    await store.beforeBroadcast(
      execution: execution,
      executionHash: '0xhash',
      tradeInternalId: trade.internalId,
    );
    await store.onBroadcastUnknown(
      execution: execution,
      executionHash: '0xhash',
      tradeInternalId: trade.internalId,
    );

    final persisted = await Trade.getByTradeId(trade.id);
    final lifecycle = TradeExecutionLifecycle.fromJsonString(persisted!.executionLifecycleJson!);
    expect(lifecycle.state, TradeExecutionLifecycleState.broadcastUnknown);
    expect(lifecycle.broadcastUnknownAt, isNotNull);
  });

  test('durably distinguishes a pre-send abort from an ambiguous broadcast', () async {
    await store.beforeBroadcast(
      execution: execution,
      executionHash: '0xhash',
      tradeInternalId: trade.internalId,
    );
    await store.onBroadcastAborted(
      execution: execution,
      executionHash: '0xhash',
      tradeInternalId: trade.internalId,
    );

    final persisted = await Trade.getByTradeId(trade.id);
    final lifecycle = TradeExecutionLifecycle.fromJsonString(persisted!.executionLifecycleJson!);
    expect(lifecycle.state, TradeExecutionLifecycleState.broadcastAborted);
    expect(lifecycle.broadcastAbortedAt, isNotNull);
    expect(lifecycle.broadcastUnknownAt, isNull);
  });

  test('rejects changed execution bytes and an unsaved row identity', () async {
    await database.update(
      Trade.tableName,
      {'executionJson': '${trade.executionJson} '},
      where: '${Trade.selfIdColumn} = ?',
      whereArgs: [trade.internalId],
    );
    await expectLater(
      store.beforeBroadcast(
        execution: execution,
        executionHash: '0xhash',
        tradeInternalId: trade.internalId,
      ),
      throwsA(isA<PegarouteBindingException>()),
    );
    await expectLater(
      store.beforeBroadcast(execution: execution, executionHash: '0xhash', tradeInternalId: 0),
      throwsA(isA<PegarouteBindingException>()),
    );
  });
}

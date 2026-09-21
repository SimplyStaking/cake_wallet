import 'dart:async';

import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_lifecycle_store.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_execution_lifecycle.dart';
import 'package:cake_wallet/exchange/trade_refund.dart';
import 'package:cake_wallet/exchange/trade_state.dart';
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
  executionJson TEXT, refundJson TEXT, executionLifecycleJson TEXT,
  fromAssetIdentityJson TEXT, toAssetIdentityJson TEXT
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
    state: TradeState.created,
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

  test('only an explicitly created row without funding/refund evidence can begin', () async {
    final mutations = <Map<String, Object?>>[
      for (final state in [
        '',
        'pending',
        'confirming',
        'exchanging',
        'sending',
        'success',
        'completed',
        'failed',
        'expired',
        'refund',
        'refunded',
        'unknown'
      ])
        {'stateRaw': state},
      {'isRefund': 1},
      {'isRefund': 2},
      {'txId': 'funded'},
      {'outputTransaction': 'paid-out'},
      {'refundJson': TradeRefund(terminalWithoutEvidence: true).encode()},
      {'refundJson': '{}'},
      {'refundJson': ''},
      {
        'refundJson': TradeRefund(
          status: 'pending',
          chain: 'ETH',
          amount: '1',
          originalAmount: '1',
          feeDeducted: '0',
          feeDescription: 'none',
          observedAddress: 'refund',
        ).encode()
      },
    ];
    for (final mutation in mutations) {
      await database.update(Trade.tableName, {
        'stateRaw': 'created',
        'isRefund': 0,
        'txId': null,
        'outputTransaction': null,
        'refundJson': null,
        ...mutation,
      });
      await expectLater(
        store.beforeBroadcast(
          execution: execution,
          executionHash: 'hash',
          tradeInternalId: trade.internalId,
        ),
        throwsA(isA<PegarouteBindingException>()),
        reason: '$mutation',
      );
      expect((await Trade.getByTradeId(trade.id))!.executionLifecycleJson, isNull);
    }
    await database.update(Trade.tableName, {
      'refundJson': TradeRefund(configuredAddress: 'refund').encode(),
    });
    await store.beforeBroadcast(
      execution: execution,
      executionHash: 'hash',
      tradeInternalId: trade.internalId,
    );
  });

  test('status committed while broadcast is queued wins over the stale caller', () async {
    final statusWriting = Completer<void>();
    final releaseStatus = Completer<void>();
    final statusUpdate = database.transaction((txn) async {
      await txn.update(Trade.tableName, {'stateRaw': 'confirming'});
      statusWriting.complete();
      await releaseStatus.future;
    });
    await statusWriting.future;
    final broadcast = store.beforeBroadcast(
      execution: execution,
      executionHash: 'hash',
      tradeInternalId: trade.internalId,
    );
    final rejected = expectLater(broadcast, throwsA(isA<PegarouteBindingException>()));
    releaseStatus.complete();
    await statusUpdate;
    await rejected;
    expect(trade.state, TradeState.created);
    final latest = (await Trade.getByTradeId(trade.id))!;
    expect(latest.state, TradeState.confirming);
    expect(latest.executionLifecycleJson, isNull);
  });

  test('post-broadcast facts can advance after provider status changes', () async {
    await store.beforeBroadcast(
      execution: execution,
      executionHash: 'hash',
      tradeInternalId: trade.internalId,
    );
    await database.update(Trade.tableName, {'stateRaw': 'confirming'});
    await store.onBroadcasted(
      execution: execution,
      executionHash: 'hash',
      tradeInternalId: trade.internalId,
    );
    final latest = (await Trade.getByTradeId(trade.id))!;
    expect(latest.state, TradeState.confirming);
    expect(TradeExecutionLifecycle.fromJsonString(latest.executionLifecycleJson!).state,
        TradeExecutionLifecycleState.broadcasted);
  });

  test('notifies after commit and does not notify for a rejected transition', () async {
    final observations = <Future<Trade?>>[];
    final subscription = Trade.onChanged.stream.listen((_) {
      observations.add(Trade.getByTradeId(trade.id));
    });
    addTearDown(subscription.cancel);
    await store.beforeBroadcast(
      execution: execution,
      executionHash: 'hash',
      tradeInternalId: trade.internalId,
    );
    await expectLater(
      store.beforeBroadcast(
        execution: execution,
        executionHash: 'hash',
        tradeInternalId: trade.internalId,
      ),
      throwsStateError,
    );
    expect(observations, hasLength(1));
    final observed = (await observations.single)!;
    expect(TradeExecutionLifecycle.fromJsonString(observed.executionLifecycleJson!).state,
        TradeExecutionLifecycleState.broadcasting);
  });
}

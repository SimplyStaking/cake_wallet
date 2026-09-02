import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_state.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_refund.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/db/sqlite.dart' as sqlite;
import 'package:cw_core/erc20_token.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openTradeDatabase() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final database = await openDatabase(
    inMemoryDatabasePath,
    version: 1,
    onCreate: (database, _) async {
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
  executionJson TEXT, refundJson TEXT
)
''');
      await database.execute('CREATE UNIQUE INDEX idx_trade_id_unique ON Trade (id)');
    },
  );
  sqlite.db = database;
  return database;
}

Trade _status({
  required String id,
  required String state,
  String amount = '1',
  String? executionJson,
  CryptoCurrency? from,
  CryptoCurrency? to,
  DateTime? expiredAt,
  bool? isRefund,
  String? inputAddress,
  String? providerName,
  String? memo,
  String? receiveAmount,
  String? outputTransaction,
}) {
  return Trade(
    id: id,
    amount: amount,
    from: from,
    to: to,
    provider: ExchangeProviderDescription.pegaroute,
    state: TradeState.deserialize(raw: state),
    executionJson: executionJson,
    expiredAt: expiredAt,
    isRefund: isRefund,
    inputAddress: inputAddress,
    providerName: providerName,
    memo: memo,
    receiveAmount: receiveAmount,
    outputTransaction: outputTransaction,
  );
}

TradeExecutionBinding _binding() => TradeExecutionBinding(
      tradeId: 'trade-fixture',
      providerRaw: 17,
      quoteId: 'quote-fixture',
      quoteExpiresAt: DateTime.utc(2099),
      routeExpiry: null,
      sourceAmount: '1',
      sourceAmountBaseUnits: '1000000000000',
      sourceDecimals: 12,
      senderAddress: 'sender',
      refundAddress: null,
      destinationAddress: 'destination',
      isSendAll: false,
      walletId: 'wallet-fixture',
      walletChainId: null,
      walletAddress: 'sender',
      reviewedRouteJson:
          '{"provider":"instaswap","providerType":"fixture","subprovider":"fixture","private":false,"expectedOutput":"0.99","fees":null,"estimatedTimeSeconds":0,"memo":null,"inboundAddress":"destination","router":null,"minAmount":null,"expiry":null,"gasRate":null,"resolvedFee":null,"openOceanRoute":null}',
      providerReferenceId: null,
    );

void main() {
  test('persists sender, execution, and refund envelopes in the trade row', () {
    final execution = TradeExecution(
      family: 'other',
      mode: 'deposit-transfer',
      sourceChain: 'XMR',
      sourceToken: 'XMR',
      nativeToken: 'XMR',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      binding: _binding(),
      routeProvider: 'instaswap',
      subprovider: 'fixture',
      privateIntent: false,
      payload: const {
        'chain': 'XMR',
        'to': 'destination',
        'amount': {'display': '1', 'baseUnits': '1000000000000'},
        'memo': null,
      },
    );
    final refund = TradeRefund(configuredAddress: 'configured');
    final trade = Trade(
      id: 'trade-fixture',
      amount: '1',
      from: CryptoCurrency.xmr,
      to: CryptoCurrency.btc,
      provider: ExchangeProviderDescription.pegaroute,
      senderAddress: 'sender',
      payoutAddress: 'destination',
      walletId: 'wallet-fixture',
      fromWalletAddress: 'sender',
      providerName: 'instaswap',
      executionJson: execution.encode(),
      refundJson: refund.encode(),
    );

    final reloaded = Trade.fromSqliteRow(trade.toSqliteMap()..['tradeId'] = 1);
    expect(reloaded.provider, ExchangeProviderDescription.pegaroute);
    expect(reloaded.senderAddress, 'sender');
    expect(TradeExecution.fromJsonString(reloaded.executionJson!).family, 'other');
    expect(TradeRefund.fromJsonString(reloaded.refundJson!).configuredAddress, 'configured');
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(trade: reloaded),
      returnsNormally,
    );
  });

  test('keeps unreadable persisted envelopes as raw values', () {
    final trade = Trade.fromSqliteRow({
      'tradeId': 1,
      'id': 'legacy-trade',
      'providerRaw': 17,
      'amount': '1',
      'stateRaw': 'created',
      'executionJson': '{"version":99}',
      'refundJson': '{"version":99}',
    });
    expect(trade.provider, ExchangeProviderDescription.pegaroute);
    expect(trade.executionJson, '{"version":99}');
    expect(trade.refundJson, '{"version":99}');
    expect(trade.toSqliteMap()['executionJson'], '{"version":99}');
  });

  test('does not replace a persisted execution payload during status merge', () {
    final trade = Trade(id: 'trade', amount: '1', executionJson: 'original');
    trade.mergeFindTradeByIdResult(Trade(id: 'trade', amount: '1', executionJson: 'replacement'));
    expect(trade.executionJson, 'original');
  });

  test('does not regress terminal Pegaroute status during status merge', () {
    final trade = Trade(
      id: 'trade',
      amount: '1',
      provider: ExchangeProviderDescription.pegaroute,
      state: TradeState.success,
    );
    trade.mergeFindTradeByIdResult(
      Trade(
        id: 'trade',
        amount: '1',
        state: TradeState.created,
      ),
    );
    expect(trade.state, TradeState.success);
  });

  test('does not populate a missing creation execution during status merge', () {
    final trade = Trade(id: 'trade', amount: '1');
    trade.mergeFindTradeByIdResult(Trade(id: 'trade', amount: '1', executionJson: 'observed'));
    expect(trade.executionJson, isNull);
  });

  test('fills a missing sender once but never replaces persisted sender intent', () {
    final missing = Trade(id: 'missing', amount: '1');
    missing.mergeFindTradeByIdResult(Trade(id: 'missing', amount: '1', senderAddress: 'observed'));
    expect(missing.senderAddress, 'observed');

    final persisted = Trade(id: 'persisted', amount: '1', senderAddress: 'configured');
    persisted.mergeFindTradeByIdResult(
      Trade(id: 'persisted', amount: '1', senderAddress: 'different'),
    );
    expect(persisted.senderAddress, 'configured');
  });

  test('preserves configured refund intent across status merges', () {
    final trade = Trade(
      id: 'persisted',
      amount: '1',
      refundAddress: 'configured',
      refundJson: TradeRefund(configuredAddress: 'configured').encode(),
    );
    trade.mergeFindTradeByIdResult(
      Trade(
        id: 'persisted',
        amount: '1',
        refundAddress: 'different',
        refundJson: TradeRefund(configuredAddress: 'different').encode(),
      ),
    );
    expect(trade.refundAddress, 'configured');
    expect(TradeRefund.fromJsonString(trade.refundJson!).configuredAddress, 'configured');
  });

  test('seeds missing refund envelope from persisted configured intent', () {
    final trade = Trade(
      id: 'persisted',
      amount: '1',
      refundAddress: 'configured',
    );
    trade.mergeFindTradeByIdResult(
      Trade(
        id: 'persisted',
        amount: '1',
        refundAddress: 'different',
        refundJson: TradeRefund(configuredAddress: 'different').encode(),
      ),
    );
    expect(trade.refundAddress, 'configured');
    expect(TradeRefund.fromJsonString(trade.refundJson!).configuredAddress, 'configured');
  });

  test('preserves unknown current-version envelopes during status merge', () {
    const unknownExecution = '{"version":1,"future":true}';
    const unknownRefund = '{"version":1,"future":true}';
    final trade =
        Trade(id: 'trade', amount: '1', executionJson: unknownExecution, refundJson: unknownRefund);
    trade.mergeFindTradeByIdResult(
      Trade(
        id: 'trade',
        amount: '1',
        executionJson: '{"version":1,"future":false}',
        refundJson: '{"version":1,"future":false}',
      ),
    );
    expect(trade.executionJson, unknownExecution);
    expect(trade.refundJson, unknownRefund);
  });

  test('does not regress completed refund evidence', () {
    final completed = TradeRefund(
      status: 'completed',
      chain: 'ETH',
      amount: '1',
      originalAmount: '1.1',
      feeDeducted: '0.1',
      feeDescription: 'network fee',
      observedAddress: 'observed',
    );
    final trade = Trade(id: 'trade', amount: '1', refundJson: completed.encode());
    trade.mergeFindTradeByIdResult(
      Trade(
        id: 'trade',
        amount: '1',
        refundJson: TradeRefund(
          status: 'pending',
          chain: 'ETH',
          amount: '1',
          originalAmount: '1.1',
          feeDeducted: '0.1',
          feeDescription: 'network fee',
          observedAddress: 'observed',
        ).encode(),
      ),
    );
    expect(TradeRefund.fromJsonString(trade.refundJson!).status, 'completed');
  });

  test('atomically rejects a status validated against a different execution', () async {
    final database = await _openTradeDatabase();
    addTearDown(() async {
      await database.close();
      sqlite.db = null;
    });

    final trade = _status(id: 'atomic', state: 'created', executionJson: 'execution-a');
    await trade.save();
    final update = _status(id: 'atomic', state: 'confirming', receiveAmount: '2');

    await expectLater(
      trade.mergeAndSavePegaroute(update, expectedRawExecutionJson: 'execution-b'),
      throwsA(isA<StateError>()),
    );
    final persisted = await Trade.getByTradeId('atomic');
    expect(persisted!.state, TradeState.created);
    expect(persisted.receiveAmount, isNull);
  });

  test('requires the caller and latest row to have the exact execution context', () async {
    final database = await _openTradeDatabase();
    addTearDown(() async {
      await database.close();
      sqlite.db = null;
    });

    final trade = _status(id: 'caller-context', state: 'created', executionJson: 'execution-a');
    await trade.save();
    await database.update(
      Trade.tableName,
      {'executionJson': 'execution-b'},
      where: 'id = ?',
      whereArgs: ['caller-context'],
    );

    await expectLater(
      trade.mergeAndSavePegaroute(
        _status(id: 'caller-context', state: 'confirming'),
        expectedRawExecutionJson: 'execution-b',
      ),
      throwsA(isA<StateError>()),
    );
    expect((await Trade.getByTradeId('caller-context'))!.state, TradeState.created);
  });

  test('applies Pegaroute stale, same-state, and forward evidence rules', () async {
    final database = await _openTradeDatabase();
    addTearDown(() async {
      await database.close();
      sqlite.db = null;
    });

    final localFrom = Erc20Token(
      name: 'SPX6900',
      symbol: 'SPX',
      contractAddress: '0x50da645f148798f68ef2d7db7c1cb22a6819bb2c',
      decimal: 18,
      tag: 'BASE',
    );
    final trade = _status(
      id: 'evidence',
      state: 'exchanging',
      executionJson: 'execution',
      from: localFrom,
      to: CryptoCurrency.btc,
      amount: 'local-amount',
      receiveAmount: '1',
      outputTransaction: 'old-tx',
      expiredAt: DateTime.utc(2026, 1),
      inputAddress: 'old-input',
      providerName: 'old-provider',
    );
    trade.payoutAddress = 'local-payout';
    trade.memo = 'local-memo';
    await trade.save();

    await trade.mergeAndSavePegaroute(
      _status(
        id: 'evidence',
        state: 'confirming',
        receiveAmount: 'stale',
        outputTransaction: 'stale-tx',
        expiredAt: DateTime.utc(2027, 1),
        inputAddress: 'stale-input',
        providerName: 'stale-provider',
        isRefund: true,
      ),
      expectedRawExecutionJson: 'execution',
    );
    expect(trade.state, TradeState.exchanging);
    expect(trade.receiveAmount, '1');
    expect(trade.outputTransaction, 'old-tx');
    expect(trade.expiredAt!.millisecondsSinceEpoch, DateTime.utc(2026, 1).millisecondsSinceEpoch);
    expect(trade.inputAddress, 'old-input');
    expect(trade.providerName, 'old-provider');
    expect(trade.isRefund, isFalse);

    await trade.mergeAndSavePegaroute(
      _status(id: 'evidence', state: 'exchanging', receiveAmount: 'conflict'),
      expectedRawExecutionJson: 'execution',
    );
    expect(trade.receiveAmount, '1');

    await trade.mergeAndSavePegaroute(
      _status(id: 'evidence', state: 'exchanging', outputTransaction: 'filled-tx'),
      expectedRawExecutionJson: 'execution',
    );
    expect(trade.outputTransaction, 'old-tx');

    final missing = _status(id: 'missing', state: 'created', executionJson: 'execution');
    await missing.save();
    await missing.mergeAndSavePegaroute(
      _status(id: 'missing', state: 'created', receiveAmount: 'filled'),
      expectedRawExecutionJson: 'execution',
    );
    expect(missing.receiveAmount, 'filled');

    await trade.mergeAndSavePegaroute(
      _status(
        id: 'evidence',
        state: 'sending',
        amount: 'remote-amount',
        from: CryptoCurrency.btc,
        to: CryptoCurrency.eth,
        receiveAmount: '2',
        outputTransaction: 'new-tx',
        inputAddress: 'new-input',
        providerName: 'new-provider',
        memo: 'remote-memo',
      ),
      expectedRawExecutionJson: 'execution',
    );
    expect(trade.state, TradeState.sending);
    expect(trade.receiveAmount, '2');
    expect(trade.outputTransaction, 'new-tx');
    expect(trade.inputAddress, 'new-input');
    expect(trade.amount, 'local-amount');
    expect(identical(trade.from, localFrom), isTrue);
    expect(trade.to, CryptoCurrency.btc);
    expect(trade.payoutAddress, 'local-payout');
    expect(trade.providerName, 'old-provider');
    expect(trade.memo, 'local-memo');

    await trade.mergeAndSavePegaroute(
      _status(id: 'evidence', state: 'success', outputTransaction: ''),
      expectedRawExecutionJson: 'execution',
    );
    expect(trade.outputTransaction, 'new-tx');
  });

  test('applies the complete Pegaroute state graph in order', () async {
    final database = await _openTradeDatabase();
    addTearDown(() async {
      await database.close();
      sqlite.db = null;
    });

    final trade = _status(id: 'graph', state: 'created', executionJson: 'execution');
    await trade.save();

    Future<void> update(String state) async {
      await trade.mergeAndSavePegaroute(
        _status(id: 'graph', state: state),
        expectedRawExecutionJson: 'execution',
      );
    }

    await update('sending'); // Normal states may be skipped.
    await update('success');
    await update('created'); // Success is terminal.
    expect(trade.state, TradeState.success);

    final refund = _status(id: 'refund-graph', state: 'created', executionJson: 'execution');
    await refund.save();
    await refund.mergeAndSavePegaroute(
      _status(id: 'refund-graph', state: 'refund'),
      expectedRawExecutionJson: 'execution',
    );
    await refund.mergeAndSavePegaroute(
      _status(id: 'refund-graph', state: 'refunded'),
      expectedRawExecutionJson: 'execution',
    );
    expect(refund.state, TradeState.refunded);

    final invalidRefund =
        _status(id: 'invalid-refund', state: 'refund', executionJson: 'execution');
    await invalidRefund.save();
    await invalidRefund.mergeAndSavePegaroute(
      _status(id: 'invalid-refund', state: 'failed'),
      expectedRawExecutionJson: 'execution',
    );
    expect(invalidRefund.state, TradeState.refund);

    final invalidFailed =
        _status(id: 'invalid-failed', state: 'failed', executionJson: 'execution');
    await invalidFailed.save();
    await invalidFailed.mergeAndSavePegaroute(
      _status(id: 'invalid-failed', state: 'success'),
      expectedRawExecutionJson: 'execution',
    );
    expect(invalidFailed.state, TradeState.failed);
  });

  test('enforces Pegaroute refund, failed, and terminal transitions', () async {
    final database = await _openTradeDatabase();
    addTearDown(() async {
      await database.close();
      sqlite.db = null;
    });

    Future<Trade> create(String id, String state) async {
      final trade = _status(id: id, state: state, executionJson: 'execution');
      await trade.save();
      return trade;
    }

    final refund = await create('refund', 'refund');
    await refund.mergeAndSavePegaroute(
      _status(id: 'refund', state: 'confirming', receiveAmount: 'stale'),
      expectedRawExecutionJson: 'execution',
    );
    expect(refund.state, TradeState.refund);
    expect(refund.receiveAmount, isNull);
    await refund.mergeAndSavePegaroute(
      _status(id: 'refund', state: 'refunded'),
      expectedRawExecutionJson: 'execution',
    );
    expect(refund.state, TradeState.refunded);

    final failed = await create('failed', 'failed');
    await failed.mergeAndSavePegaroute(
      _status(id: 'failed', state: 'created', receiveAmount: 'stale'),
      expectedRawExecutionJson: 'execution',
    );
    expect(failed.state, TradeState.failed);
    expect(failed.receiveAmount, isNull);
    await failed.mergeAndSavePegaroute(
      _status(id: 'failed', state: 'refunded'),
      expectedRawExecutionJson: 'execution',
    );
    expect(failed.state, TradeState.refunded);

    final success = await create('success', 'success');
    await success.mergeAndSavePegaroute(
      _status(id: 'success', state: 'created', receiveAmount: 'stale'),
      expectedRawExecutionJson: 'execution',
    );
    expect(success.state, TradeState.success);
    expect(success.receiveAmount, isNull);
    await success.mergeAndSavePegaroute(
      _status(id: 'success', state: 'refunded'),
      expectedRawExecutionJson: 'execution',
    );
    expect(success.state, TradeState.success);
  });

  test('serializes status merges from separate Trade instances', () async {
    final database = await _openTradeDatabase();
    addTearDown(() async {
      await database.close();
      sqlite.db = null;
    });

    final original = _status(id: 'concurrent', state: 'created', executionJson: 'execution');
    await original.save();
    final first = await Trade.getByTradeId('concurrent');
    final second = await Trade.getByTradeId('concurrent');
    await Future.wait([
      first!.mergeAndSavePegaroute(
        _status(
          id: 'concurrent',
          state: 'confirming',
          receiveAmount: 'lower',
          outputTransaction: 'lower-tx',
        ),
        expectedRawExecutionJson: 'execution',
      ),
      second!.mergeAndSavePegaroute(
        _status(
          id: 'concurrent',
          state: 'exchanging',
          receiveAmount: 'higher',
          outputTransaction: 'higher-tx',
        ),
        expectedRawExecutionJson: 'execution',
      ),
    ]);

    final persisted = await Trade.getByTradeId('concurrent');
    expect(persisted!.state, TradeState.exchanging);
    expect(persisted.receiveAmount, 'higher');
    expect(persisted.outputTransaction, 'higher-tx');
    expect(first.state == TradeState.exchanging || second.state == TradeState.exchanging, isTrue);
  });
}

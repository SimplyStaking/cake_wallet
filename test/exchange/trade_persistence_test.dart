import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_refund.dart';
import 'package:cake_wallet/exchange/trade_state.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/db/sqlite.dart' as sqlite;
import 'package:http/http.dart' as very_insecure_http_do_not_use;
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

Trade _boundTrade({String id = 'refresh', String state = 'created'}) {
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
      tradeId: id,
      providerRaw: 17,
      quoteId: 'quote-fixture',
      quoteExpiresAt: DateTime.utc(2099),
      routeExpiry: null,
      providerTransactionId: id,
      sourceAmount: '1',
      sourceAmountBaseUnits: '1000000000000000000',
      sourceDecimals: 18,
      destinationDecimals: 8,
      senderAddress: '0x0000000000000000000000000000000000000002',
      refundAddress: '0x0000000000000000000000000000000000000003',
      destinationAddress: 'bc1qfixture',
      isSendAll: false,
      walletId: 'wallet-fixture',
      walletChainId: 1,
      walletAddress: '0x0000000000000000000000000000000000000002',
      reviewedRouteJson:
          '{"provider":"instaswap","providerType":"fixture","subprovider":null,"private":false,"expectedOutput":"0.99","fees":{"affiliate":"0","liquidity":"0.01","outbound":"0","subAffiliate":null,"total":"0.01","totalBps":null,"slippageBps":null},"estimatedTimeSeconds":120,"memo":null,"inboundAddress":"0x0000000000000000000000000000000000000001","router":null,"minAmount":null,"expiry":null,"gasRate":null,"resolvedFee":null,"openOceanRoute":null}',
      providerReferenceId: null,
    ),
    payload: const {
      'chainId': 1,
      'to': '0x0000000000000000000000000000000000000001',
      'data': null,
      'value': {'display': '1', 'baseUnits': '1000000000000000000'},
      'gasLimit': null,
      'memo': null,
      'approval': null,
      'transferAmount': null,
    },
  );
  return Trade(
    id: id,
    amount: '1',
    from: CryptoCurrency.eth,
    to: CryptoCurrency.btc,
    provider: ExchangeProviderDescription.pegaroute,
    state: TradeState.deserialize(raw: state),
    senderAddress: '0x0000000000000000000000000000000000000002',
    refundAddress: '0x0000000000000000000000000000000000000003',
    payoutAddress: 'bc1qfixture',
    walletId: 'wallet-fixture',
    fromWalletAddress: '0x0000000000000000000000000000000000000002',
    chainId: 1,
    providerName: 'instaswap',
    executionJson: execution.encode(),
  );
}

Map<String, dynamic> _statusResponse(String id, {String internalStatus = 'submitted'}) {
  final value = json.decode(
    File('test/exchange/fixtures/pegaroute/status_refund.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  value['transactionId'] = id;
  value['internalStatus'] = internalStatus;
  value['status'] = internalStatus == 'completed'
      ? 'success'
      : internalStatus == 'failed' || internalStatus == 'refunded'
          ? 'fail'
          : 'pending';
  return value;
}

PegarouteExchangeProvider _provider(
  Map<String, dynamic> response, {
  Future<void> Function()? beforeResponse,
}) {
  return PegarouteExchangeProvider(
    apiClient: PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
      get: (uri, headers) async {
        await beforeResponse?.call();
        return very_insecure_http_do_not_use.Response(json.encode(response), 200);
      },
    ),
  );
}

void main() {
  test('round-trips the persisted execution and refund envelopes', () {
    final trade = _boundTrade();
    trade.refundJson = TradeRefund(configuredAddress: 'configured').encode();
    final row = trade.toSqliteMap()..['tradeId'] = 1;
    final reloaded = Trade.fromSqliteRow(row);
    expect(reloaded.provider, ExchangeProviderDescription.pegaroute);
    expect(reloaded.executionJson, trade.executionJson);
    expect(TradeRefund.fromJsonString(reloaded.refundJson!).configuredAddress, 'configured');
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(trade: reloaded),
      returnsNormally,
    );
  });

  test('the old public Pegaroute merge boundary is unusable', () async {
    final trade = _boundTrade();
    await expectLater(
      trade.mergeAndSavePegaroute(
        Trade(id: trade.id, amount: '1', state: TradeState.confirming),
        expectedRawExecutionJson: trade.executionJson!,
      ),
      throwsA(isA<StateError>()),
    );
    trade.mergeFindTradeByIdResult(Trade(id: trade.id, amount: '1', state: TradeState.success));
    expect(trade.state, TradeState.created);
  });

  test('rejects an unsaved caller before transport', () async {
    var calls = 0;
    final provider = _provider(
      _statusResponse('refresh'),
      beforeResponse: () async {
        calls++;
      },
    );
    final unsaved = _boundTrade();
    await expectLater(
      provider.refreshTradeStatus(trade: unsaved),
      throwsA(isA<PegarouteBindingException>()),
    );
    expect(calls, 0);
  });

  test('commits a valid forward status and syncs only after commit', () async {
    final database = await _openTradeDatabase();
    addTearDown(() async {
      await database.close();
      sqlite.db = null;
    });
    final trade = _boundTrade();
    await trade.save();

    final result = await _provider(_statusResponse(trade.id)).refreshTradeStatus(trade: trade);
    expect(identical(result, trade), isTrue);
    expect(trade.state, TradeState.confirming);
    expect(trade.receiveAmount, '0.01');
    expect(trade.outputTransaction, 'output-hash-fixture');
    expect((await Trade.getByTradeId(trade.id))!.state, TradeState.confirming);
  });

  test('rejects every latest-row binding scalar mutation', () async {
    final mutations = <String, dynamic>{
      'amount': '2',
      'walletId': 'other-wallet',
      'providerName': 'other-provider',
      'providerId': 'other-reference',
      'senderAddress': '0x0000000000000000000000000000000000000004',
      'fromWalletAddress': '0x0000000000000000000000000000000000000004',
      'payoutAddress': 'different-destination',
      'chainId': 56,
      'executionJson': '{"changed":true}',
    };
    for (final entry in mutations.entries) {
      final database = await _openTradeDatabase();
      final trade = _boundTrade(id: 'mutation-${entry.key}');
      await trade.save();
      await database.update(
        Trade.tableName,
        {entry.key: entry.value},
        where: 'id = ?',
        whereArgs: [trade.id],
      );
      await expectLater(
        _provider(_statusResponse(trade.id)).refreshTradeStatus(trade: trade),
        throwsA(isA<PegarouteBindingException>()),
      );
      final latest = await Trade.getByTradeId(trade.id);
      expect(latest!.state, TradeState.created, reason: entry.key);
      await database.close();
      sqlite.db = null;
    }
  });

  test('rejects a deleted and recreated row with the same public id', () async {
    final database = await _openTradeDatabase();
    addTearDown(() async {
      await database.close();
      sqlite.db = null;
    });
    final trade = _boundTrade(id: 'aba');
    await trade.save();
    final originalInternalId = trade.internalId;
    final provider = _provider(
      _statusResponse(trade.id),
      beforeResponse: () async {
        await Trade.deleteTrade(trade);
        await _boundTrade(id: trade.id).save();
      },
    );

    await expectLater(
      provider.refreshTradeStatus(trade: trade),
      throwsA(isA<StateError>()),
    );
    final replacement = await Trade.getByTradeId(trade.id);
    expect(replacement!.internalId, isNot(originalInternalId));
    expect(replacement.state, TradeState.created);
  });

  test('serializes concurrent refreshes against the latest row', () async {
    final database = await _openTradeDatabase();
    addTearDown(() async {
      await database.close();
      sqlite.db = null;
    });
    final original = _boundTrade(id: 'race');
    await original.save();
    final first = await Trade.getByTradeId(original.id);
    final second = await Trade.getByTradeId(original.id);
    var call = 0;
    final provider = PegarouteExchangeProvider(
      apiClient: PegarouteApiClient(
        configuration:
            const PegarouteConfiguration(baseUrl: 'https://example.test', apiKey: 'test'),
        get: (uri, headers) async {
          final status = call++ == 0 ? 'submitted' : 'executing';
          return very_insecure_http_do_not_use.Response(
            json.encode(_statusResponse(original.id, internalStatus: status)),
            200,
          );
        },
      ),
    );
    await Future.wait([
      provider.refreshTradeStatus(trade: first!),
      provider.refreshTradeStatus(trade: second!),
    ]);
    final persisted = await Trade.getByTradeId(original.id);
    expect(persisted!.state, TradeState.exchanging);
  });

  test('applies the forward graph and ignores a stale scalar response', () async {
    final database = await _openTradeDatabase();
    addTearDown(() async {
      await database.close();
      sqlite.db = null;
    });
    final trade = _boundTrade(id: 'graph');
    await trade.save();
    for (final status in ['submitted', 'executing', 'confirming', 'completed']) {
      await _provider(_statusResponse(trade.id, internalStatus: status))
          .refreshTradeStatus(trade: trade);
    }
    expect(trade.state, TradeState.success);
    trade.receiveAmount = 'local';
    await trade.save();
    await _provider(_statusResponse(trade.id, internalStatus: 'submitted'))
        .refreshTradeStatus(trade: trade);
    expect(trade.state, TradeState.success);
    expect(trade.receiveAmount, 'local');
  });

  test('does not let generic merge alter Pegaroute refund evidence', () {
    final refund = TradeRefund(
      status: 'completed',
      chain: 'ETH',
      amount: '1',
      originalAmount: '1',
      feeDeducted: '0',
      feeDescription: 'none',
      observedAddress: 'refund-address',
    );
    final trade = Trade(
      id: 'refund',
      amount: '1',
      provider: ExchangeProviderDescription.pegaroute,
      refundJson: refund.encode(),
    );
    trade.mergeFindTradeByIdResult(
      Trade(
        id: trade.id,
        amount: '1',
        refundJson: TradeRefund(
          status: 'pending',
          chain: 'ETH',
          amount: '1',
          originalAmount: '1',
          feeDeducted: '0',
          feeDescription: 'none',
          observedAddress: 'refund-address',
        ).encode(),
      ),
    );
    expect(TradeRefund.fromJsonString(trade.refundJson!).status, 'completed');
  });

  test('advances a refunding trade to the terminal refunded state', () async {
    final database = await _openTradeDatabase();
    addTearDown(() async {
      await database.close();
      sqlite.db = null;
    });
    final trade = _boundTrade(id: 'refund-transition', state: 'refund');
    await trade.save();

    await _provider(_statusResponse(trade.id, internalStatus: 'refunded'))
        .refreshTradeStatus(trade: trade);

    expect(trade.state, TradeState.refunded);
  });
}

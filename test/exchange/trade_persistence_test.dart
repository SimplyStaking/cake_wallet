import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_currency_mapper.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_lifecycle_store.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_refund.dart';
import 'package:cake_wallet/exchange/trade_state.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/db/sqlite.dart' as sqlite;
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/spl_token.dart';
import 'package:cw_core/tron_token.dart';
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
  executionJson TEXT, refundJson TEXT, executionLifecycleJson TEXT,
  fromAssetIdentityJson TEXT, toAssetIdentityJson TEXT
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
  final value =
      json.decode(File('test/exchange/fixtures/pegaroute/status_refund.json').readAsStringSync())
          as Map<String, dynamic>;
  value['transactionId'] = id;
  value['internalStatus'] = internalStatus;
  value['status'] = internalStatus == 'completed'
      ? 'success'
      : internalStatus == 'failed' || internalStatus == 'refunded'
          ? 'fail'
          : internalStatus == 'pending'
              ? 'pending'
              : 'executing';
  return value;
}

PegarouteExchangeProvider _provider(
  Map<String, dynamic> response, {
  Future<void> Function()? beforeResponse,
}) {
  return PegarouteExchangeProvider(
    apiClient: PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
      get: (uri, headers) async {
        await beforeResponse?.call();
        return very_insecure_http_do_not_use.Response(json.encode(response), 200);
      },
    ),
  );
}

CryptoCurrency _token(bool solana) => solana
    ? SPLToken(
        name: 'Pyth Network',
        symbol: 'PYTH',
        mintAddress: 'HZ1JovNiVvGrGNiiYvEozEVgZ58xaU3RKwX8eACQBCt3',
        decimal: 8,
        mint: 'pyth',
      )
    : Erc20Token(
        name: 'SPX6900',
        symbol: 'SPX',
        contractAddress: '0x50da645f148798f68ef2d7db7c1cb22a6819bb2c',
        decimal: 18,
        tag: 'BASE',
        chainId: 8453,
      );

Trade _tokenTrade(CryptoCurrency token, {required bool source}) {
  final trade = _boundTrade();
  final asset = const PegarouteCurrencyMapper().map(token);
  final raw = jsonDecode(trade.executionJson!) as Map<String, dynamic>;
  final binding = raw['binding'] as Map<String, dynamic>;
  if (source) {
    final solana = token is SPLToken;
    final target = solana ? 'sol-deposit' : '0x0000000000000000000000000000000000000001';
    trade.from = token;
    trade.chainId = solana ? null : 8453;
    trade.senderAddress = solana ? 'sol-sender' : trade.senderAddress;
    trade.fromWalletAddress = trade.senderAddress;
    trade.refundAddress = null;
    raw['sourceChain'] = asset.chain;
    raw['sourceToken'] = asset.token;
    raw['nativeToken'] = asset.nativeToken;
    binding['sourceDecimals'] = token.decimals;
    binding['sourceAmountBaseUnits'] = BigInt.from(10).pow(token.decimals).toString();
    binding['walletChainId'] = trade.chainId;
    binding['senderAddress'] = trade.senderAddress;
    binding['walletAddress'] = trade.fromWalletAddress;
    binding['refundAddress'] = null;
    final route = jsonDecode(binding['reviewedRouteJson'] as String) as Map<String, dynamic>;
    route['inboundAddress'] = target;
    binding['reviewedRouteJson'] = jsonEncode(route);
    raw['family'] = solana ? 'solana' : 'evm';
    raw['mode'] = solana ? 'deposit-transfer' : 'erc20-transfer';
    final amount = {'display': '1', 'baseUnits': binding['sourceAmountBaseUnits']};
    raw['payload'] = solana
        ? {'to': target, 'amount': amount, 'memo': null}
        : {
            'chainId': 8453,
            'to': target,
            'data': null,
            'value': null,
            'gasLimit': null,
            'memo': null,
            'approval': null,
            'transferAmount': amount,
          };
  } else {
    trade.to = token;
    trade.payoutAddress =
        token is Erc20Token ? '0x0000000000000000000000000000000000000004' : 'token-receiver';
    raw['destinationChain'] = asset.chain;
    raw['destinationToken'] = asset.token;
    binding['destinationDecimals'] = token.decimals;
    binding['destinationAddress'] = trade.payoutAddress;
  }
  trade.executionJson = TradeExecution.fromJson(raw).encode();
  return trade;
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
      'fromDecimals': 6,
      'toDecimals': 6,
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

    await expectLater(provider.refreshTradeStatus(trade: trade), throwsA(isA<StateError>()));
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
        configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
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
      await _provider(
        _statusResponse(trade.id, internalStatus: status),
      ).refreshTradeStatus(trade: trade);
    }
    expect(trade.state, TradeState.success);
    final committedReceiveAmount = trade.receiveAmount;
    trade.receiveAmount = 'local';
    await expectLater(trade.save(), throwsStateError);
    await _provider(
      _statusResponse(trade.id, internalStatus: 'submitted'),
    ).refreshTradeStatus(trade: trade);
    expect(trade.state, TradeState.success);
    expect(trade.receiveAmount, committedReceiveAmount);
  });

  group('Pegaroute persistence boundaries', () {
    late Database database;
    const validator = PegarouteExecutionBindingValidator();

    setUp(() async {
      database = await _openTradeDatabase();
    });

    tearDown(() async {
      await database.close();
      sqlite.db = null;
    });

    test('stale save cannot erase lifecycle, execution, status or refund evidence', () async {
      final stale = _boundTrade();
      await stale.save();
      final execution = validator.validatePersisted(trade: stale);
      final store = PegarouteExecutionLifecycleStore();
      await store.beforeBroadcast(
        execution: execution,
        executionHash: 'funding-hash',
        tradeInternalId: stale.internalId,
      );
      await store.onBroadcasted(
        execution: execution,
        executionHash: 'funding-hash',
        tradeInternalId: stale.internalId,
      );
      final live = (await Trade.getByTradeId(stale.id))!;
      await _provider(_statusResponse(stale.id, internalStatus: 'refunded'))
          .refreshTradeStatus(trade: live);
      final before = await database.query(Trade.tableName);
      expect(live.refundJson, isNotNull);
      expect(live.state, TradeState.refunded);
      stale.executionJson = null;
      stale.refundJson = null;
      stale.executionLifecycleJson = null;
      await expectLater(stale.save(), throwsStateError);
      expect(await database.query(Trade.tableName), before);
    });

    test('generic save cannot resurrect an old row after delete/recreate ABA', () async {
      final stale = _boundTrade();
      await stale.save();
      final oldId = stale.internalId;
      await Trade.deleteTrade(stale);
      final replacement = _boundTrade();
      await replacement.save();
      expect(replacement.internalId, isNot(oldId));
      final before = await database.query(Trade.tableName);
      await expectLater(stale.save(), throwsStateError);
      stale.internalId = 0;
      stale.providerRaw = ExchangeProviderDescription.changeNow.raw;
      await expectLater(stale.save(), throwsStateError);
      expect(await database.query(Trade.tableName), before);
    });

    test('neither unique key nor provider mutation can replace a protected row', () async {
      final trade = _boundTrade();
      await trade.save();
      final before = await database.query(Trade.tableName);
      final attempts = [
        _boundTrade(),
        _boundTrade()..internalId = trade.internalId + 100,
        Trade(id: trade.id, amount: '2', provider: ExchangeProviderDescription.changeNow),
        Trade(internalId: trade.internalId, id: 'other', amount: '2'),
      ];
      for (final attempt in attempts) {
        await expectLater(attempt.save(), throwsStateError);
      }
      final loaded = (await Trade.getByTradeId(trade.id))!;
      loaded.id = 'other';
      loaded.internalId = 0;
      loaded.providerRaw = ExchangeProviderDescription.changeNow.raw;
      await expectLater(loaded.save(), throwsStateError);
      expect(await database.query(Trade.tableName), before);
    });

    test('Pegaroute insertion cannot replace an unrelated provider', () async {
      final other =
          Trade(id: 'refresh', amount: '2', provider: ExchangeProviderDescription.changeNow);
      await other.save();
      final before = await database.query(Trade.tableName);
      await expectLater(_boundTrade().save(), throwsA(isA<DatabaseException>()));
      expect(await database.query(Trade.tableName), before);
    });

    test('other providers retain insert, update and public-id replacement behavior', () async {
      final other =
          Trade(id: 'other', amount: '1', provider: ExchangeProviderDescription.changeNow);
      await other.save();
      final firstId = other.internalId;
      other.amount = '2';
      await other.save();
      expect(other.internalId, firstId);
      expect((await Trade.getByTradeId(other.id))!.amount, '2');
      final replacement = Trade(id: other.id, amount: '3');
      await replacement.save();
      expect(replacement.internalId, isNot(firstId));
      expect((await Trade.getByTradeId(other.id))!.amount, '3');
    });

    for (final solana in [false, true]) {
      for (final source in [false, true]) {
        test(
            '${solana ? 'SPL' : 'EVM'} ${source ? 'source' : 'destination'} survives SQLite and status refresh',
            () async {
          final trade = _tokenTrade(_token(solana), source: source);
          await trade.save();
          final reloaded = (await Trade.getByTradeId(trade.id))!;
          final restored = source ? reloaded.from : reloaded.to;
          if (solana) {
            expect(restored, isA<SPLToken>());
            expect((restored as SPLToken).mintAddress, (_token(true) as SPLToken).mintAddress);
            expect(restored.mint, 'pyth');
          } else {
            expect(restored, isA<Erc20Token>());
            expect((restored as Erc20Token).contractAddress,
                (_token(false) as Erc20Token).contractAddress);
            expect(restored.chainId, 8453);
          }
          final execution = validator.validatePersisted(trade: reloaded).execution;
          final response = _statusResponse(trade.id);
          response['input'] = {
            'chain': execution.sourceChain,
            'token': execution.sourceToken,
            'amount': '1',
            'address': trade.senderAddress,
            if (trade.refundAddress != null) 'refundAddress': trade.refundAddress,
          };
          response['output'] = {
            'chain': execution.destinationChain,
            'token': execution.destinationToken,
            'address': trade.payoutAddress,
            'amount': '0.01',
          };
          final before = (await database.query(Trade.tableName)).single;
          await _provider(response).refreshTradeStatus(trade: reloaded);
          final after = (await database.query(Trade.tableName)).single;
          expect(after['fromAssetIdentityJson'], before['fromAssetIdentityJson']);
          expect(after['toAssetIdentityJson'], before['toAssetIdentityJson']);
          expect(after['executionJson'], before['executionJson']);
          expect(reloaded.state, TradeState.confirming);
          validator.validatePersisted(trade: (await Trade.getByTradeId(trade.id))!);
        });
      }

      test('${solana ? 'SPL' : 'EVM'} missing/corrupt identity cannot fund or refresh', () async {
        final trade = _tokenTrade(_token(solana), source: true);
        await trade.save();
        final execution = validator.validatePersisted(trade: trade);
        final identity = jsonDecode(trade.toSqliteMap()['fromAssetIdentityJson'] as String)
            as Map<String, dynamic>;
        final mutations = <Object?>[
          null,
          '',
          '{}',
          '[]',
          jsonEncode({...identity, 'version': 2}),
          jsonEncode({...identity, 'extra': 'unknown'}),
          jsonEncode({...identity, 'token': '${identity['token']}x'}),
          jsonEncode({...identity, 'chain': 'ETH'}),
          jsonEncode({...identity, 'nativeToken': 'BTC'}),
          jsonEncode({...identity, 'chainId': 56}),
          jsonEncode({...identity, 'decimals': 6}),
          jsonEncode({...identity, 'decimals': '18'}),
          jsonEncode({...identity, 'kind': solana ? 'erc20' : 'spl'}),
        ];
        for (final value in mutations) {
          await database.update(Trade.tableName, {'fromAssetIdentityJson': value});
          final reloaded = (await Trade.getByTradeId(trade.id))!;
          await expectLater(
            _provider(_statusResponse(trade.id)).refreshTradeStatus(trade: reloaded),
            throwsA(isA<PegarouteBindingException>()),
            reason: '$value',
          );
          await expectLater(
            PegarouteExecutionLifecycleStore().beforeBroadcast(
              execution: execution,
              executionHash: 'hash',
              tradeInternalId: trade.internalId,
            ),
            throwsA(isA<PegarouteBindingException>()),
            reason: '$value',
          );
          expect((await Trade.getByTradeId(trade.id))!.executionLifecycleJson, isNull);
        }
      });
    }

    test('an uncatalogued TRON token cannot be persisted as a native asset', () async {
      final token = TronToken(
        name: 'Tether',
        symbol: 'USDT',
        contractAddress: 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t',
        decimal: 6,
      );
      final trade = _boundTrade()..to = token;
      await expectLater(trade.save(), throwsA(isA<PegarouteCurrencyException>()));
      expect(await database.query(Trade.tableName), isEmpty);
    });

    test('CAS preserves exact valid stored token bytes during lifecycle and status writes',
        () async {
      final trade = _tokenTrade(_token(false), source: false);
      await trade.save();
      final rawIdentity = ' ${trade.toSqliteMap()['toAssetIdentityJson']}\n';
      await database.update(Trade.tableName, {'toAssetIdentityJson': rawIdentity});
      final execution = validator.validatePersisted(trade: trade);
      await PegarouteExecutionLifecycleStore().beforeBroadcast(
        execution: execution,
        executionHash: 'hash',
        tradeInternalId: trade.internalId,
      );
      final before = (await database.query(Trade.tableName)).single;
      final response = _statusResponse(trade.id);
      response['output'] = {
        'chain': execution.execution.destinationChain,
        'token': execution.execution.destinationToken,
        'address': trade.payoutAddress,
        'amount': '0.01',
      };
      await _provider(response).refreshTradeStatus(trade: trade);
      final after = (await database.query(Trade.tableName)).single;
      expect(after['toAssetIdentityJson'], rawIdentity);
      expect(after['executionLifecycleJson'], before['executionLifecycleJson']);
      expect(after['executionJson'], before['executionJson']);
    });

    test('native catalog restoration cannot conceal corrupted SQLite decimals', () async {
      final trade = _boundTrade();
      await trade.save();
      final execution = validator.validatePersisted(trade: trade);
      await database.update(Trade.tableName, {'fromDecimals': 6});
      await expectLater(
        PegarouteExecutionLifecycleStore().beforeBroadcast(
          execution: execution,
          executionHash: 'hash',
          tradeInternalId: trade.internalId,
        ),
        throwsA(isA<PegarouteBindingException>()),
      );
      expect((await Trade.getByTradeId(trade.id))!.executionLifecycleJson, isNull);
    });

    test('invalid serialized intent is rejected before insertion', () async {
      final trade = _tokenTrade(_token(false), source: true)..amount = '2';
      await expectLater(trade.save(), throwsA(isA<PegarouteBindingException>()));
      expect(await database.query(Trade.tableName), isEmpty);
      expect(trade.internalId, 0);
    });

    test('validates actual SQLite token restoration and rolls back a corrupt insert', () async {
      await database.execute('''
CREATE TRIGGER corrupt_asset AFTER INSERT ON Trade BEGIN
  UPDATE Trade SET fromAssetIdentityJson = '{}' WHERE tradeId = NEW.tradeId;
END
''');
      final trade = _tokenTrade(_token(false), source: true);
      await expectLater(trade.save(), throwsA(isA<PegarouteBindingException>()));
      expect(await database.query(Trade.tableName), isEmpty);
      expect(trade.internalId, 0);
    });
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

    final response = _statusResponse(trade.id, internalStatus: 'refunded');
    response['refund'] = {
      'status': 'completed',
      'chain': 'ETH',
      'amount': '1',
      'originalAmount': '1',
      'feeDeducted': '0',
      'feeDescription': 'fixture',
      'refundAddress': '0x0000000000000000000000000000000000000004',
    };
    await _provider(response).refreshTradeStatus(trade: trade);

    expect(trade.state, TradeState.refunded);
    final rows = await database
        .query(Trade.tableName, where: '${Trade.selfIdColumn} = ?', whereArgs: [trade.internalId]);
    final saved = Trade.fromSqliteRow(rows.single);
    final refund = TradeRefund.fromJsonString(saved.refundJson!);
    expect(refund.configuredAddress, '0x0000000000000000000000000000000000000003');
    expect(refund.observedAddress, '0x0000000000000000000000000000000000000004');
    expect(saved.refundAddress, refund.configuredAddress);
  });
}

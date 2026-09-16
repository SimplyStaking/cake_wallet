// Offline wallet facade/SQLite fixtures; no native wallet or network is used.
import 'dart:convert';
import 'dart:io';

import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:cake_wallet/bitcoin/bitcoin.dart';
import 'package:cake_wallet/zcash/zcash.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_currency_mapper.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_lifecycle_store.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_native_eth.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_trusted_execution.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cake_wallet/exchange/trade_execution_lifecycle.dart';
import 'package:cake_wallet/exchange/trade_request.dart';
import 'package:cake_wallet/view_model/send/output.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/db/sqlite.dart' as sqlite;
import 'package:cw_core/output_info.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/spl_token.dart';
import 'package:cw_core/solana_serialized_transaction_credentials.dart';
import 'package:cw_core/transaction_history.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/unspent_coin_type.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_bitcoin/bitcoin_transaction_credentials.dart';
import 'package:cw_monero/monero_transaction_creation_credentials.dart';
import 'package:cw_solana/solana_transaction_credentials.dart';
import 'package:cw_tron/tron_transaction_credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as very_insecure_http_do_not_use;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mobx/mobx.dart';

const _sender = 'fixture-wallet-address';
const _target = 'fixture-deposit-address';
const _destination = '0x0000000000000000000000000000000000000001';
final _solBytes = [
  1,
  ...List.filled(64, 1),
  1,
  0,
  0,
  1,
  ...List.filled(32, 2),
  ...List.filled(32, 3),
  0
];

class _Addresses implements WalletAddresses {
  @override
  String get address => _sender;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Balance extends Balance {
  _Balance(CryptoCurrency currency, BigInt amount)
      : super(Money(amount, currency), Money.zero(currency));
}

class _Pending with PendingTransaction {
  _Pending(this.wallet, this.amount)
      : id = wallet.type == WalletType.solana || wallet.type == WalletType.zcash ? '' : 'ab' * 32,
        hex = wallet.type == WalletType.zcash
            ? ''
            : wallet.type == WalletType.solana
                ? Base58Encoder.encode(_solBytes)
                : '01020304';
  final _Wallet wallet;
  @override
  final Money amount;
  @override
  Money get fee => Money(BigInt.from(1000), wallet.currency);
  @override
  String id;
  @override
  String hex;
  @override
  String get amountFormatted => amount.toString();
  @override
  Future<void> commit() async {
    wallet.broadcasts++;
    if (wallet.unknown) throw const SocketException('Ambiguous submission');
    if (wallet.type == WalletType.zcash) id = 'cd' * 32;
    if (wallet.type == WalletType.solana) id = Base58Encoder.encode(List.filled(64, 1));
    if (wallet.returnedId != null) id = wallet.returnedId!;
    if (wallet.postBroadcastFailure) throw StateError('Balance refresh failed after broadcast');
  }

  @override
  Future<Map<String, String>> commitUR() => throw UnimplementedError();
}

class _Wallet
    extends WalletBase<Balance, TransactionHistoryBase<TransactionInfo>, TransactionInfo> {
  _Wallet(WalletType type, this.currency)
      : super(
            WalletInfo.external(
              id: 'deposit-fixture',
              name: 'deposit-fixture',
              type: type,
              isRecovery: false,
              restoreHeight: 0,
              date: DateTime.utc(2026),
              dirPath: '',
              path: '',
              address: _sender,
            ),
            DerivationInfo());
  @override
  final CryptoCurrency currency;
  bool hardware = false, unknown = false, postBroadcastFailure = false, exactBalance = false;
  String? expectedMemo;
  String? expectedSerialized;
  String? returnedId;
  int builds = 0, broadcasts = 0;
  late _Pending pending;
  @override
  bool get isSoftwareWallet => !hardware;
  @override
  bool get isHardwareWallet => hardware;
  @override
  WalletAddresses get walletAddresses => _Addresses();
  @override
  ObservableMap<CryptoCurrency, Balance> get balance => ObservableMap.of({
        currency: _Balance(
            currency, BigInt.from(exactBalance ? 1 : 10) * BigInt.from(10).pow(currency.decimals)),
      });
  @override
  Future<PendingTransaction> createTransaction(Object credentials) async {
    builds++;
    if (credentials is SolanaSerializedTransactionCredentials) {
      expect(credentials.transactionBase58, Base58Encoder.encode(_solBytes));
      pending = _Pending(this, credentials.amount);
      return pending;
    }
    final List<OutputInfo> outputs;
    if (credentials is BitcoinTransactionCredentials) {
      outputs = credentials.outputs;
      expect(credentials.coinTypeToSpendFrom, UnspentCoinType.nonMweb);
      expect(credentials.payjoinUri, isNull);
    } else if (credentials is MoneroTransactionCreationCredentials) {
      outputs = credentials.outputs;
    } else if (credentials is SolanaTransactionCredentials) {
      outputs = credentials.outputs;
    } else if (credentials is TronTransactionCredentials) {
      outputs = credentials.outputs;
    } else {
      outputs = credentials as List<OutputInfo>;
    }
    final output = outputs.single;
    expect(output.address, _target);
    expect(output.memo, expectedMemo);
    expect(output.sendAll, false);
    expect(output.cryptoAmount.amount, BigInt.from(10).pow(output.cryptoAmount.currency.decimals));
    pending = _Pending(this, output.cryptoAmount);
    return pending;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Bitcoin implements Bitcoin {
  _Bitcoin(this.original);
  final Bitcoin original;
  bool testnet = false;
  @override
  bool isTestnet(Object wallet) => testnet;
  @override
  TransactionPriority getMediumTransactionPriority() => original.getMediumTransactionPriority();
  @override
  Object createBitcoinTransactionCredentials(
    List<Output> outputs, {
    required TransactionPriority priority,
    int? feeRate,
    UnspentCoinType coinTypeToSpendFrom = UnspentCoinType.any,
    String? payjoinUri,
  }) =>
      original.createBitcoinTransactionCredentials(outputs,
          priority: priority,
          feeRate: feeRate,
          coinTypeToSpendFrom: coinTypeToSpendFrom,
          payjoinUri: payjoinUri);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Zcash implements Zcash {
  @override
  Object createZcashTransactionCredentialsRaw(List<OutputInfo> outputs,
      {required CryptoCurrency currency, required int feeRate}) {
    expect(currency, CryptoCurrency.zec);
    return outputs;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late Database database;
  late Bitcoin originalBitcoin;
  Zcash? originalZcash;
  late _Wallet wallet;
  late PegarouteActiveWalletContext context;
  late PegarouteExchangeProvider provider;
  late RegistryTradeExecutionDispatcher dispatcher;
  late Map<String, dynamic> quote, swap;
  late List<String> calls;
  String? notifiedHash;
  bool failCallback = false;
  bool serveStatus = false;
  String? statusHash;

  setUp(() async {
    originalBitcoin = bitcoin!;
    bitcoin = _Bitcoin(originalBitcoin);
    originalZcash = zcash;
    zcash = _Zcash();
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final keys = Trade(id: '', amount: '').toSqliteMap().keys.where((key) => key != 'tradeId');
    await database.execute('CREATE TABLE Trade (tradeId INTEGER PRIMARY KEY AUTOINCREMENT, '
        '${keys.map((key) => '"$key"').join(', ')}, fromAssetIdentityJson TEXT, toAssetIdentityJson TEXT)');
    await database.execute('CREATE UNIQUE INDEX idx_trade_id_unique ON Trade (id)');
    sqlite.db = database;
    wallet = _Wallet(WalletType.zcash, CryptoCurrency.zec);
    context = PegarouteActiveWalletContext(() => wallet, supportsWallet: pegarouteTrustedWallet);
    quote = (jsonDecode(File('test/exchange/fixtures/pegaroute/quote.json').readAsStringSync())
        as Map<String, dynamic>)
      ..['expiresAt'] = '2099-01-01T00:00:00.000Z';
    swap = jsonDecode(File('test/exchange/fixtures/pegaroute/swap.json').readAsStringSync())
        as Map<String, dynamic>;
    swap['provider']['details']['instaswapSwapLite']['depositAddress'] = _target;
    calls = [];
    notifiedHash = null;
    failCallback = false;
    serveStatus = false;
    statusHash = null;
    provider = PegarouteExchangeProvider(
        currentWallet: () => wallet,
        executableQuotesOnly: true,
        currencyLookup: (chain, token) async =>
            chain == 'ETH' ? CryptoCurrency.eth : wallet.currency,
        apiClient: PegarouteApiClient(
            configuration: const PegarouteConfiguration(baseUrl: 'https://fixture.invalid'),
            get: (uri, headers) async {
              calls.add('GET ${uri.path}');
              if (uri.path == '/quote')
                return very_insecure_http_do_not_use.Response(jsonEncode(quote), 200);
              if (serveStatus) {
                final source = const PegarouteCurrencyMapper().map(wallet.currency);
                return very_insecure_http_do_not_use.Response(
                    jsonEncode({
                      'transactionId': 'transaction-fixture',
                      'status': 'executing',
                      'internalStatus': 'submitted',
                      'route': swap['route'],
                      'execution': swap['execution'],
                      'provider': swap['provider'],
                      'input': {
                        'chain': source.chain,
                        'token': source.token,
                        'amount': '1',
                        'address': _sender,
                        'refundAddress': _sender,
                        'txHash': statusHash ?? notifiedHash
                      },
                      'output': {'chain': 'ETH', 'token': 'ETH', 'address': _destination},
                      'fees': swap['route']['fees'],
                      'timestamps': {'created': '2026-01-01T00:00:00.000Z'},
                      'error': null,
                      'refund': null,
                      'streamingProgress': null,
                    }),
                    200);
              }
              return very_insecure_http_do_not_use.Response('{}', 503);
            },
            post: (uri, headers, body) async {
              calls.add('POST ${uri.path}');
              if (uri.path == '/swap')
                return very_insecure_http_do_not_use.Response(jsonEncode(swap), 202);
              notifiedHash = jsonDecode(body)['txHash'] as String;
              if (failCallback) throw const SocketException('Callback failed');
              return very_insecure_http_do_not_use.Response(
                  jsonEncode({
                    'transactionId': 'transaction-fixture',
                    'txHash': notifiedHash,
                    'status': 'submitted',
                  }),
                  200);
            }));
    dispatcher = RegistryTradeExecutionDispatcher([
      PegarouteTrustedExecutionHandler(
        walletContext: context,
        adapter: PegarouteTrustedWalletAdapter(priority: (_) => null),
        lifecycle: PegarouteExecutionLifecycleStore(),
        onSourceCommitted: provider.notifyCommitted,
      )
    ]);
  });
  tearDown(() async {
    context.dispose();
    bitcoin = originalBitcoin;
    zcash = originalZcash;
    await database.close();
    sqlite.db = null;
  });

  Future<Trade> create(
      {String? memo, bool serialized = false, String? encoded, String encoding = 'base58'}) async {
    final family = switch (wallet.type) {
      WalletType.monero => 'other',
      WalletType.solana => 'solana',
      WalletType.tron => 'tron',
      _ => 'utxo',
    };
    final chain = switch (wallet.type) {
      WalletType.monero => 'XMR',
      WalletType.solana => 'SOL',
      WalletType.tron => 'TRON',
      _ => wallet.currency.title,
    };
    quote['routes'][0]['memo'] = memo;
    swap['execution'] = {
      'family': family,
      'mode': family == 'utxo' ? 'payment-with-memo' : 'deposit-transfer',
      if (family == 'other') 'chain': chain,
      'to': _target,
      'amount': {
        'display': '1',
        'baseUnits': BigInt.from(10).pow(wallet.currency.decimals).toString()
      },
      'memo': memo,
      if (family == 'utxo') 'gasRate': null,
    };
    if (serialized) {
      wallet.expectedSerialized = encoded ?? Base58Encoder.encode(_solBytes);
      quote['routes'][0]['provider'] = 'openocean';
      swap['route']['provider'] = 'openocean';
      swap['provider'] = {'name': 'openocean', 'referenceId': null, 'details': null};
      swap['execution'] = {
        'family': 'solana',
        'mode': 'serialized-tx',
        'serializedTransaction': wallet.expectedSerialized,
        'encoding': encoding,
        'minOut': null
      };
    }
    final trade = await provider.createTrade(
        request: TradeRequest(
          fromCurrency: wallet.currency,
          toCurrency: CryptoCurrency.eth,
          fromAmount: '1',
          toAddress: _destination,
          senderAddress: _sender,
          refundAddress: _sender,
        ),
        isFixedRateMode: false,
        isSendAll: false);
    await trade.save();
    return trade;
  }

  for (final entry in {
    WalletType.bitcoin: CryptoCurrency.btc,
    WalletType.bitcoinCash: CryptoCurrency.bch,
    WalletType.litecoin: CryptoCurrency.ltc,
    WalletType.dogecoin: CryptoCurrency.doge,
    WalletType.monero: CryptoCurrency.xmr,
    WalletType.solana: CryptoCurrency.sol,
    WalletType.tron: CryptoCurrency.trx,
    WalletType.zcash: CryptoCurrency.zec,
  }.entries) {
    test('${entry.key.name} deposit restores, commits once, notifies truthful hash', () async {
      wallet = _Wallet(entry.key, entry.value);
      final trade = await create();
      final restored = (await Trade.getByTradeId(trade.id))!;
      final first = (await dispatcher.prepare(wallet: wallet, trade: restored))!;
      final second = (await dispatcher.prepare(wallet: wallet, trade: restored))!;
      if (entry.key == WalletType.zcash) expect(first.id, isEmpty);
      await first.commit();
      final stored = (await Trade.getByTradeId(trade.id))!;
      expect(stored.txId, first.id);
      expect(notifiedHash, first.id);
      final lifecycle = TradeExecutionLifecycle.fromJsonString(stored.executionLifecycleJson!);
      expect(lifecycle.state, TradeExecutionLifecycleState.broadcasted);
      if (entry.key == WalletType.zcash) expect(lifecycle.executionHash, isNot(first.id));
      await expectLater(first.commit(), throwsA(isA<PegarouteBindingException>()));
      await expectLater(
          second.commit(), throwsA(anyOf(isA<PegarouteBindingException>(), isA<StateError>())));
      expect(wallet.broadcasts, 1);
    });
  }
  test('UTXO numeric memo is sent as its exact UTF-8 bytes', () async {
    wallet = _Wallet(WalletType.bitcoin, CryptoCurrency.btc)..expectedMemo = '31323334';
    final trade = await create(memo: '1234');
    expect(await dispatcher.prepare(wallet: wallet, trade: trade), isNotNull);
  });
  for (final entry in {
    Base58Encoder.encode(_solBytes): 'base58',
    base64Encode(_solBytes): 'base64',
    BytesUtils.toHexString(_solBytes): 'hex',
    '0x${BytesUtils.toHexString(_solBytes)}': 'hex',
  }.entries) {
    final encoded = entry.key;
    test(
        'OpenOcean serialized Solana ${encoded.substring(0, 4)} is bound, restored and funded once',
        () async {
      wallet = _Wallet(WalletType.solana, CryptoCurrency.sol);
      final trade = await create(serialized: true, encoded: encoded, encoding: entry.value);
      final restored = (await Trade.getByTradeId(trade.id))!;
      expect(TradeExecution.fromJsonString(restored.executionJson!).mode, 'serialized-tx');
      expect(
          TradeExecution.fromJsonString(restored.executionJson!).payload['serializedTransaction'],
          encoded);
      expect(
          TradeExecution.fromJsonString(restored.executionJson!).payload['encoding'], entry.value);
      final pending = (await dispatcher.prepare(wallet: wallet, trade: restored))!;
      await pending.commit();
      expect((await Trade.getByTradeId(trade.id))!.txId, pending.id);
      expect(notifiedHash, pending.id);
      expect(wallet.broadcasts, 1);
    });
  }
  test('SPL deposit preserves mint and decimal identity', () async {
    wallet = _Wallet(
        WalletType.solana,
        SPLToken(
            name: 'USDC',
            symbol: 'USDC',
            mintAddress: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
            mint: 'USDC',
            decimal: 6));
    final trade = await create();
    final restored = (await Trade.getByTradeId(trade.id))!;
    expect(restored.from, isA<SPLToken>());
    final pending = (await dispatcher.prepare(wallet: wallet, trade: restored))!;
    await pending.commit();
    expect(pending.amount.currency, isA<SPLToken>());
  });
  for (final mutation in ['label', 'equivalent reencoding']) {
    test('Solana $mutation cannot replace the prepared raw provider binding', () async {
      wallet = _Wallet(WalletType.solana, CryptoCurrency.sol);
      final trade =
          await create(serialized: true, encoded: base64Encode(_solBytes), encoding: 'base64');
      final pending = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
      final value = jsonDecode(trade.executionJson!) as Map<String, dynamic>;
      (value['payload'] as Map)['encoding'] = 'base58';
      if (mutation == 'equivalent reencoding') {
        (value['payload'] as Map)['serializedTransaction'] = Base58Encoder.encode(_solBytes);
      }
      trade.executionJson = jsonEncode(value);
      await expectLater(pending.commit(), throwsA(isA<PegarouteBindingException>()));
      expect(wallet.broadcasts, 0);
    });
  }

  test('status echo cannot replace bound Solana raw text and label with equivalent bytes',
      () async {
    wallet = _Wallet(WalletType.solana, CryptoCurrency.sol);
    final trade =
        await create(serialized: true, encoded: base64Encode(_solBytes), encoding: 'base64');
    final pending = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    await pending.commit();
    final stored = (await Trade.getByTradeId(trade.id))!;
    serveStatus = true;
    await provider.refreshTradeStatus(trade: stored);
    (swap['execution'] as Map)
      ..['encoding'] = 'base58'
      ..['serializedTransaction'] = Base58Encoder.encode(_solBytes);
    await expectLater(
        provider.refreshTradeStatus(trade: stored), throwsA(isA<PegarouteBindingException>()));
    expect(wallet.broadcasts, 1);
  });
  test('status echo label alone is bound when both codecs decode the same text', () async {
    const wire = 'AQEB'; // Lexically valid Base64 and Base58; no wallet preparation here.
    wallet = _Wallet(WalletType.solana, CryptoCurrency.sol);
    final trade = await create(serialized: true, encoded: wire, encoding: 'base64');
    serveStatus = true;
    statusHash = Base58Encoder.encode(List.filled(64, 1));
    await provider.refreshTradeStatus(trade: trade);
    (swap['execution'] as Map)['encoding'] = 'base58';
    await expectLater(
        provider.refreshTradeStatus(trade: trade),
        throwsA(isA<PegarouteBindingException>()
            .having((e) => e.message, 'reason', 'status execution changed')));
    expect(wallet.broadcasts, 0);
  });

  test('ZEC post-broadcast refresh and callback errors preserve successful payment', () async {
    wallet.postBroadcastFailure = true;
    failCallback = true;
    final trade = await create();
    final pending = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    await pending.commit();
    expect((await Trade.getByTradeId(trade.id))!.txId, 'cd' * 32);
    expect(wallet.broadcasts, 1);
  });
  for (final currency in [CryptoCurrency.zec, CryptoCurrency.sol]) {
    test('${currency.title} status accepts the real hash, never the funding marker or case alias',
        () async {
      wallet =
          _Wallet(currency == CryptoCurrency.zec ? WalletType.zcash : WalletType.solana, currency);
      serveStatus = true;
      final trade = await create();
      final pending = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
      await pending.commit();
      final stored = (await Trade.getByTradeId(trade.id))!;
      final lifecycle = TradeExecutionLifecycle.fromJsonString(stored.executionLifecycleJson!);
      expect(lifecycle.callbackState, TradeExecutionCallbackState.accepted);
      expect(stored.txId, pending.id);
      statusHash =
          currency == CryptoCurrency.zec ? lifecycle.executionHash : pending.id.toLowerCase();
      expect(statusHash, isNot(pending.id));
      await expectLater(
          provider.refreshTradeStatus(trade: stored), throwsA(isA<PegarouteBindingException>()));
      expect((await Trade.getByTradeId(trade.id))!.txId, pending.id);
    });
  }
  test('Solana RPC ID mismatch retains unknown funding and cannot trigger a second send', () async {
    wallet = _Wallet(WalletType.solana, CryptoCurrency.sol)
      ..returnedId = Base58Encoder.encode(List.filled(64, 2));
    final trade =
        await create(serialized: true, encoded: base64Encode(_solBytes), encoding: 'base64');
    final pending = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    await expectLater(pending.commit(), throwsA(isA<PegarouteBindingException>()));
    final stored = (await Trade.getByTradeId(trade.id))!;
    expect(TradeExecutionLifecycle.fromJsonString(stored.executionLifecycleJson!).state,
        TradeExecutionLifecycleState.broadcastUnknown);
    expect(notifiedHash, isNull);
    await expectLater(pending.commit(), throwsA(isA<PegarouteBindingException>()));
    final restoredPending = (await dispatcher.prepare(wallet: wallet, trade: stored))!;
    await expectLater(restoredPending.commit(), throwsStateError);
    expect(wallet.broadcasts, 1);
  });
  test('ZEC ambiguous broadcast keeps an attempt marker and never invents a txid', () async {
    wallet.unknown = true;
    final trade = await create();
    final pending = (await dispatcher.prepare(wallet: wallet, trade: trade))!;
    await expectLater(pending.commit(), throwsA(isA<SocketException>()));
    final stored = (await Trade.getByTradeId(trade.id))!;
    expect(stored.txId, isNull);
    expect(TradeExecutionLifecycle.fromJsonString(stored.executionLifecycleJson!).state,
        TradeExecutionLifecycleState.broadcastUnknown);
    await expectLater(pending.commit(), throwsA(isA<PegarouteBindingException>()));
    expect(wallet.broadcasts, 1);
  });
  test('ZEC exact balance cannot reduce the provider deposit by its fee', () async {
    wallet.exactBalance = true;
    final trade = await create();
    expect(await dispatcher.prepare(wallet: wallet, trade: trade), isNull);
    expect(wallet.builds, 0);
  });
  test('testnet and unsupported ZEC memos cannot create provider orders', () async {
    wallet.walletInfo.network = 'testnet';
    await expectLater(create(), throwsA(isA<PegarouteUnavailableException>()));
    expect(calls, isEmpty);
    wallet.walletInfo.network = 'mainnet';
    await expectLater(create(memo: 'required'), throwsA(isA<PegarouteUnavailableException>()));
    expect(calls, ['GET /quote']);
  });
}

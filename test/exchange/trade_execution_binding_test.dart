import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/spl_token.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/transaction_history.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:http/http.dart' as very_insecure_http_do_not_use;
import 'package:flutter_test/flutter_test.dart';

TradeExecution _execution({
  String tradeId = 'trade-fixture',
  String family = 'evm',
  String mode = 'native-transfer',
  String amount = '1',
  String baseUnits = '1000000000000000000',
  String destination = 'bc1qfixture',
  Map<String, dynamic>? payload,
}) => TradeExecution(
  family: family,
  mode: mode,
  sourceChain: 'ETH',
  sourceToken: 'ETH',
  nativeToken: 'ETH',
  destinationChain: 'BTC',
  destinationToken: 'BTC',
  routeProvider: 'instaswap',
  binding: TradeExecutionBinding(
    tradeId: tradeId,
    providerRaw: 17,
    quoteId: 'quote-fixture',
    quoteExpiresAt: DateTime.utc(2099),
    routeExpiry: null,
    sourceAmount: amount,
    sourceAmountBaseUnits: baseUnits,
    sourceDecimals: 18,
    destinationDecimals: 8,
    senderAddress: '0x0000000000000000000000000000000000000002',
    refundAddress: null,
    destinationAddress: destination,
    isSendAll: false,
    walletId: 'wallet-fixture',
    walletChainId: 1,
    walletAddress: '0x0000000000000000000000000000000000000002',
    reviewedRouteJson:
        '{"provider":"instaswap","providerType":"fixture","subprovider":null,"private":false,"expectedOutput":"0.99","fees":null,"estimatedTimeSeconds":0,"memo":null,"inboundAddress":"0x0000000000000000000000000000000000000001","router":null,"minAmount":null,"expiry":null,"gasRate":null,"resolvedFee":null,"openOceanRoute":null}',
    providerReferenceId: null,
  ),
  payload:
      payload ??
      {
        'chainId': 1,
        'to': '0x0000000000000000000000000000000000000001',
        'data': null,
        'value': {'display': '1', 'baseUnits': baseUnits},
        'gasLimit': null,
        'memo': null,
        'approval': null,
        'transferAmount': null,
      },
);

Trade _trade(TradeExecution execution) => Trade(
  id: execution.binding.tradeId,
  amount: execution.binding.sourceAmount,
  from: CryptoCurrency.eth,
  to: CryptoCurrency.btc,
  provider: ExchangeProviderDescription.pegaroute,
  senderAddress: execution.binding.senderAddress,
  refundAddress: execution.binding.refundAddress,
  payoutAddress: execution.binding.destinationAddress,
  walletId: execution.binding.walletId,
  fromWalletAddress: execution.binding.walletAddress,
  chainId: execution.binding.walletChainId,
  providerName: execution.routeProvider,
  providerId: execution.binding.providerReferenceId,
  isSendAll: false,
  executionJson: execution.encode(),
);

Trade _swapTrade() => Trade(
  id: 'transaction-fixture',
  amount: '1',
  from: CryptoCurrency.eth,
  to: CryptoCurrency.btc,
  provider: ExchangeProviderDescription.pegaroute,
  providerName: 'instaswap',
  walletId: 'wallet-fixture',
  fromWalletAddress: '0x0000000000000000000000000000000000000002',
  chainId: 1,
  senderAddress: '0x0000000000000000000000000000000000000002',
  refundAddress: '0x0000000000000000000000000000000000000003',
  payoutAddress: 'bc1qfixture',
);

Trade _qualifiedTokenTrade({required bool solana}) {
  final source = solana
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
        );
  final sourceChain = solana ? 'SOL' : 'BASE';
  final sourceToken = solana
      ? 'PYTH-HZ1JovNiVvGrGNiiYvEozEVgZ58xaU3RKwX8eACQBCt3'
      : 'SPX-0x50da645f148798f68ef2d7db7c1cb22a6819bb2c';
  final sourceDecimals = solana ? 8 : 18;
  final baseUnits = solana ? '100000000' : '1000000000000000000';
  final destination = solana ? 'sol-deposit' : '0x0000000000000000000000000000000000000001';
  final execution = TradeExecution(
    family: solana ? 'solana' : 'evm',
    mode: solana ? 'deposit-transfer' : 'erc20-transfer',
    sourceChain: sourceChain,
    sourceToken: sourceToken,
    nativeToken: solana ? 'SOL' : 'ETH',
    destinationChain: 'BTC',
    destinationToken: 'BTC',
    routeProvider: 'instaswap',
    binding: TradeExecutionBinding(
      tradeId: 'qualified-token-trade',
      providerRaw: 17,
      quoteId: 'quote-fixture',
      quoteExpiresAt: DateTime.utc(2099),
      routeExpiry: null,
      sourceAmount: '1',
      sourceAmountBaseUnits: baseUnits,
      sourceDecimals: sourceDecimals,
      destinationDecimals: 8,
      senderAddress: solana ? 'sol-sender' : '0x0000000000000000000000000000000000000002',
      refundAddress: null,
      destinationAddress: 'bc1qfixture',
      isSendAll: false,
      walletId: 'wallet-fixture',
      walletChainId: solana ? null : 8453,
      walletAddress: solana ? 'sol-sender' : '0x0000000000000000000000000000000000000002',
      reviewedRouteJson:
          '{"provider":"instaswap","providerType":"fixture","subprovider":null,"private":false,"expectedOutput":"0.99","fees":null,"estimatedTimeSeconds":0,"memo":null,"inboundAddress":"$destination","router":null,"minAmount":null,"expiry":null,"gasRate":null,"resolvedFee":null,"openOceanRoute":null}',
      providerReferenceId: null,
    ),
    payload: solana
        ? {
            'to': destination,
            'amount': {'display': '1', 'baseUnits': baseUnits},
            'memo': null,
          }
        : {
            'chainId': 8453,
            'to': destination,
            'data': null,
            'value': null,
            'gasLimit': null,
            'memo': null,
            'approval': null,
            'transferAmount': {'display': '1', 'baseUnits': baseUnits},
          },
  );
  return Trade(
    id: execution.binding.tradeId,
    amount: '1',
    from: source,
    to: CryptoCurrency.btc,
    provider: ExchangeProviderDescription.pegaroute,
    senderAddress: execution.binding.senderAddress,
    payoutAddress: execution.binding.destinationAddress,
    walletId: execution.binding.walletId,
    fromWalletAddress: execution.binding.walletAddress,
    chainId: execution.binding.walletChainId,
    providerName: 'instaswap',
    executionJson: execution.encode(),
  );
}

class _Addresses implements WalletAddresses {
  @override
  String get address => '0x0000000000000000000000000000000000000002';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Wallet
    extends WalletBase<Balance, TransactionHistoryBase<TransactionInfo>, TransactionInfo> {
  _Wallet()
    : super(
        WalletInfo.external(
          id: 'wallet-fixture',
          name: 'wallet-fixture',
          type: WalletType.ethereum,
          isRecovery: false,
          restoreHeight: 0,
          date: DateTime.utc(2024),
          dirPath: '',
          path: '',
          address: '0x0000000000000000000000000000000000000002',
        ),
        DerivationInfo(),
      ) {
    _walletAddresses = _Addresses();
  }

  @override
  int? get chainId => 1;

  late final WalletAddresses _walletAddresses;

  @override
  WalletAddresses get walletAddresses => _walletAddresses;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<PegarouteValidatedQuote> _quote(PegarouteApiClient client) => client.quote(
  PegarouteQuoteRequest(
    fromChain: 'ETH',
    fromToken: 'ETH',
    toChain: 'BTC',
    toToken: 'BTC',
    amount: '1',
    destinationAddress: 'bc1qfixture',
    senderAddress: '0x0000000000000000000000000000000000000002',
    refundAddress: '0x0000000000000000000000000000000000000003',
  ),
);

PegarouteSwapRequest _request() => PegarouteSwapRequest(
  fromChain: 'ETH',
  fromToken: 'ETH',
  toChain: 'BTC',
  toToken: 'BTC',
  amount: '1',
  destinationAddress: 'bc1qfixture',
  senderAddress: '0x0000000000000000000000000000000000000002',
  refundAddress: '0x0000000000000000000000000000000000000003',
  quoteId: 'quote-fixture',
  routeProvider: 'instaswap',
);

void main() {
  test('validates the complete persisted trade context', () {
    final execution = _execution();
    final validated = const PegarouteExecutionBindingValidator().validatePersisted(
      trade: _trade(execution),
    );
    expect(validated.rawExecutionJson, execution.encode());
    expect(validated.execution.binding.tradeId, 'trade-fixture');
  });

  test('rejects qualified token identity after SQLite reload loses its contract', () {
    for (final solana in [false, true]) {
      final original = _qualifiedTokenTrade(solana: solana);
      expect(
        () => const PegarouteExecutionBindingValidator().validatePersisted(trade: original),
        returnsNormally,
      );
      final reloaded = Trade.fromSqliteRow(original.toSqliteMap()..['tradeId'] = 1);
      expect(
        () => const PegarouteExecutionBindingValidator().validatePersisted(trade: reloaded),
        throwsA(isA<PegarouteBindingException>()),
      );

      final title = solana ? 'PYTH' : 'SPX';
      final tag = solana ? 'SOL' : 'BASE';
      final decimals = solana ? 8 : 18;
      final changedCurrencies = [
        CryptoCurrency(title: 'OTHER', name: 'reloaded-token', tag: tag, decimals: decimals),
        CryptoCurrency(title: title, name: 'reloaded-token', tag: 'WRONG', decimals: decimals),
        CryptoCurrency(title: title, name: 'reloaded-token', tag: tag, decimals: decimals - 1),
      ];
      for (final changedCurrency in changedCurrencies) {
        final changed = Trade.fromSqliteRow(original.toSqliteMap()..['tradeId'] = 1);
        changed.from = changedCurrency;
        expect(
          () => const PegarouteExecutionBindingValidator().validatePersisted(trade: changed),
          throwsA(isA<PegarouteBindingException>()),
        );
      }

      final invalidTyped = solana
          ? SPLToken(
              name: title,
              symbol: title,
              mintAddress: 'invalid-mint',
              decimal: decimals,
              mint: title,
            )
          : Erc20Token(
              name: title,
              symbol: title,
              contractAddress: '0x0000000000000000000000000000000000000001',
              decimal: decimals,
              tag: tag,
            );
      final typedReload = Trade.fromSqliteRow(original.toSqliteMap()..['tradeId'] = 1);
      typedReload.from = invalidTyped;
      expect(
        () => const PegarouteExecutionBindingValidator().validatePersisted(trade: typedReload),
        throwsA(isA<PegarouteBindingException>()),
      );

      final missingIdentity = Trade.fromSqliteRow(original.toSqliteMap()..['tradeId'] = 1);
      missingIdentity.from = CryptoCurrency(
        title: title,
        name: 'reloaded-token',
        tag: null,
        decimals: decimals,
      );
      expect(
        () => const PegarouteExecutionBindingValidator().validatePersisted(trade: missingIdentity),
        throwsA(isA<PegarouteBindingException>()),
      );
    }
  });

  test('rejects each changed persisted identity and amount', () {
    final execution = _execution();
    final validator = const PegarouteExecutionBindingValidator();
    final cases = <Trade Function(Trade)>[
      (trade) => trade..id = 'different-trade',
      (trade) => trade..providerRaw = 16,
      (trade) => trade..amount = '1.1',
      (trade) => trade..senderAddress = '0x0000000000000000000000000000000000000003',
      (trade) => trade..refundAddress = 'refund',
      (trade) => trade..payoutAddress = 'different-destination',
      (trade) => trade..walletId = 'different-wallet',
      (trade) => trade..providerName = 'thorchain',
      (trade) => trade..providerName = null,
      (trade) => trade..fromWalletAddress = null,
    ];
    for (final mutate in cases) {
      final trade = mutate(_trade(execution));
      expect(
        () => validator.validatePersisted(trade: trade),
        throwsA(isA<PegarouteBindingException>()),
      );
    }
  });

  test('rejects non-canonical or mismatched source amounts', () {
    expect(() => _execution(amount: '1.0000000000000000001'), throwsFormatException);

    expect(() => _execution(baseUnits: '1000000000000000001'), throwsFormatException);
  });

  test('rejects family, chain, native value, and approval contradictions', () {
    final validator = const PegarouteExecutionBindingValidator();
    final cases = <TradeExecution>[
      _execution(
        payload: {
          'chainId': 56,
          'to': '0x0000000000000000000000000000000000000001',
          'data': null,
          'value': {'display': '1', 'baseUnits': '1000000000000000000'},
          'gasLimit': null,
          'memo': null,
          'approval': null,
          'transferAmount': null,
        },
      ),
      _execution(
        payload: {
          'chainId': 1,
          'to': '0x0000000000000000000000000000000000000001',
          'data': null,
          'value': {'display': '2', 'baseUnits': '2000000000000000000'},
          'gasLimit': null,
          'memo': null,
          'approval': null,
          'transferAmount': null,
        },
      ),
      _execution(
        family: 'utxo',
        mode: 'payment-with-memo',
        payload: {
          'to': 'destination',
          'amount': {'display': '1', 'baseUnits': '1000000000000000000'},
          'memo': null,
          'gasRate': null,
        },
      ),
      _execution(
        mode: 'contract-call',
        payload: {
          'chainId': 1,
          'to': '0x0000000000000000000000000000000000000001',
          'data': '0xdeadbeef',
          'value': null,
          'gasLimit': null,
          'memo': null,
          'approval': {
            'spender': '0x0000000000000000000000000000000000000004',
            'tokenAddress': '0x0000000000000000000000000000000000000005',
            'amount': {'display': '1', 'baseUnits': '1000000000000000000'},
          },
          'transferAmount': null,
        },
      ),
    ];
    for (final execution in cases) {
      expect(
        () => validator.validatePersisted(trade: _trade(execution)),
        throwsA(isA<PegarouteBindingException>()),
      );
    }
  });

  test('rejects token contract calls without a decoded debit proof', () {
    final trade = _qualifiedTokenTrade(solana: false);
    final raw = json.decode(trade.executionJson!) as Map<String, dynamic>;
    raw['mode'] = 'contract-call';
    raw['payload'] = {
      'chainId': 8453,
      'to': '0x0000000000000000000000000000000000000001',
      'data': '0xdeadbeef',
      'value': {'display': '0', 'baseUnits': '0'},
      'gasLimit': null,
      'memo': null,
      'approval': {
        'spender': '0x0000000000000000000000000000000000000001',
        'tokenAddress': '0x50da645f148798f68ef2d7db7c1cb22a6819bb2c',
        'amount': {'display': '1', 'baseUnits': '1000000000000000000'},
      },
      'transferAmount': null,
    };
    final tampered = TradeExecution.fromJson(raw);
    trade.executionJson = tampered.encode();
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(trade: trade),
      throwsA(isA<PegarouteBindingException>()),
    );
  });

  test('rejects persisted target and memo changes against the reviewed route', () {
    for (final change in [
      (Map<String, dynamic> route, Map<String, dynamic> payload) {
        payload['to'] = '0x0000000000000000000000000000000000000004';
      },
      (Map<String, dynamic> route, Map<String, dynamic> payload) {
        route['memo'] = 'unexpected-memo';
      },
    ]) {
      final execution = _execution();
      final raw = json.decode(execution.encode()) as Map<String, dynamic>;
      final binding = raw['binding'] as Map<String, dynamic>;
      final route = json.decode(binding['reviewedRouteJson'] as String) as Map<String, dynamic>;
      final payload = raw['payload'] as Map<String, dynamic>;
      change(route, payload);
      binding['reviewedRouteJson'] = json.encode(route);
      final tampered = TradeExecution.fromJson(raw);
      expect(
        () => const PegarouteExecutionBindingValidator().validatePersisted(trade: _trade(tampered)),
        throwsA(isA<PegarouteBindingException>()),
      );
    }
  });

  test('matches string private route identities exactly', () {
    final raw = json.decode(_execution().encode()) as Map<String, dynamic>;
    final binding = raw['binding'] as Map<String, dynamic>;
    final route = json.decode(binding['reviewedRouteJson'] as String) as Map<String, dynamic>;
    route['private'] = 'private-fixture';
    binding['reviewedRouteJson'] = json.encode(route);
    raw['privateIntent'] = 'private-fixture';
    final valid = TradeExecution.fromJson(raw);
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(trade: _trade(valid)),
      returnsNormally,
    );

    raw['privateIntent'] = 'different-private-fixture';
    final changed = TradeExecution.fromJson(raw);
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(trade: _trade(changed)),
      throwsA(isA<PegarouteBindingException>()),
    );
  });

  test('binds persisted provider deposits to execution and reviewed inbound', () {
    final raw = json.decode(_execution().encode()) as Map<String, dynamic>;
    final binding = raw['binding'] as Map<String, dynamic>;
    binding['providerDepositAddress'] = '0x0000000000000000000000000000000000000001';
    final valid = TradeExecution.fromJson(raw);
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(trade: _trade(valid)),
      returnsNormally,
    );

    binding['providerDepositAddress'] = '0x0000000000000000000000000000000000000004';
    final changed = TradeExecution.fromJson(raw);
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(trade: _trade(changed)),
      throwsA(isA<PegarouteBindingException>()),
    );
  });

  test('rejects a changed exact raw execution snapshot', () {
    final execution = _execution();
    final trade = _trade(execution);
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(
        trade: trade,
        expectedRawExecutionJson: '${execution.encode()} ',
      ),
      throwsA(isA<PegarouteBindingException>()),
    );
  });

  test('requires quote expiry before future swap creation', () async {
    final value =
        json.decode(File('test/exchange/fixtures/pegaroute/quote.json').readAsStringSync())
            as Map<String, dynamic>;
    value['expiresAt'] = '2099-01-01T00:00:00.000Z';
    final quote =
        await PegarouteApiClient(
          configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
          get: (uri, headers) async =>
              very_insecure_http_do_not_use.Response(json.encode(value), 200),
        ).quote(
          PegarouteQuoteRequest(
            fromChain: 'ETH',
            fromToken: 'ETH',
            toChain: 'BTC',
            toToken: 'BTC',
            amount: '1',
            destinationAddress: 'bc1qfixture',
            senderAddress: '0x0000000000000000000000000000000000000002',
          ),
        );
    final route = quote.response.routes.single;
    final request = PegarouteSwapRequest(
      fromChain: 'ETH',
      fromToken: 'ETH',
      toChain: 'BTC',
      toToken: 'BTC',
      amount: '1',
      destinationAddress: 'bc1qfixture',
      senderAddress: '0x0000000000000000000000000000000000000002',
      routeProvider: 'instaswap',
    );
    const validator = PegarouteExecutionBindingValidator();
    expect(
      () => validator.validateQuotePreflight(
        quote: quote,
        route: route,
        request: request,
        at: DateTime.utc(2098),
      ),
      returnsNormally,
    );
    expect(
      () => validator.validateQuotePreflight(
        quote: quote,
        route: route,
        request: request,
        at: DateTime.utc(2100),
      ),
      throwsA(isA<PegarouteBindingException>()),
    );
  });

  test('preserves and validates typed route expiry without creating a dispatch deadline', () {
    final expiry = TradeExecutionExpiry.fromProviderValue(4102444800);
    expect(expiry.kind, TradeExecutionExpiryKind.unixSeconds);
    expect(expiry.instant().year, 2100);
    expect(TradeExecutionExpiry.fromJson(expiry.toJson()).instant(), expiry.instant());
  });

  test('preflights complete swap context before API I/O and binds after quote expiry', () async {
    Map<String, dynamic>? responseValue;
    var calls = 0;
    String? sentBody;
    final client = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
      get: (uri, headers) async => very_insecure_http_do_not_use.Response(
        File('test/exchange/fixtures/pegaroute/quote.json').readAsStringSync(),
        200,
      ),
      post: (uri, headers, body) async {
        calls++;
        sentBody = body;
        return very_insecure_http_do_not_use.Response(json.encode(responseValue), 202);
      },
      clock: () => DateTime.utc(2026, 8, 31),
    );
    final quote = await _quote(client);
    final route = quote.response.routes.single;
    final trade = _swapTrade();
    PegarouteValidatedSwapPreflight preflight() =>
        const PegarouteExecutionBindingValidator().preflightSwap(
          trade: trade,
          wallet: _Wallet(),
          quote: quote,
          route: route,
          request: _request(),
          at: DateTime.utc(2026, 8, 31),
        );
    final firstPreflight = preflight();
    final value =
        json.decode(File('test/exchange/fixtures/pegaroute/swap.json').readAsStringSync())
            as Map<String, dynamic>;
    ((value['execution'] as Map<String, dynamic>)['value'] as Map<String, dynamic>)['baseUnits'] =
        '1000000000000000000';
    Future<PegarouteValidatedSwapResult> postResult(Map<String, dynamic> response) {
      responseValue = response;
      return client.swap(preflight());
    }

    final result = await postResult(value);
    expect(result.preflight.requestJson, firstPreflight.requestJson);
    expect(result.response.transactionId, 'transaction-fixture');
    final execution = const PegarouteExecutionBindingValidator().bindSwapResponse(result: result);
    expect(execution.binding.quoteId, 'quote-fixture');
    expect(execution.binding.reviewedRouteJson, isNotEmpty);

    final mixedCapabilities = json.decode(json.encode(value)) as Map<String, dynamic>;
    (mixedCapabilities['route'] as Map<String, dynamic>)['private'] = 'post-only-private';
    await expectLater(
      postResult(mixedCapabilities).then(
        (result) => const PegarouteExecutionBindingValidator().bindSwapResponse(result: result),
      ),
      throwsA(isA<PegarouteBindingException>()),
    );

    final routeChanged = json.decode(json.encode(value)) as Map<String, dynamic>;
    (routeChanged['route'] as Map<String, dynamic>)['expectedOutput'] = '0.50';
    await expectLater(
      postResult(routeChanged).then(
        (result) => const PegarouteExecutionBindingValidator().bindSwapResponse(result: result),
      ),
      throwsA(isA<PegarouteBindingException>()),
    );

    final omittedRouteIdentity = json.decode(json.encode(value)) as Map<String, dynamic>;
    (omittedRouteIdentity['route'] as Map<String, dynamic>).remove('subprovider');
    await expectLater(
      postResult(omittedRouteIdentity).then(
        (result) => const PegarouteExecutionBindingValidator().bindSwapResponse(result: result),
      ),
      throwsA(isA<PegarouteBindingException>()),
    );

    final opaqueResponse = json.decode(json.encode(value)) as Map<String, dynamic>;
    opaqueResponse['execution'] = {
      'family': 'solana',
      'mode': 'serialized-tx',
      'serializedTransaction': '3MN',
      'minOut': null,
    };
    await expectLater(
      postResult(opaqueResponse).then(
        (result) => const PegarouteExecutionBindingValidator().bindSwapResponse(result: result),
      ),
      throwsA(isA<PegarouteBindingException>()),
    );

    calls = 0;
    sentBody = null;
    (value['route'] as Map<String, dynamic>)['expectedOutput'] = '0.01';
    final requestCopy = json.decode(firstPreflight.requestJson) as Map<String, dynamic>;
    requestCopy['amount'] = '9';
    responseValue = value;
    final exactPreflight = preflight();
    await client.swap(exactPreflight);
    expect(calls, 1);
    expect(sentBody, exactPreflight.requestJson);

    var staleCalls = 0;
    final staleClient = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
      post: (uri, headers, body) async {
        staleCalls++;
        fail('expired preflight must not perform POST');
      },
      clock: () => DateTime.utc(2026, 9, 2),
    );
    await expectLater(staleClient.swap(preflight()), throwsA(isA<PegarouteBindingException>()));
    expect(staleCalls, 0);
  });

  test('binds quote, preflight, and result to one client and origin', () async {
    var clientPosts = 0;
    var foreignPosts = 0;
    final swapJson = File('test/exchange/fixtures/pegaroute/swap.json').readAsStringSync();
    final configuration = const PegarouteConfiguration(baseUrl: 'https://example.test');
    final client = PegarouteApiClient(
      configuration: configuration,
      get: (uri, headers) async => very_insecure_http_do_not_use.Response(
        File('test/exchange/fixtures/pegaroute/quote.json').readAsStringSync(),
        200,
      ),
      post: (uri, headers, body) async {
        clientPosts++;
        return very_insecure_http_do_not_use.Response(swapJson, 202);
      },
      clock: () => DateTime.utc(2026, 8, 31),
    );
    final foreignClient = PegarouteApiClient(
      configuration: configuration,
      post: (uri, headers, body) async {
        foreignPosts++;
        return very_insecure_http_do_not_use.Response(swapJson, 202);
      },
      clock: () => DateTime.utc(2026, 8, 31),
    );
    final foreignOriginClient = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://other.example.test'),
      post: (uri, headers, body) async {
        fail('foreign origin must not perform POST');
      },
      clock: () => DateTime.utc(2026, 8, 31),
    );
    final quote = await _quote(client);
    expect(quote.isBoundTo(client), isTrue);
    expect(quote.isBoundTo(foreignClient), isFalse);

    final preflight = const PegarouteExecutionBindingValidator().preflightSwap(
      trade: _swapTrade(),
      wallet: _Wallet(),
      quote: quote,
      route: quote.response.routes.single,
      request: _request(),
      at: DateTime.utc(2026, 8, 31),
    );
    expect(preflight.isBoundTo(client), isTrue);
    expect(preflight.isBoundTo(foreignClient), isFalse);
    await expectLater(foreignClient.swap(preflight), throwsA(isA<PegarouteBindingException>()));
    await expectLater(
      foreignOriginClient.swap(preflight),
      throwsA(isA<PegarouteBindingException>()),
    );
    expect(clientPosts, 0);
    expect(foreignPosts, 0);

    final result = await client.swap(preflight);
    expect(result.isBoundTo(client), isTrue);
    expect(result.isBoundTo(foreignClient), isFalse);
    expect(clientPosts, 1);
    await expectLater(client.swap(preflight), throwsA(isA<PegarouteBindingException>()));
    expect(clientPosts, 1);
  });

  test('consumes preflight before provider, timeout, and ambiguous failures', () async {
    final outcomes = <Future<very_insecure_http_do_not_use.Response> Function()>[
      () async => very_insecure_http_do_not_use.Response(
        json.encode({
          'error': {
            'code': 'PROVIDER_FAILED',
            'message': 'failed',
            'userMessage': 'failed',
            'retryable': false,
          },
        }),
        502,
      ),
      () async => throw TimeoutException('fixture timeout'),
      () async => throw StateError('ambiguous fixture failure'),
    ];

    for (final outcome in outcomes) {
      var posts = 0;
      final client = PegarouteApiClient(
        configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
        get: (uri, headers) async => very_insecure_http_do_not_use.Response(
          File('test/exchange/fixtures/pegaroute/quote.json').readAsStringSync(),
          200,
        ),
        post: (uri, headers, body) {
          posts++;
          return outcome();
        },
        clock: () => DateTime.utc(2026, 8, 31),
      );
      final quote = await _quote(client);
      final preflight = const PegarouteExecutionBindingValidator().preflightSwap(
        trade: _swapTrade(),
        wallet: _Wallet(),
        quote: quote,
        route: quote.response.routes.single,
        request: _request(),
        at: DateTime.utc(2026, 8, 31),
      );
      await expectLater(client.swap(preflight), throwsA(anything));
      await expectLater(client.swap(preflight), throwsA(isA<PegarouteBindingException>()));
      expect(posts, 1);
    }
  });

  test('rejects malformed reviewed route fields and one-copy expiry tampering', () {
    final execution = _execution();
    final raw = json.decode(execution.encode()) as Map<String, dynamic>;
    final binding = raw['binding'] as Map<String, dynamic>;
    final route = json.decode(binding['reviewedRouteJson'] as String) as Map<String, dynamic>;
    route['estimatedTimeSeconds'] = 'not-a-number';
    binding['reviewedRouteJson'] = json.encode(route);
    final malformed = TradeExecution.fromJson(raw);
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(trade: _trade(malformed)),
      throwsA(isA<PegarouteBindingException>()),
    );

    final expiryRaw = json.decode(execution.encode()) as Map<String, dynamic>;
    (expiryRaw['binding'] as Map<String, dynamic>)['routeExpiry'] = {
      'kind': 'unixSeconds',
      'value': 4102444800,
    };
    final expiryTampered = TradeExecution.fromJson(expiryRaw);
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(
        trade: _trade(expiryTampered),
      ),
      throwsA(isA<PegarouteBindingException>()),
    );
  });

  test('raw requests cannot cross the swap API boundary', () {
    final dynamic client = PegarouteApiClient(
      configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
    );
    expect(() => client.swap(_request()), throwsA(isA<TypeError>()));
  });

  test('rejects expired or mismatched swap preflight without API I/O', () async {
    final quote = await _quote(
      PegarouteApiClient(
        configuration: const PegarouteConfiguration(baseUrl: 'https://example.test'),
        get: (uri, headers) async => very_insecure_http_do_not_use.Response(
          File('test/exchange/fixtures/pegaroute/quote.json').readAsStringSync(),
          200,
        ),
      ),
    );
    final route = quote.response.routes.single;
    final trade = _swapTrade();
    expect(
      () => const PegarouteExecutionBindingValidator().preflightSwap(
        trade: trade,
        wallet: _Wallet(),
        quote: quote,
        route: route,
        request: _request(),
        at: DateTime.utc(2026, 9, 2),
      ),
      throwsA(isA<PegarouteBindingException>()),
    );
    expect(
      () => const PegarouteExecutionBindingValidator().preflightSwap(
        trade: trade,
        wallet: _Wallet(),
        quote: quote,
        route: route,
        request: PegarouteSwapRequest(
          fromChain: 'BSC',
          fromToken: 'BNB',
          toChain: 'BTC',
          toToken: 'BTC',
          amount: '1',
          destinationAddress: 'bc1qfixture',
          senderAddress: '0x0000000000000000000000000000000000000002',
          quoteId: 'quote-fixture',
          routeProvider: 'instaswap',
        ),
        at: DateTime.utc(2026, 8, 31),
      ),
      throwsA(isA<PegarouteBindingException>()),
    );
  });
}

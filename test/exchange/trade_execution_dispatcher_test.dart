import 'dart:async';

import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/transaction_history.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:flutter_test/flutter_test.dart';

TradeExecutionBinding _binding() => TradeExecutionBinding(
      tradeId: 'trade',
      providerRaw: 17,
      quoteId: 'quote',
      quoteExpiresAt: DateTime.utc(2099),
      routeExpiry: null,
      sourceAmount: '1',
      sourceAmountBaseUnits: '1000000000000',
      sourceDecimals: 12,
      senderAddress: 'sender',
      refundAddress: null,
      destinationAddress: 'destination',
      isSendAll: false,
      walletId: 'wallet',
      walletChainId: null,
      walletAddress: 'sender',
      reviewedRouteJson:
          '{"provider":"instaswap","providerType":"fixture","subprovider":null,"private":false,"expectedOutput":"0.99","fees":null,"estimatedTimeSeconds":0,"memo":null,"inboundAddress":"destination","router":null,"minAmount":null,"expiry":null,"gasRate":null,"resolvedFee":null,"openOceanRoute":null}',
      providerReferenceId: null,
    );

TradeExecution _execution() => TradeExecution(
      family: 'other',
      mode: 'deposit-transfer',
      sourceChain: 'XMR',
      sourceToken: 'XMR',
      nativeToken: 'XMR',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      binding: _binding(),
      routeProvider: 'instaswap',
      payload: const {
        'chain': 'XMR',
        'to': 'destination',
        'amount': {'display': '1', 'baseUnits': '1000000000000'},
        'memo': null,
      },
    );

class _Handler implements TradeExecutionHandler {
  _Handler(
    this.external, {
    this.mutateDuringCommit = false,
    this.prepareCompleter,
    this.throwOnCommitted = false,
    this.ignoreGuard = false,
  });

  final bool external;
  final bool mutateDuringCommit;
  final Completer<void>? prepareCompleter;
  final bool throwOnCommitted;
  final bool ignoreGuard;
  int prepareCalls = 0;
  int validationCalls = 0;
  int validationsAfterConstruction = 0;
  int commitHookCalls = 0;
  bool constructionStarted = false;
  late Trade trade;
  late _Pending pending;

  @override
  bool supports(TradeExecution execution) => true;

  @override
  bool supportsExternalSend(TradeExecution execution) => external;

  @override
  void validateForExecution({
    required ValidatedTradeExecution execution,
    required DateTime now,
  }) {
    validationCalls++;
    if (constructionStarted) validationsAfterConstruction++;
  }

  @override
  Future<GuardedPendingTransaction?> prepare({
    required TradeExecutionGuard guard,
  }) async {
    if (ignoreGuard) return _prepared() as dynamic;
    return guard.withWalletConstruction((wallet, execution) async {
      if (prepareCompleter != null) await prepareCompleter!.future;
      constructionStarted = true;
      return _prepared();
    });
  }

  @override
  Future<void> onCommitted({
    required ValidatedTradeExecution execution,
    required CommittedTradeExecution receipt,
  }) async {
    commitHookCalls++;
    if (throwOnCommitted) throw StateError('callback failed');
  }

  PendingTransaction _prepared() {
    prepareCalls++;
    pending = _Pending(
      onCommit: mutateDuringCommit ? () => trade.amount = '2' : null,
    );
    return pending;
  }
}

class _Addresses implements WalletAddresses {
  @override
  String get address => 'sender';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Wallet
    extends WalletBase<Balance, TransactionHistoryBase<TransactionInfo>, TransactionInfo> {
  _Wallet()
      : super(
          WalletInfo.external(
            id: 'wallet',
            name: 'wallet',
            type: WalletType.ethereum,
            isRecovery: false,
            restoreHeight: 0,
            date: DateTime.utc(2024),
            dirPath: '',
            path: '',
            address: 'sender',
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

class _Pending with PendingTransaction {
  _Pending({this.onCommit});

  final void Function()? onCommit;
  int commits = 0;
  int urCommits = 0;

  @override
  String get id => 'pending';

  @override
  Money get amount => Money.zero(CryptoCurrency.eth);

  @override
  Money get fee => Money.zero(CryptoCurrency.eth);

  @override
  String get amountFormatted => '0';

  @override
  String get hex => '';

  @override
  Future<void> commit() async {
    commits++;
    onCommit?.call();
  }

  @override
  Future<Map<String, String>> commitUR() async {
    urCommits++;
    return {};
  }
}

void main() {
  test('empty Phase 1 dispatcher supports and prepares nothing', () async {
    const dispatcher = EmptyTradeExecutionDispatcher();
    final execution = _execution();
    expect(dispatcher.supports(execution), isFalse);
    expect(dispatcher.supportsExternalSend(execution), isFalse);
  });

  test('registry rejects zero and multiple matches without using order', () {
    final execution = _execution();
    expect(RegistryTradeExecutionDispatcher(const []).supports(execution), isFalse);
    expect(
      RegistryTradeExecutionDispatcher([_Handler(true), _Handler(true)]).supports(execution),
      isFalse,
    );
    expect(
      RegistryTradeExecutionDispatcher([_Handler(true), _Handler(false)])
          .supportsExternalSend(execution),
      isFalse,
    );
    expect(
      RegistryTradeExecutionDispatcher([_Handler(true)]).supportsExternalSend(execution),
      isTrue,
    );
  });

  test('validates before prepare and guards commit while disabling commitUR', () async {
    final execution = _execution();
    final trade = Trade(
      id: 'trade',
      amount: '1',
      from: CryptoCurrency.xmr,
      to: CryptoCurrency.btc,
      provider: ExchangeProviderDescription.pegaroute,
      senderAddress: 'sender',
      payoutAddress: 'destination',
      walletId: 'wallet',
      fromWalletAddress: 'sender',
      providerName: 'instaswap',
      executionJson: execution.encode(),
    );
    final handler = _Handler(false);
    final dispatcher = RegistryTradeExecutionDispatcher([handler]);
    final wallet = _Wallet();
    expect(
      () => const PegarouteExecutionBindingValidator().validatePersisted(
        trade: trade,
        wallet: wallet,
      ),
      returnsNormally,
    );
    final pending = await dispatcher.prepare(wallet: wallet, trade: trade);
    expect(pending, isNotNull);
    expect(handler.prepareCalls, 1);
    expect(handler.validationCalls, greaterThanOrEqualTo(3));
    expect(handler.validationsAfterConstruction, greaterThanOrEqualTo(1));

    trade.amount = '2';
    await expectLater(pending!.commit(), throwsA(isA<PegarouteBindingException>()));
    expect(handler.pending.commits, 0);

    trade.amount = '1';
    final validPending = await dispatcher.prepare(wallet: wallet, trade: trade);
    await validPending!.commit();
    expect(handler.commitHookCalls, 1);

    final urPending = await dispatcher.prepare(wallet: wallet, trade: trade);
    trade.amount = '2';
    await expectLater(urPending!.commitUR(), throwsA(isA<PegarouteBindingException>()));
    expect(handler.pending.urCommits, 0);
    trade.amount = '1';
    final validUrPending = await dispatcher.prepare(wallet: wallet, trade: trade);
    expect(validUrPending!.shouldCommitUR(), isFalse);
    await expectLater(validUrPending.commitUR(), throwsA(isA<PegarouteBindingException>()));
    expect(handler.pending.urCommits, 0);
    expect(handler.commitHookCalls, 1);
  });

  test('raw pending transactions cannot satisfy guarded preparation', () async {
    final execution = _execution();
    final trade = Trade(
      id: 'trade',
      amount: '1',
      from: CryptoCurrency.xmr,
      to: CryptoCurrency.btc,
      provider: ExchangeProviderDescription.pegaroute,
      senderAddress: 'sender',
      payoutAddress: 'destination',
      walletId: 'wallet',
      fromWalletAddress: 'sender',
      providerName: 'instaswap',
      executionJson: execution.encode(),
    );
    final handler = _Handler(false, ignoreGuard: true);
    final pending = await RegistryTradeExecutionDispatcher([handler]).prepare(
      wallet: _Wallet(),
      trade: trade,
    );
    expect(pending, isNull);
    expect(handler.pending.commits, 0);
    expect(handler.pending.urCommits, 0);
  });

  test('suppresses post-broadcast hook when context changes during commit', () async {
    final execution = _execution();
    final trade = Trade(
      id: 'trade',
      amount: '1',
      from: CryptoCurrency.xmr,
      to: CryptoCurrency.btc,
      provider: ExchangeProviderDescription.pegaroute,
      senderAddress: 'sender',
      payoutAddress: 'destination',
      walletId: 'wallet',
      fromWalletAddress: 'sender',
      providerName: 'instaswap',
      executionJson: execution.encode(),
    );
    final handler = _Handler(false, mutateDuringCommit: true)..trade = trade;
    final wallet = _Wallet();
    final pending = await RegistryTradeExecutionDispatcher([handler]).prepare(
      wallet: wallet,
      trade: trade,
    );
    await pending!.commit();
    expect(handler.commitHookCalls, 0);
  });

  test('rejects stale context after delayed prepare without returning a wrapper', () async {
    final execution = _execution();
    final trade = Trade(
      id: 'trade',
      amount: '1',
      from: CryptoCurrency.xmr,
      to: CryptoCurrency.btc,
      provider: ExchangeProviderDescription.pegaroute,
      senderAddress: 'sender',
      payoutAddress: 'destination',
      walletId: 'wallet',
      fromWalletAddress: 'sender',
      providerName: 'instaswap',
      executionJson: execution.encode(),
    );
    final completer = Completer<void>();
    final handler = _Handler(false, prepareCompleter: completer)..trade = trade;
    final wallet = _Wallet();
    final pendingFuture = RegistryTradeExecutionDispatcher([handler]).prepare(
      wallet: wallet,
      trade: trade,
    );
    trade.amount = '2';
    completer.complete();
    final pending = await pendingFuture;
    expect(pending, isNull);
    expect(handler.prepareCalls, 1);
    expect(handler.pending.commits, 0);
  });

  test('returns successful commit when post-commit callback fails', () async {
    final execution = _execution();
    final trade = Trade(
      id: 'trade',
      amount: '1',
      from: CryptoCurrency.xmr,
      to: CryptoCurrency.btc,
      provider: ExchangeProviderDescription.pegaroute,
      senderAddress: 'sender',
      payoutAddress: 'destination',
      walletId: 'wallet',
      fromWalletAddress: 'sender',
      providerName: 'instaswap',
      executionJson: execution.encode(),
    );
    final handler = _Handler(false, throwOnCommitted: true)..trade = trade;
    final pending = await RegistryTradeExecutionDispatcher([handler]).prepare(
      wallet: _Wallet(),
      trade: trade,
    );
    await pending!.commit();
    expect(handler.pending.commits, 1);
    expect(handler.commitHookCalls, 1);
  });
}

import 'dart:async';

import 'package:cake_wallet/core/amount_parsing_proxy.dart';
import 'package:cake_wallet/core/address_resolver/address_resolver_service.dart';
import 'package:cake_wallet/core/execution_state.dart';
import 'package:cake_wallet/entities/bitcoin_amount_display_mode.dart';
import 'package:cake_wallet/entities/transaction_description.dart';
import 'package:cake_wallet/entities/fiat_currency.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cake_wallet/store/app_store.dart';
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cake_wallet/view_model/contact_list/contact_list_view_model.dart';
import 'package:cake_wallet/view_model/dashboard/balance_view_model.dart';
import 'package:cake_wallet/view_model/send/fees_view_model.dart';
import 'package:cake_wallet/view_model/send/send_template_view_model.dart';
import 'package:cake_wallet/view_model/send/send_view_model.dart';
import 'package:cake_wallet/view_model/send/send_view_model_state.dart';
import 'package:cake_wallet/view_model/unspent_coins/unspent_coins_list_view_model.dart';
import 'package:cake_wallet/store/dashboard/fiat_conversion_store.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/transaction_history.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobx/mobx.dart' show ObservableMap;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AppStore extends Mock implements AppStore {}

class _SettingsStore extends Mock implements SettingsStore {}

class _Wallet extends Mock
    implements WalletBase<Balance, TransactionHistoryBase<TransactionInfo>, TransactionInfo> {}

class _WalletAddresses extends Mock implements WalletAddresses {}

class _Balance extends Balance {
  _Balance() : super(Money.zero(CryptoCurrency.zec), Money.zero(CryptoCurrency.zec));
}

class _AddressResolverService extends Mock implements AddressResolverService {}

class _BalanceViewModel extends Mock implements BalanceViewModel {}

class _ContactListViewModel extends Mock implements ContactListViewModel {}

class _FeesViewModel extends Mock implements FeesViewModel {}

class _SendTemplateViewModel extends Mock implements SendTemplateViewModel {}

class _UnspentCoinsListViewModel extends Mock implements UnspentCoinsListViewModel {}

class _DescriptionBox extends Mock implements Box<TransactionDescription> {}

class _TransactionDescriptionFake extends Fake implements TransactionDescription {}

class _Context extends Mock implements BuildContext {}

class _PendingTransaction with PendingTransaction {
  _PendingTransaction({
    this.id = 'transaction-id',
    this.commitError,
    this.onCommit,
    this.commitStarted,
    this.releaseCommit,
    this.commitUr = false,
  });

  final String id;
  final Object? commitError;
  final void Function()? onCommit;
  final Completer<void>? commitStarted;
  final Completer<void>? releaseCommit;
  final bool commitUr;
  int commits = 0;
  int urCommits = 0;

  @override
  Money get amount => Money.zero(CryptoCurrency.zec);

  @override
  Money get fee => Money.zero(CryptoCurrency.zec);

  @override
  String get amountFormatted => '0';

  @override
  String get hex => '';

  @override
  Future<void> commit() async {
    commits++;
    onCommit?.call();
    commitStarted?.complete();
    if (releaseCommit != null) await releaseCommit!.future;
    if (commitError != null) throw commitError!;
  }

  @override
  bool shouldCommitUR() => commitUr;

  @override
  Future<Map<String, String>> commitUR() async {
    urCommits++;
    return {};
  }
}

class _ApprovalTransaction extends _PendingTransaction implements TradeExecutionStage {
  _ApprovalTransaction({super.commitError});
  @override
  String get prerequisiteDescription => 'Approve 1 USDC';
}

class _NextStepDispatcher extends EmptyTradeExecutionDispatcher {
  _NextStepDispatcher(this.next);
  final PendingTransaction next;
  int preparations = 0;
  @override
  bool supports(TradeExecution execution) => true;
  @override
  Future<PendingTransaction?> prepare({required WalletBase wallet, required Trade trade}) async {
    preparations++;
    return next;
  }
}

// The mocked dispatcher isolates UI stage transitions; bound approval/SQLite
// execution is covered by pegaroute_native_eth_flow_test.dart.
Trade _stageTrade() => Trade(
    id: 'trade-id',
    amount: '1',
    provider: ExchangeProviderDescription.pegaroute,
    executionJson: TradeExecution(
      family: 'other',
      mode: 'deposit-transfer',
      sourceChain: 'XMR',
      sourceToken: 'XMR',
      nativeToken: 'XMR',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      routeProvider: 'instaswap',
      payload: const {
        'chain': 'XMR',
        'to': 'deposit',
        'memo': null,
        'amount': {'display': '1', 'baseUnits': '1000000000000'}
      },
      binding: TradeExecutionBinding(
          tradeId: 'trade-id',
          providerRaw: 17,
          quoteId: 'quote',
          quoteExpiresAt: DateTime.utc(2099),
          routeExpiry: null,
          sourceAmount: '1',
          sourceAmountBaseUnits: '1000000000000',
          sourceDecimals: 12,
          destinationDecimals: 8,
          senderAddress: 'sender',
          refundAddress: null,
          destinationAddress: 'destination',
          isSendAll: false,
          walletId: 'wallet',
          walletChainId: null,
          walletAddress: 'sender',
          reviewedRouteJson: '{}',
          providerReferenceId: null),
    ).encode());

SendViewModel _viewModel({
  required _DescriptionBox descriptionBox,
  required _PendingTransaction pending,
  bool saveRecipient = false,
  TradeExecutionDispatcher dispatcher = const EmptyTradeExecutionDispatcher(),
}) {
  final appStore = _AppStore();
  final settingsStore = _SettingsStore();
  final wallet = _Wallet();
  final walletAddresses = _WalletAddresses();
  final balance = ObservableMap<CryptoCurrency, Balance>()..[CryptoCurrency.zec] = _Balance();

  when(() => appStore.wallet).thenReturn(wallet);
  when(() => appStore.settingsStore).thenReturn(settingsStore);
  when(() => appStore.amountParsingProxy)
      .thenReturn(const AmountParsingProxy(BitcoinAmountDisplayMode.bitcoin));
  when(() => settingsStore.fiatCurrency).thenReturn(FiatCurrency.usd);
  when(() => settingsStore.shouldSaveRecipientAddress).thenReturn(saveRecipient);

  when(() => wallet.type).thenReturn(WalletType.zcash);
  when(() => wallet.currency).thenReturn(CryptoCurrency.zec);
  when(() => wallet.chainId).thenReturn(null);
  when(() => wallet.balance).thenReturn(balance);
  when(() => wallet.syncStatus).thenReturn(StartingScanSyncStatus(0));
  when(() => wallet.isHardwareWallet).thenReturn(false);
  when(() => wallet.name).thenReturn('test-wallet');
  when(() => walletAddresses.primaryAddress).thenReturn('primary-address');
  when(() => wallet.walletAddresses).thenReturn(walletAddresses);

  final unspentCoins = _UnspentCoinsListViewModel();
  when(() => unspentCoins.initialSetup()).thenAnswer((_) async {});

  return SendViewModel(
    appStore,
    _SendTemplateViewModel(),
    FiatConversionStore(),
    _AddressResolverService(),
    _BalanceViewModel(),
    _ContactListViewModel(),
    descriptionBox,
    null,
    unspentCoins,
    _FeesViewModel(),
    tradeExecutionDispatcher: dispatcher,
  )..pendingTransaction = pending;
}

SendViewModel _pegarouteViewModel({
  required _DescriptionBox descriptionBox,
  required _PendingTransaction pending,
  bool saveRecipient = false,
}) {
  final viewModel =
      _viewModel(descriptionBox: descriptionBox, pending: pending, saveRecipient: saveRecipient);
  viewModel.setPendingTransactionContextForTesting(
    transaction: pending,
    trade: Trade(
      id: 'trade-id',
      amount: '1',
      inputAddress: 'reviewed-deposit',
      provider: ExchangeProviderDescription.pegaroute,
    ),
  );
  return viewModel;
}

void main() {
  setUpAll(() {
    registerFallbackValue(_TransactionDescriptionFake());
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('sets failure state when the commit itself fails', () async {
    final pending = _PendingTransaction(commitError: StateError('commit failed'));
    final viewModel = _viewModel(descriptionBox: _DescriptionBox(), pending: pending);

    await viewModel.commitTransaction(_Context());

    expect(pending.commits, 1);
    expect(viewModel.state, isA<FailureState>());
  });

  test('approval confirmation prepares the next step without reporting a successful swap',
      () async {
    final approval = _ApprovalTransaction();
    final payment = _PendingTransaction();
    final dispatcher = _NextStepDispatcher(payment);
    final box = _DescriptionBox();
    final viewModel = _viewModel(descriptionBox: box, pending: approval, dispatcher: dispatcher);
    viewModel.setPendingTransactionContextForTesting(transaction: approval, trade: _stageTrade());
    await viewModel.commitTransaction(_Context());
    expect(approval.commits, 1);
    expect(payment.commits, 0);
    expect(dispatcher.preparations, 1);
    expect(viewModel.pendingTransaction, same(payment));
    expect(viewModel.state, isA<ExecutedSuccessfullyState>());
    verifyNever(() => box.add(any()));
    await viewModel.commitTransaction(_Context());
    expect(payment.commits, 1);
    expect(viewModel.state, isA<TransactionCommitted>());
  });

  test('pending approval keeps the confirmation error and does not prepare funding', () async {
    final approval = _ApprovalTransaction(
        commitError:
            const TradeExecutionPrerequisiteException('Approval confirmation is still pending'));
    final dispatcher = _NextStepDispatcher(_PendingTransaction());
    final box = _DescriptionBox();
    final viewModel = _viewModel(descriptionBox: box, pending: approval, dispatcher: dispatcher);
    viewModel.setPendingTransactionContextForTesting(transaction: approval, trade: _stageTrade());
    await viewModel.commitTransaction(_Context());
    expect(viewModel.state, isA<FailureState>());
    expect((viewModel.state as FailureState).error,
        contains('Approval confirmation is still pending'));
    expect(dispatcher.preparations, 0);
    verifyNever(() => box.add(any()));
  });

  test('Pegaroute missing or malformed execution never falls through to ordinary send', () async {
    final viewModel = _viewModel(descriptionBox: _DescriptionBox(), pending: _PendingTransaction());
    for (final raw in [null, '', '{}']) {
      final trade = Trade(
          id: 'unsupported-order',
          amount: '1',
          provider: ExchangeProviderDescription.pegaroute,
          executionJson: raw);
      expect(await viewModel.createTransaction(trade: trade), isNull);
      expect(viewModel.state, isA<FailureState>());
    }
    verifyNever(() => viewModel.wallet.createTransaction(any()));
  });

  test('keeps the existing UR path for non-Pegaroute transactions', () async {
    final pending = _PendingTransaction(commitUr: true);
    final viewModel = _viewModel(descriptionBox: _DescriptionBox(), pending: pending);

    await viewModel.commitTransaction(_Context());

    expect(pending.commits, 0);
    expect(pending.urCommits, 1);
    expect(viewModel.state, isA<FailureState>());
  });

  test('Pegaroute captures the committed pending transaction and succeeds', () async {
    final descriptionBox = _DescriptionBox();
    final descriptions = <TransactionDescription>[];
    when(() => descriptionBox.add(any<TransactionDescription>())).thenAnswer((invocation) async {
      descriptions.add(invocation.positionalArguments.single as TransactionDescription);
      return 0;
    });

    late final SendViewModel viewModel;
    final replacement = _PendingTransaction(id: 'replacement');
    final pending = _PendingTransaction(
      id: 'pegaroute-transaction',
      onCommit: () => viewModel.pendingTransaction = replacement,
    );
    viewModel = _pegarouteViewModel(descriptionBox: descriptionBox, pending: pending);

    await viewModel.commitTransaction(_Context());

    expect(pending.commits, 1);
    expect(descriptions.single.id, 'pegaroute-transaction_primary-address');
    expect(viewModel.state, isA<TransactionCommitted>());
  });

  test('Pegaroute preserves committed state when bookkeeping fails', () async {
    final descriptionBox = _DescriptionBox();
    when(() => descriptionBox.add(any<TransactionDescription>()))
        .thenThrow(StateError('sensitive failure detail'));
    final pending = _PendingTransaction();
    final viewModel = _pegarouteViewModel(descriptionBox: descriptionBox, pending: pending);

    await viewModel.commitTransaction(_Context());

    expect(pending.commits, 1);
    expect(viewModel.state, isA<TransactionCommitted>());
  });

  test('Pegaroute description keeps the bound deposit and captured wallet context', () async {
    final descriptionBox = _DescriptionBox();
    final descriptions = <TransactionDescription>[];
    when(() => descriptionBox.add(any<TransactionDescription>())).thenAnswer((invocation) async {
      descriptions.add(invocation.positionalArguments.single as TransactionDescription);
      return 0;
    });
    late final SendViewModel viewModel;
    final pending = _PendingTransaction(onCommit: () {
      viewModel.outputs.first.address = 'changed-deposit';
      viewModel.outputs.first.note = 'changed-note';
      when(() => viewModel.wallet.walletAddresses.primaryAddress).thenReturn('changed-wallet');
    });
    viewModel =
        _pegarouteViewModel(descriptionBox: descriptionBox, pending: pending, saveRecipient: true);
    viewModel.outputs.first.note = 'reviewed-note';
    await viewModel.commitTransaction(_Context());
    expect(viewModel.state, isA<TransactionCommitted>());
    expect(descriptions.single.id, '${pending.id}_primary-address');
    expect(descriptions.single.recipientAddress, 'reviewed-deposit');
    expect(descriptions.single.transactionNote, 'reviewed-note');
  });

  test('Pegaroute reports pre-boundary failure without failure bookkeeping', () async {
    final pending = _PendingTransaction(commitError: StateError('commit failed'));
    final viewModel = _pegarouteViewModel(descriptionBox: _DescriptionBox(), pending: pending);

    await viewModel.commitTransaction(_Context());

    expect(pending.commits, 1);
    expect(viewModel.state, isA<FailureState>());
  });

  test('Pegaroute rejects UR and does not call commitUR', () async {
    final pending = _PendingTransaction(commitUr: true);
    final viewModel = _pegarouteViewModel(descriptionBox: _DescriptionBox(), pending: pending);

    await viewModel.commitTransaction(_Context());

    expect(pending.commits, 0);
    expect(pending.urCommits, 0);
    expect(viewModel.state, isA<FailureState>());
  });

  test('Pegaroute prevents concurrent commits and clears the guard', () async {
    final commitStarted = Completer<void>();
    final releaseCommit = Completer<void>();
    final pending = _PendingTransaction(
      commitStarted: commitStarted,
      releaseCommit: releaseCommit,
    );
    final viewModel = _pegarouteViewModel(descriptionBox: _DescriptionBox(), pending: pending);

    final firstCommit = viewModel.commitTransaction(_Context());
    await commitStarted.future;
    final secondCommit = viewModel.commitTransaction(_Context());

    await secondCommit;
    expect(pending.commits, 1);

    releaseCommit.complete();
    await firstCommit;

    await viewModel.commitTransaction(_Context());
    expect(pending.commits, 2);
  });
}

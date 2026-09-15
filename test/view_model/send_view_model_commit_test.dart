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
import 'package:cake_wallet/generated/i18n.dart';
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
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/exceptions.dart';
// Offline round-trip coverage of the actual persisted EVM history format.
// ignore: cw_custom_lints/no_restricted_imports_in_lib
import 'package:cw_evm/evm_chain_transaction_info.dart';
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

class _History extends Mock implements TransactionHistoryBase<TransactionInfo> {
  final added = <TransactionInfo>[];
  @override
  void addOne(TransactionInfo transaction) => added.add(transaction);
}

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

class _Priority extends TransactionPriority {
  const _Priority() : super(title: 'Medium', raw: 1);
}

class _PendingTransaction with PendingTransaction {
  _PendingTransaction({
    this.id = 'transaction-id',
    this.commitError,
    this.onCommit,
    this.commitStarted,
    this.releaseCommit,
    this.commitUr = false,
    this.sourceAmount,
    this.networkFee,
  });

  final String id;
  final Object? commitError;
  final void Function()? onCommit;
  final Completer<void>? commitStarted;
  final Completer<void>? releaseCommit;
  final bool commitUr;
  final Money? sourceAmount;
  final Money? networkFee;
  int commits = 0;
  int urCommits = 0;

  @override
  Money get amount => sourceAmount ?? Money.zero(CryptoCurrency.zec);

  @override
  Money get fee => networkFee ?? Money.zero(CryptoCurrency.zec);
  @override
  String? get evmTxHashFromRawHex => id;

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

class _BalanceFailureDispatcher extends EmptyTradeExecutionDispatcher {
  _BalanceFailureDispatcher(this.error);
  final TransactionWrongBalanceException error;
  int preparations = 0;
  @override
  bool supports(TradeExecution execution) => true;
  @override
  Future<PendingTransaction?> prepare({required WalletBase wallet, required Trade trade}) async {
    preparations++;
    throw error;
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
  int? chainId,
  WalletType walletType = WalletType.zcash,
  CryptoCurrency walletCurrency = CryptoCurrency.zec,
  _History? history,
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

  when(() => wallet.type).thenReturn(walletType);
  when(() => wallet.currency).thenReturn(walletCurrency);
  when(() => wallet.chainId).thenReturn(chainId);
  if (history != null) when(() => wallet.transactionHistory).thenReturn(history);
  when(() => wallet.updateTransactionsHistory()).thenAnswer((_) async {});
  when(() => wallet.updateBalance()).thenAnswer((_) async {});
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
    S.current = const S();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const chains = {
    1: (WalletType.ethereum, CryptoCurrency.eth),
    56: (WalletType.bsc, CryptoCurrency.bnb),
    8453: (WalletType.base, CryptoCurrency.baseEth),
    42161: (WalletType.arbitrum, CryptoCurrency.arbEth),
    137: (WalletType.polygon, CryptoCurrency.maticpoly),
  };
  for (final chain in chains.entries) {
    for (final tokenSource in [false, true]) {
      testWidgets(
          'Pegaroute history captures chain ${chain.key} ${tokenSource ? "token" : "native"} source and native fee',
          (tester) async {
        final token = Erc20Token(
            name: 'Synthetic token',
            symbol: 'USDC',
            contractAddress: '0x1111111111111111111111111111111111111111',
            decimal: 6,
            chainId: chain.key);
        final currency = tokenSource ? token : chain.value.$2;
        final amount = Money(BigInt.from(251261), currency);
        final fee = Money(BigInt.from(517375134920720), chain.value.$2);
        final history = _History();
        final box = _DescriptionBox();
        when(() => box.add(any())).thenAnswer((_) async => 0);
        late SendViewModel viewModel;
        final pending = _PendingTransaction(
            sourceAmount: amount,
            networkFee: fee,
            onCommit: () => viewModel.selectedCryptoCurrency = CryptoCurrency.zec);
        viewModel = _viewModel(
            descriptionBox: box,
            pending: pending,
            chainId: chain.key,
            walletType: chain.value.$1,
            walletCurrency: chain.value.$2,
            history: history);
        viewModel.setPendingTransactionContextForTesting(
            transaction: pending,
            trade: Trade(
                id: 'trade-id',
                amount: '0.251261',
                inputAddress: 'deposit',
                provider: ExchangeProviderDescription.pegaroute));
        await viewModel.commitTransaction(_Context());
        expect(viewModel.state, isA<TransactionCommitted>());
        final tx = history.added.single as EVMChainTransactionInfo;
        expect(tx.id, pending.id);
        expect(tx.amount, amount);
        expect(tx.tokenSymbol, currency.title);
        expect(tx.exponent, currency.decimals);
        expect(tx.contractAddress, tokenSource ? token.contractAddress : null);
        expect(tx.chainId, chain.key);
        expect(tx.fee, fee);
        final restored = EVMChainTransactionInfo.fromJson(tx.toJson(), chain.key);
        expect(restored.amount.amount, amount.amount);
        expect(restored.amount.currency.decimals, currency.decimals);
        expect(restored.fee.currency, chain.value.$2);
        if (tokenSource) {
          expect((restored.amount.currency as Erc20Token).contractAddress, token.contractAddress);
          expect((restored.amount.currency as Erc20Token).chainId, chain.key);
        }
        await tester.pump(const Duration(seconds: 4));
      });
    }
  }

  testWidgets('Pegaroute does not insert source history into a switched network', (tester) async {
    final history = _History();
    final box = _DescriptionBox();
    when(() => box.add(any())).thenAnswer((_) async => 0);
    late SendViewModel viewModel;
    final pending =
        _PendingTransaction(onCommit: () => when(() => viewModel.wallet.chainId).thenReturn(56));
    viewModel = _viewModel(
        descriptionBox: box,
        pending: pending,
        chainId: 1,
        walletType: WalletType.ethereum,
        walletCurrency: CryptoCurrency.eth,
        history: history);
    viewModel.setPendingTransactionContextForTesting(
        transaction: pending,
        trade: Trade(id: 'trade-id', amount: '1', provider: ExchangeProviderDescription.pegaroute));
    await viewModel.commitTransaction(_Context());
    expect(history.added, isEmpty);
    expect(viewModel.state, isA<TransactionCommitted>());
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

  for (final currency in [
    CryptoCurrency.eth,
    Erc20Token(
        name: 'USD Coin',
        symbol: 'USDC',
        contractAddress: '0x1111111111111111111111111111111111111111',
        decimal: 6,
        chainId: 1),
  ]) {
    test('Pegaroute preparation displays the insufficient ${currency.title} balance', () async {
      final dispatcher = _BalanceFailureDispatcher(TransactionWrongBalanceException(currency));
      final box = _DescriptionBox();
      final viewModel = _viewModel(
          descriptionBox: box,
          pending: _PendingTransaction(),
          dispatcher: dispatcher,
          walletType: WalletType.ethereum,
          walletCurrency: CryptoCurrency.eth,
          chainId: 1);
      expect(await viewModel.createTransaction(trade: _stageTrade()), isNull);
      expect(viewModel.pendingTransaction, isNull);
      expect(viewModel.state, isA<FailureState>());
      expect((viewModel.state as FailureState).error,
          S.current.tx_wrong_balance_exception(currency.toString()));
      expect(dispatcher.preparations, 1);
      verifyNever(() => viewModel.wallet.createTransaction(any()));
      verifyNever(() => box.add(any()));
    });
  }

  for (final chain in chains.entries) {
    test('failed preparation shows exact native value and gas budget on chain ${chain.key}',
        () async {
      final currency = chain.value.$2;
      final symbol = currency.symbol;
      final dispatcher = _BalanceFailureDispatcher(TransactionWrongBalanceException(
        currency,
        requiredBalance: Money.parse('0.00275917', currency),
        availableBalance: Money.parse('0.000836033134785206', currency),
        fee: Money.parse('0.00175917', currency),
        feePriority: const _Priority(),
      ));
      final box = _DescriptionBox();
      final viewModel = _viewModel(
          descriptionBox: box,
          pending: _PendingTransaction(),
          dispatcher: dispatcher,
          walletType: chain.value.$1,
          walletCurrency: currency,
          chainId: chain.key);
      expect(await viewModel.createTransaction(trade: _stageTrade()), isNull);
      expect(viewModel.pendingTransaction, isNull);
      expect(viewModel.state, isA<FailureState>());
      expect(
          (viewModel.state as FailureState).error,
          '${S.current.tx_wrong_balance_exception(currency.toString())}\n\n'
          '${S.current.transaction_details_amount}: 0.001 $symbol\n'
          '${S.current.wc_max_network_fee}: 0.00175917 $symbol\n'
          '${S.current.settings_fee_priority}: Medium\n'
          '${S.current.transaction_cost}: 0.00275917 $symbol\n'
          '${S.current.available_balance}: 0.000836033134785206 $symbol\n'
          '${S.current.overshot}: 0.001923136865214794 $symbol');
      expect(dispatcher.preparations, 1);
      verifyNever(() => viewModel.wallet.createTransaction(any()));
      verifyNever(() => box.add(any()));
    });
  }

  test('capitalized node funding rejection is localized with exact native amounts', () async {
    final pending = _PendingTransaction(
        commitError: StateError('RPCError: got code -32000 with msg '
            '"Insufficient funds for gas * price + value: '
            'have 717351881928726 want 723646218408612"'));
    final viewModel = _viewModel(
        descriptionBox: _DescriptionBox(),
        pending: pending,
        walletType: WalletType.ethereum,
        walletCurrency: CryptoCurrency.eth,
        chainId: 1);
    viewModel.setPendingTransactionContextForTesting(transaction: pending, trade: _stageTrade());
    await viewModel.commitTransaction(_Context());
    expect(
        (viewModel.state as FailureState).error,
        '${S.current.tx_wrong_balance_exception('ETH')}\n\n'
        '${S.current.transaction_cost}: 0.000723646218408612 ETH\n'
        '${S.current.available_balance}: 0.000717351881928726 ETH\n'
        '${S.current.overshot}: 0.000006294336479886 ETH');
    expect(pending.commits, 1);
  });

  test('token principal failure uses the token decimals without a native fee total', () async {
    final token = Erc20Token(
        name: 'USD Coin',
        symbol: 'USDC',
        contractAddress: '0x1111111111111111111111111111111111111111',
        decimal: 6,
        chainId: 1);
    final dispatcher = _BalanceFailureDispatcher(TransactionWrongBalanceException(
      token,
      requiredBalance: Money.parse('1.000001', token),
      availableBalance: Money.parse('0.5', token),
    ));
    final viewModel = _viewModel(
        descriptionBox: _DescriptionBox(),
        pending: _PendingTransaction(),
        dispatcher: dispatcher,
        walletType: WalletType.ethereum,
        walletCurrency: CryptoCurrency.eth,
        chainId: 1);
    expect(await viewModel.createTransaction(trade: _stageTrade()), isNull);
    expect(viewModel.pendingTransaction, isNull);
    expect(viewModel.state, isA<FailureState>());
    expect(
        (viewModel.state as FailureState).error,
        '${S.current.tx_wrong_balance_exception('USDC')}\n\n'
        '${S.current.transaction_cost}: 1.000001 USDC\n'
        '${S.current.available_balance}: 0.5 USDC\n'
        '${S.current.overshot}: 0.500001 USDC');
  });

  test('known balances without a fee retain a one-wei shortfall without inventing a fee', () {
    final viewModel = _viewModel(
        descriptionBox: _DescriptionBox(),
        pending: _PendingTransaction(),
        walletType: WalletType.ethereum,
        walletCurrency: CryptoCurrency.eth,
        chainId: 1);
    final message = viewModel.translateErrorMessage(
        TransactionWrongBalanceException(
          CryptoCurrency.eth,
          requiredBalance: Money.parse('1', CryptoCurrency.eth),
          availableBalance: Money.parse('0.999999999999999999', CryptoCurrency.eth),
        ),
        WalletType.ethereum,
        CryptoCurrency.eth);
    expect(
        message,
        '${S.current.tx_wrong_balance_exception('ETH')}\n\n'
        '${S.current.transaction_cost}: 1 ETH\n'
        '${S.current.available_balance}: 0.999999999999999999 ETH\n'
        '${S.current.overshot}: 0.000000000000000001 ETH');
  });

  test('incomplete or mismatched balance metadata keeps the localized legacy failure', () {
    final viewModel = _viewModel(
        descriptionBox: _DescriptionBox(),
        pending: _PendingTransaction(),
        walletType: WalletType.ethereum,
        walletCurrency: CryptoCurrency.eth,
        chainId: 1);
    for (final error in [
      TransactionWrongBalanceException(CryptoCurrency.eth),
      TransactionWrongBalanceException(CryptoCurrency.eth,
          requiredBalance: Money.parse('1', CryptoCurrency.eth)),
      TransactionWrongBalanceException(CryptoCurrency.eth,
          availableBalance: Money.zero(CryptoCurrency.eth)),
      TransactionWrongBalanceException(CryptoCurrency.eth,
          requiredBalance: Money.parse('1', CryptoCurrency.eth),
          availableBalance: Money.zero(CryptoCurrency.bnb)),
    ]) {
      expect(viewModel.translateErrorMessage(error, WalletType.ethereum, CryptoCurrency.eth),
          S.current.tx_wrong_balance_exception('ETH'));
    }
  });

  test('a differently denominated fee is never subtracted from the required balance', () {
    final viewModel = _viewModel(
        descriptionBox: _DescriptionBox(),
        pending: _PendingTransaction(),
        walletType: WalletType.bsc,
        walletCurrency: CryptoCurrency.bnb,
        chainId: 56);
    final message = viewModel.translateErrorMessage(
        TransactionWrongBalanceException(
          CryptoCurrency.bnb,
          requiredBalance: Money.parse('1', CryptoCurrency.bnb),
          availableBalance: Money.parse('0.5', CryptoCurrency.bnb),
          fee: Money.parse('0.001', CryptoCurrency.eth),
        ),
        WalletType.bsc,
        CryptoCurrency.bnb);
    expect(
        message,
        '${S.current.tx_wrong_balance_exception('BNB')}\n\n'
        '${S.current.transaction_cost}: 1 BNB\n'
        '${S.current.available_balance}: 0.5 BNB\n'
        '${S.current.overshot}: 0.5 BNB');
  });

  test('Litecoin retains its legacy wallet currency and integer amount formatting', () {
    final viewModel = _viewModel(
        descriptionBox: _DescriptionBox(),
        pending: _PendingTransaction(),
        walletType: WalletType.litecoin,
        walletCurrency: CryptoCurrency.ltc);
    // Bitcoin-family exceptions carry BTC even when the wallet is Litecoin.
    final error = TransactionWrongBalanceException(CryptoCurrency.btc, amount: 12345);
    expect(error.amount, 12345);
    expect(viewModel.translateErrorMessage(error, WalletType.litecoin, CryptoCurrency.ltc),
        S.current.tx_wrong_balance_with_amount_exception('LTC', '12345'));
    expect(
        viewModel.translateErrorMessage(TransactionWrongBalanceException(CryptoCurrency.btc),
            WalletType.litecoin, CryptoCurrency.ltc),
        S.current.tx_wrong_balance_exception('LTC'));
  });

  test('confirmed approval retains a subsequent balance failure without funding the swap',
      () async {
    final approval = _ApprovalTransaction();
    final dispatcher = _BalanceFailureDispatcher(TransactionWrongBalanceException(
      CryptoCurrency.eth,
      requiredBalance: Money.parse('0.00175917', CryptoCurrency.eth),
      availableBalance: Money.parse('0.000836033134785206', CryptoCurrency.eth),
      fee: Money.parse('0.00175917', CryptoCurrency.eth),
    ));
    final box = _DescriptionBox();
    final viewModel = _viewModel(
        descriptionBox: box,
        pending: approval,
        dispatcher: dispatcher,
        walletType: WalletType.ethereum,
        walletCurrency: CryptoCurrency.eth,
        chainId: 1);
    viewModel.setPendingTransactionContextForTesting(transaction: approval, trade: _stageTrade());
    await viewModel.commitTransaction(_Context());
    expect(approval.commits, 1);
    expect(dispatcher.preparations, 1);
    expect(viewModel.pendingTransaction, isNull);
    expect(viewModel.state, isA<FailureState>());
    expect(
        (viewModel.state as FailureState).error,
        '${S.current.tx_wrong_balance_exception('ETH')}\n\n'
        '${S.current.wc_max_network_fee}: 0.00175917 ETH\n'
        '${S.current.transaction_cost}: 0.00175917 ETH\n'
        '${S.current.available_balance}: 0.000836033134785206 ETH\n'
        '${S.current.overshot}: 0.000923136865214794 ETH');
    verifyNever(() => viewModel.wallet.createTransaction(any()));
    verifyNever(() => box.add(any()));
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

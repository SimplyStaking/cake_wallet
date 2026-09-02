import 'package:cake_wallet/core/amount_parsing_proxy.dart';
import 'package:cake_wallet/core/address_resolver/address_resolver_service.dart';
import 'package:cake_wallet/core/execution_state.dart';
import 'package:cake_wallet/entities/bitcoin_amount_display_mode.dart';
import 'package:cake_wallet/entities/transaction_description.dart';
import 'package:cake_wallet/entities/fiat_currency.dart';
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
  _PendingTransaction({this.commitError});

  final Object? commitError;
  int commits = 0;

  @override
  String get id => 'transaction-id';

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
    if (commitError != null) throw commitError!;
  }

  @override
  Future<Map<String, String>> commitUR() async => {};
}

SendViewModel _viewModel({
  required _DescriptionBox descriptionBox,
  required _PendingTransaction pending,
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
  when(() => settingsStore.shouldSaveRecipientAddress).thenReturn(false);

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
  )..pendingTransaction = pending;
}

void main() {
  setUpAll(() {
    registerFallbackValue(_TransactionDescriptionFake());
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('keeps committed state when post-commit description persistence fails', () async {
    final descriptionBox = _DescriptionBox();
    when(() => descriptionBox.add(any<TransactionDescription>()))
        .thenThrow(StateError('sensitive failure detail'));
    final pending = _PendingTransaction();
    final viewModel = _viewModel(descriptionBox: descriptionBox, pending: pending);

    await viewModel.commitTransaction(_Context());

    expect(pending.commits, 1);
    expect(viewModel.state, isA<TransactionCommitted>());
  });

  test('sets failure state when the commit itself fails', () async {
    final pending = _PendingTransaction(commitError: StateError('commit failed'));
    final viewModel = _viewModel(descriptionBox: _DescriptionBox(), pending: pending);

    await viewModel.commitTransaction(_Context());

    expect(pending.commits, 1);
    expect(viewModel.state, isA<FailureState>());
  });
}

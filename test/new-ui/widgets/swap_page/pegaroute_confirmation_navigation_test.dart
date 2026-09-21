import 'dart:async';

import 'package:cake_wallet/core/amount_parsing_proxy.dart';
import 'package:cake_wallet/core/execution_state.dart';
import 'package:cake_wallet/di.dart';
import 'package:cake_wallet/entities/bitcoin_amount_display_mode.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/new-ui/widgets/swap_page/swap_confirm_sheet.dart';
import 'package:cake_wallet/new-ui/widgets/swap_page/pegaroute_preparation_retry_button.dart';
import 'package:cake_wallet/themes/core/theme_store.dart';
import 'package:cake_wallet/view_model/exchange/exchange_trade_view_model.dart';
import 'package:cake_wallet/view_model/exchange/exchange_view_model.dart';
import 'package:cake_wallet/view_model/send/send_view_model.dart';
import 'package:cake_wallet/view_model/send/send_view_model_state.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart' show Observable, runInAction;
import 'package:mocktail/mocktail.dart';
import 'package:modal_bottom_sheet/modal_bottom_sheet.dart';

class _Exchange extends Mock implements ExchangeViewModel {}

class _Trade extends Mock implements ExchangeTradeViewModel {}

class _Send extends Mock implements SendViewModel {}

void main() {
  for (final nested in [false, true]) {
    for (final closing in [
      'success',
      'error close',
      'manual close',
      'close before timer',
      'overlay'
    ]) {
      testWidgets('$closing preserves the underlying ${nested ? 'nested' : 'root'} navigator',
          (tester) async {
        tester.view.physicalSize =
            closing == 'error close' ? const Size(390, 844) : const Size(1200, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        getIt.registerSingleton<ThemeStore>(ThemeStore());
        addTearDown(() => getIt.unregister<ThemeStore>());
        final exchange = _Exchange();
        final trade = _Trade();
        final send = _Send();
        final state = Observable<ExecutionState>(FailureState('Synthetic preparation error'));
        final polling = Timer.periodic(const Duration(seconds: 20), (_) {});
        addTearDown(polling.cancel);
        when(() => trade.timer).thenReturn(polling);
        when(() => trade.sendViewModel).thenReturn(send);
        when(() => send.state).thenAnswer((_) => state.value);
        when(() => send.pendingTransaction).thenReturn(null);
        when(() => exchange.isSendFromExternal).thenReturn(true);
        when(() => exchange.depositCurrency).thenReturn(CryptoCurrency.eth);
        when(() => exchange.receiveCurrency).thenReturn(CryptoCurrency.usdc);
        when(() => exchange.amountParsingProxy)
            .thenReturn(const AmountParsingProxy(BitcoinAmountDisplayMode.bitcoin));
        when(() => exchange.receiveAddressDisplayName).thenReturn('Destination');
        when(() => trade.trade).thenReturn(Trade(
            id: 'fixture',
            provider: ExchangeProviderDescription.pegaroute,
            amount: '0.001',
            from: CryptoCurrency.eth,
            to: CryptoCurrency.usdc,
            payoutAddress: '0x0000000000000000000000000000000000000001'));
        final root = GlobalKey<NavigatorState>();
        final inner = GlobalKey<NavigatorState>();
        Widget page(BuildContext context) => Scaffold(
            body: TextButton(
                onPressed: () => showMaterialModalBottomSheet<void>(
                    context: context,
                    builder: (_) => SwapConfirmSheet(
                        exchangeViewModel: exchange,
                        exchangeTradeViewModel: trade,
                        receiveAmount: '2.617439')),
                child: const Text('Open confirmation')));
        await tester.pumpWidget(MaterialApp(
            navigatorKey: root,
            locale: const Locale('en'),
            supportedLocales: S.delegate.supportedLocales,
            localizationsDelegates: [S.delegate],
            home: nested
                ? Navigator(key: inner, onGenerateRoute: (_) => MaterialPageRoute(builder: page))
                : Builder(builder: page)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open confirmation'));
        await tester.pumpAndSettle();
        final navigator = nested ? inner.currentState! : root.currentState!;
        expect(find.byType(SwapConfirmSheet), findsOneWidget);
        // Failure actions are wired into the actual sheet, not an orphan widget.
        expect(find.byType(PegaroutePreparationRetryButton), findsOneWidget);
        if (closing == 'error close') {
          const breakdown = 'You do not have enough ETH to send this amount.\n\n'
              'Amount: 0.0005 ETH\n'
              'Max network fee: 0.00086164639831152 ETH\n'
              'Fee priority: Medium\n'
              'Transaction Cost: 0.00136164639831152 ETH\n'
              'Available Balance: 0.000836033134785206 ETH\n'
              'Overshot: 0.000525613263526314 ETH';
          runInAction(() => state.value = FailureState(breakdown));
          await tester.pumpAndSettle();
          expect(find.text(breakdown), findsOneWidget);
          await tester.ensureVisible(find.text(breakdown));
          await tester.ensureVisible(find.text(S.current.close));
          await tester.tap(find.text(S.current.close));
        } else if (closing == 'manual close') {
          await tester.tap(find.byIcon(Icons.close));
        } else {
          runInAction(() => state.value = TransactionCommitted());
          await tester.pump();
          if (closing == 'close before timer') navigator.pop();
          if (closing == 'overlay') {
            navigator.push(
                MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Overlay'))));
          }
        }
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        if (closing == 'overlay') {
          expect(find.text('Overlay'), findsOneWidget);
          navigator.pop();
          await tester.pumpAndSettle();
          navigator.pop();
          await tester.pumpAndSettle();
        }
        expect(find.byType(SwapConfirmSheet), findsNothing);
        expect(find.text('Open confirmation'), findsOneWidget);
        expect(polling.isActive, false);
        expect(root.currentState!.canPop(), false);
        expect(tester.takeException(), isNull);
        // A disposed sheet must not react to future sends or schedule new pops.
        runInAction(() => state.value = IsExecutingState());
        runInAction(() => state.value = TransactionCommitted());
        await tester.pump(const Duration(seconds: 3));
        expect(find.text('Open confirmation'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

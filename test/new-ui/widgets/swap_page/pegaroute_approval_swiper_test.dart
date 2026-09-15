import 'package:cake_wallet/core/execution_state.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/new-ui/widgets/send_page/send_confirm_bottom_widget.dart';
import 'package:cake_wallet/view_model/send/send_view_model.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart' show Observable, runInAction;
import 'package:mocktail/mocktail.dart';

class _Send extends Mock implements SendViewModel {}

class _Pending extends Mock implements PendingTransaction, TradeExecutionStage {
  _Pending(this.prerequisiteDescription);
  @override
  final String? prerequisiteDescription;
}

void main() {
  testWidgets('approval action is specific and updates to send for the actual swap',
      (tester) async {
    final send = _Send();
    final pending = Observable<PendingTransaction>(_Pending('Approve 5 USDC'));
    when(() => send.state).thenReturn(ExecutedSuccessfullyState());
    when(() => send.pendingTransaction).thenAnswer((_) => pending.value);
    await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        supportedLocales: S.delegate.supportedLocales,
        localizationsDelegates: [S.delegate],
        home: Scaffold(body: SendConfirmBottomWidget(sendViewModel: send))));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Swipe for contract approval'), findsOneWidget);
    expect(find.text(S.current.swipe_to_send), findsNothing);
    runInAction(() => pending.value = _Pending(null));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Swipe for contract approval'), findsNothing);
    expect(find.text(S.current.swipe_to_send), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

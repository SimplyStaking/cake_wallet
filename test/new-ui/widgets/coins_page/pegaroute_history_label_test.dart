import 'package:cake_wallet/new-ui/widgets/coins_page/assets_history/history_tile_base.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('long provider labels fit a narrow history tile without obscuring amounts',
      (tester) async {
    const label = 'Pegaroute via Instaswap (via An exchange with a long informational name)';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: HistoryTileBase(
              title: 'Pending',
              subtitle: label,
              date: 'Today',
              amount: '+2.49 USDC',
              amountFiat: '-0.001 ETH',
              leadingIcon: SizedBox(),
              roundedTop: true,
              roundedBottom: true,
              bottomSeparator: false,
            ),
          ),
        ),
      ),
    ));
    expect(find.text(label), findsOneWidget);
    expect(find.text('+2.49 USDC'), findsOneWidget);
    expect(find.text('-0.001 ETH'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final labelRect = tester.getRect(find.text(label));
    final amountRect = tester.getRect(find.text('-0.001 ETH'));
    expect(labelRect.top, greaterThanOrEqualTo(amountRect.bottom));
    expect(labelRect.width, lessThanOrEqualTo(320));
  });
}

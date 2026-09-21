import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/provider/exchange_provider.dart';
import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/locales/locale.dart';
import 'package:cake_wallet/new-ui/pages/swap_page.dart';
import 'package:cake_wallet/view_model/exchange/exchange_view_model.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart' show Observable, runInAction;
import 'package:mocktail/mocktail.dart';

class _Exchange extends Mock implements ExchangeViewModel {}

class _Provider extends Mock implements ExchangeProvider {}

void main() {
  testWidgets('preview distinguishes loading, unavailable and a recovered current quote',
      (tester) async {
    final viewModel = _Exchange();
    final provider = _Provider();
    final loading = Observable(true);
    final unavailable = Observable(false);
    when(() => provider.title).thenReturn('Pegaroute');
    when(() => provider.description).thenReturn(ExchangeProviderDescription.pegaroute);
    when(() => viewModel.isFixedRateMode).thenReturn(false);
    when(() => viewModel.depositAmount).thenReturn('0.002');
    when(() => viewModel.isFetchingRate).thenAnswer((_) => loading.value);
    when(() => viewModel.noProviderForPair).thenAnswer((_) => unavailable.value);
    when(() => viewModel.forcedProvider).thenReturn(null);
    // Even retained display fields must not win over unavailable/loading state.
    when(() => viewModel.providerDisplay).thenReturn(provider);
    when(() => viewModel.bestRate).thenReturn(2384);
    when(() => viewModel.depositCurrency).thenReturn(CryptoCurrency.eth);
    when(() => viewModel.receiveCurrency).thenReturn(CryptoCurrency.usdcArb);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      supportedLocales: S.delegate.supportedLocales,
      localizationsDelegates: localizationDelegates,
      home: Scaffold(body: SwapProviderPreview(exchangeViewModel: viewModel)),
    ));
    await tester.pump();
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(find.text('Pegaroute'), findsNothing);
    runInAction(() {
      loading.value = false;
      unavailable.value = true;
    });
    await tester.pump();
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.text('Pegaroute'), findsNothing);
    expect(find.byKey(const ValueKey('swap_provider_unavailable')), findsOneWidget);
    expect(find.text(S.current.none_of_selected_providers_can_exchange), findsOneWidget);
    runInAction(() => unavailable.value = false);
    await tester.pump();
    expect(find.byKey(const ValueKey('swap_provider_unavailable')), findsNothing);
    expect(find.text('Pegaroute'), findsOneWidget);
    expect(find.textContaining('2384.000000'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final language in ['en', 'de']) {
    testWidgets('existing unavailable message wraps at mobile width in $language', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final viewModel = _Exchange();
      when(() => viewModel.isFixedRateMode).thenReturn(false);
      when(() => viewModel.depositAmount).thenReturn('0.002');
      when(() => viewModel.noProviderForPair).thenReturn(true);
      when(() => viewModel.isFetchingRate).thenReturn(false);
      await tester.pumpWidget(MaterialApp(
        locale: Locale(language),
        supportedLocales: S.delegate.supportedLocales,
        localizationsDelegates: localizationDelegates,
        home: Scaffold(body: SwapProviderPreview(exchangeViewModel: viewModel)),
      ));
      await tester.pumpAndSettle();
      expect(find.text(S.current.none_of_selected_providers_can_exchange), findsOneWidget);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

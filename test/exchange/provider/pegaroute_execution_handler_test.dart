import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_btc_execution_handler.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_eth_execution_handler.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_handler_support.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_xmr_execution_handler.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:flutter_test/flutter_test.dart';

const _route =
    '{"provider":"instaswap","providerType":"fixture","subprovider":null,"private":false,"expectedOutput":"0.99","fees":null,"estimatedTimeSeconds":0,"memo":null,"inboundAddress":"provider-inbound","router":"0x0000000000000000000000000000000000000005","minAmount":null,"expiry":null,"gasRate":null,"resolvedFee":null,"openOceanRoute":null}';

TradeExecutionBinding _binding({
  required String sourceAmount,
  required String sourceAmountBaseUnits,
  required int? walletChainId,
  String? providerDepositAddress,
  String reviewedRouteJson = _route,
}) => TradeExecutionBinding(
  tradeId: 'trade-fixture',
  providerRaw: 17,
  quoteId: 'quote-fixture',
  quoteExpiresAt: DateTime.utc(2099),
  routeExpiry: null,
  providerDepositAddress: providerDepositAddress,
  sourceAmount: sourceAmount,
  sourceAmountBaseUnits: sourceAmountBaseUnits,
  sourceDecimals: 0,
  destinationDecimals: 8,
  senderAddress: 'sender',
  refundAddress: null,
  destinationAddress: 'destination',
  isSendAll: false,
  walletId: 'wallet-fixture',
  walletChainId: walletChainId,
  walletAddress: 'sender',
  reviewedRouteJson: reviewedRouteJson,
  providerReferenceId: null,
);

ValidatedTradeExecution _validated(TradeExecution execution) =>
    ValidatedTradeExecution(execution: execution, rawExecutionJson: execution.encode());

void main() {
  final now = DateTime.utc(2026);

  test('BTC handler requires an exact payment-with-memo envelope', () {
    final execution = TradeExecution(
      family: 'utxo',
      mode: 'payment-with-memo',
      sourceChain: 'BTC',
      sourceToken: 'BTC',
      nativeToken: 'BTC',
      destinationChain: 'ETH',
      destinationToken: 'ETH',
      binding: _binding(
        sourceAmount: '1',
        sourceAmountBaseUnits: '1',
        walletChainId: null,
        providerDepositAddress: 'provider-btc',
      ),
      routeProvider: 'instaswap',
      payload: {
        'to': 'provider-btc',
        'amount': {'display': '1', 'baseUnits': '1'},
        'memo': null,
        'gasRate': '1',
      },
    );
    final handler = PegarouteBtcExecutionHandler(
      walletContext: _UnsupportedWalletContext(),
      adapter: _UnsupportedBtcAdapter(),
    );

    expect(handler.supports(execution), isTrue);
    expect(
      () => handler.validateForExecution(execution: _validated(execution), now: now),
      returnsNormally,
    );
  });

  test('XMR handler rejects a memo or payment id', () {
    final execution = TradeExecution(
      family: 'other',
      mode: 'deposit-transfer',
      sourceChain: 'XMR',
      sourceToken: 'XMR',
      nativeToken: 'XMR',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      binding: _binding(
        sourceAmount: '1',
        sourceAmountBaseUnits: '1',
        walletChainId: null,
        providerDepositAddress: 'provider-xmr',
      ),
      routeProvider: 'instaswap',
      payload: {
        'chain': 'XMR',
        'to': 'provider-xmr',
        'amount': {'display': '1', 'baseUnits': '1'},
        'memo': 'unexpected',
      },
    );
    final handler = PegarouteXmrExecutionHandler(
      walletContext: _UnsupportedWalletContext(),
      adapter: _UnsupportedXmrAdapter(),
    );

    expect(handler.supports(execution), isTrue);
    expect(
      () => handler.validateForExecution(execution: _validated(execution), now: now),
      throwsA(isA<PegarouteBindingException>()),
    );
  });

  test('native ETH handler requires chain id 1 and no calldata', () {
    final execution = TradeExecution(
      family: 'evm',
      mode: 'native-transfer',
      sourceChain: 'ETH',
      sourceToken: 'ETH',
      nativeToken: 'ETH',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      binding: _binding(
        sourceAmount: '1',
        sourceAmountBaseUnits: '1',
        walletChainId: 1,
        providerDepositAddress: '0x0000000000000000000000000000000000000005',
      ),
      routeProvider: 'instaswap',
      payload: {
        'chainId': 1,
        'to': '0x0000000000000000000000000000000000000005',
        'data': null,
        'value': {'display': '1', 'baseUnits': '1'},
        'gasLimit': '21000',
        'memo': null,
        'approval': null,
        'transferAmount': null,
      },
    );
    final handler = PegarouteEthExecutionHandler(
      walletContext: _UnsupportedWalletContext(),
      adapter: _UnsupportedEthAdapter(),
    );

    expect(handler.supports(execution), isTrue);
    expect(
      () => handler.validateForExecution(execution: _validated(execution), now: now),
      returnsNormally,
    );
  });
}

final class _UnsupportedWalletContext implements PegarouteWalletContext {
  @override
  PegarouteWalletSnapshot snapshot(WalletBase wallet) =>
      throw UnsupportedError('wallet construction is not part of this test');
}

final class _UnsupportedBtcAdapter implements PegarouteBtcWalletAdapter {
  @override
  Future<PegaroutePreparedTransaction<PegarouteBtcTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  }) => throw UnsupportedError('wallet construction is not part of this test');
}

final class _UnsupportedXmrAdapter implements PegarouteXmrWalletAdapter {
  @override
  Future<PegaroutePreparedTransaction<PegarouteXmrTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  }) => throw UnsupportedError('wallet construction is not part of this test');
}

final class _UnsupportedEthAdapter implements PegarouteEthWalletAdapter {
  @override
  Future<PegaroutePreparedTransaction<PegarouteEthTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  }) => throw UnsupportedError('wallet construction is not part of this test');
}

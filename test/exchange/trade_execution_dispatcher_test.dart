import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:flutter_test/flutter_test.dart';

TradeExecution _execution() => TradeExecution(
      family: 'other',
      mode: 'deposit-transfer',
      sourceChain: 'XMR',
      sourceToken: 'XMR',
      nativeToken: 'XMR',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      payload: const {
        'chain': 'XMR',
        'to': 'destination',
        'amount': {'display': '1', 'baseUnits': '1'},
        'memo': null,
      },
    );

class _Handler implements TradeExecutionHandler {
  const _Handler(this.external);

  final bool external;

  @override
  bool supports(TradeExecution execution) => true;

  @override
  bool supportsExternalSend(TradeExecution execution) => external;

  @override
  Future<PendingTransaction?> prepare({
    required WalletBase wallet,
    required Trade trade,
    required TradeExecution execution,
  }) async =>
      null;
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
      RegistryTradeExecutionDispatcher(const [_Handler(true), _Handler(true)]).supports(execution),
      isFalse,
    );
    expect(
      RegistryTradeExecutionDispatcher(const [_Handler(true), _Handler(false)])
          .supportsExternalSend(execution),
      isFalse,
    );
    expect(
      RegistryTradeExecutionDispatcher(const [_Handler(true)]).supportsExternalSend(execution),
      isTrue,
    );
  });
}

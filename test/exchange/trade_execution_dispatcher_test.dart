import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';

void main() {
  test('empty Phase 1 dispatcher supports and prepares nothing', () async {
    const dispatcher = EmptyTradeExecutionDispatcher();
    const execution = TradeExecution(
      family: 'other',
      mode: 'deposit-transfer',
      sourceChain: 'XMR',
      sourceToken: 'XMR',
      nativeToken: 'XMR',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      payload: {},
    );
    expect(dispatcher.supports(execution), isFalse);
    expect(dispatcher.supportsExternalSend(execution), isFalse);
  });
}

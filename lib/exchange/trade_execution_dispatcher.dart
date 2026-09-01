import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/wallet_base.dart';

import 'trade.dart';
import 'trade_execution.dart';

abstract interface class TradeExecutionHandler {
  bool supports(TradeExecution execution);
  bool supportsExternalSend(TradeExecution execution);
  Future<PendingTransaction?> prepare({
    required WalletBase wallet,
    required Trade trade,
    required TradeExecution execution,
  });
}

abstract interface class TradeExecutionDispatcher {
  bool supports(TradeExecution execution);
  bool supportsExternalSend(TradeExecution execution);
  Future<PendingTransaction?> prepare({required WalletBase wallet, required Trade trade});
}

class EmptyTradeExecutionDispatcher implements TradeExecutionDispatcher {
  const EmptyTradeExecutionDispatcher();

  @override
  bool supports(TradeExecution execution) => false;

  @override
  bool supportsExternalSend(TradeExecution execution) => false;

  @override
  Future<PendingTransaction?> prepare({required WalletBase wallet, required Trade trade}) async =>
      null;
}

class RegistryTradeExecutionDispatcher implements TradeExecutionDispatcher {
  const RegistryTradeExecutionDispatcher(this.handlers);

  final List<TradeExecutionHandler> handlers;

  TradeExecutionHandler? _handler(TradeExecution execution) {
    for (final handler in handlers) {
      if (handler.supports(execution)) return handler;
    }
    return null;
  }

  @override
  bool supports(TradeExecution execution) => _handler(execution) != null;

  @override
  bool supportsExternalSend(TradeExecution execution) =>
      _handler(execution)?.supportsExternalSend(execution) ?? false;

  @override
  Future<PendingTransaction?> prepare({required WalletBase wallet, required Trade trade}) {
    final raw = trade.executionJson;
    if (raw == null || raw.isEmpty) return Future.value(null);
    final execution = TradeExecution.fromJsonString(raw);
    final handler = _handler(execution);
    if (handler == null) return Future.value(null);
    return handler.prepare(wallet: wallet, trade: trade, execution: execution);
  }
}

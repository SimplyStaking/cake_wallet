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

  List<TradeExecutionHandler> _matchingHandlers(
    TradeExecution execution, {
    bool external = false,
  }) {
    return handlers
        .where((handler) => handler.supports(execution))
        .where((handler) => !external || handler.supportsExternalSend(execution))
        .toList(growable: false);
  }

  TradeExecutionHandler? _handler(TradeExecution execution, {bool external = false}) {
    final matches = _matchingHandlers(execution, external: external);
    return matches.length == 1 ? matches.single : null;
  }

  @override
  bool supports(TradeExecution execution) => _handler(execution) != null;

  @override
  bool supportsExternalSend(TradeExecution execution) {
    final matches = _matchingHandlers(execution);
    return matches.length == 1 && matches.single.supportsExternalSend(execution);
  }

  @override
  Future<PendingTransaction?> prepare({required WalletBase wallet, required Trade trade}) {
    final raw = trade.executionJson;
    if (raw == null || raw.isEmpty) return Future.value(null);
    late final TradeExecution execution;
    try {
      execution = TradeExecution.fromJsonString(raw);
    } catch (_) {
      return Future.value(null);
    }
    final handler = _handler(execution);
    if (handler == null) return Future.value(null);
    return handler.prepare(wallet: wallet, trade: trade, execution: execution);
  }
}

import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/amount/money.dart';

import 'trade.dart';
import 'trade_execution.dart';
import 'provider/pegaroute/pegaroute_execution_binding.dart';

abstract interface class TradeExecutionHandler {
  bool supports(TradeExecution execution);
  bool supportsExternalSend(TradeExecution execution);
  void validateForExecution({
    required WalletBase wallet,
    required Trade trade,
    required ValidatedTradeExecution execution,
    required DateTime now,
  });
  Future<PendingTransaction?> prepare({
    required WalletBase wallet,
    required Trade trade,
    required ValidatedTradeExecution execution,
  });
  Future<void> onCommitted({
    required WalletBase wallet,
    required Trade trade,
    required ValidatedTradeExecution execution,
    required PendingTransaction transaction,
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
    late final ValidatedTradeExecution validated;
    try {
      validated = const PegarouteExecutionBindingValidator().validatePersisted(
        trade: trade,
        wallet: wallet,
      );
      handler.validateForExecution(
        wallet: wallet,
        trade: trade,
        execution: validated,
        now: DateTime.now().toUtc(),
      );
    } catch (_) {
      return Future.value(null);
    }
    final prepared = handler.prepare(wallet: wallet, trade: trade, execution: validated);
    return prepared.then((transaction) {
      if (transaction == null) return null;
      return _BoundPendingTransaction(
        inner: transaction,
        wallet: wallet,
        trade: trade,
        handler: handler,
        validator: const PegarouteExecutionBindingValidator(),
        execution: validated,
      );
    });
  }
}

class _BoundPendingTransaction with PendingTransaction {
  _BoundPendingTransaction({
    required this.inner,
    required this.wallet,
    required this.trade,
    required this.handler,
    required this.validator,
    required this.execution,
  });

  final PendingTransaction inner;
  final WalletBase wallet;
  final Trade trade;
  final TradeExecutionHandler handler;
  final PegarouteExecutionBindingValidator validator;
  final ValidatedTradeExecution execution;

  ValidatedTradeExecution _validate() {
    final current = validator.validatePersisted(
      trade: trade,
      wallet: wallet,
      expectedRawExecutionJson: execution.rawExecutionJson,
    );
    handler.validateForExecution(
      wallet: wallet,
      trade: trade,
      execution: current,
      now: validator.now,
    );
    return current;
  }

  @override
  String get id => inner.id;

  @override
  Money get amount => inner.amount;

  @override
  Money get fee => inner.fee;

  @override
  Money? get additionalCost => inner.additionalCost;

  @override
  String get amountFormatted => inner.amountFormatted;

  @override
  String get feeFormatted => inner.feeFormatted;

  @override
  String get feeFormattedValue => inner.feeFormattedValue;

  @override
  String? get feeRate => inner.feeRate;

  @override
  set feeRate(String? value) => inner.feeRate = value;

  @override
  String get hex => inner.hex;

  @override
  String? get evmTxHashFromRawHex => inner.evmTxHashFromRawHex;

  @override
  int? get outputCount => inner.outputCount;

  @override
  PendingChange? get change => inner.change;

  @override
  set change(PendingChange? value) => inner.change = value;

  @override
  bool shouldCommitUR() => inner.shouldCommitUR();

  @override
  Future<void> commit() async {
    _validate();
    await inner.commit();
    late final ValidatedTradeExecution current;
    try {
      current = _validate();
    } on Object {
      // The broadcast succeeded, but a changed context must suppress follow-up I/O.
      return;
    }
    await handler.onCommitted(
      wallet: wallet,
      trade: trade,
      execution: current,
      transaction: inner,
    );
  }

  @override
  Future<Map<String, String>> commitUR() async {
    _validate();
    return inner.commitUR();
  }
}

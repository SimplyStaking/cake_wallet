import 'package:cw_core/pending_transaction.dart';
import 'dart:async';

import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/amount/money.dart';

import 'trade.dart';
import 'trade_execution.dart';
import 'provider/pegaroute/pegaroute_execution_binding.dart';

abstract interface class TradeExecutionHandler {
  bool supports(TradeExecution execution);
  bool supportsExternalSend(TradeExecution execution);
  void validateForExecution({required ValidatedTradeExecution execution, required DateTime now});
  Future<GuardedPendingTransaction?> prepare({required TradeExecutionGuard guard});
  Future<void> onCommitted({
    required ValidatedTradeExecution execution,
    required CommittedTradeExecution receipt,
  });
}

abstract interface class TradeExecutionLifecycleHandler {
  Future<void> beforeBroadcast({
    required ValidatedTradeExecution execution,
    required String executionHash,
  });

  Future<void> onBroadcasted({
    required ValidatedTradeExecution execution,
    required String executionHash,
  });

  Future<void> onBroadcastUnknown({
    required ValidatedTradeExecution execution,
    required String executionHash,
  });
}

final class TradeExecutionGuard {
  const TradeExecutionGuard._(this._validate, this._wallet);

  final ValidatedTradeExecution Function() _validate;

  ValidatedTradeExecution validate() => _validate();

  Future<T> withProviderIo<T>(
    FutureOr<T> Function(ValidatedTradeExecution execution) operation,
  ) async {
    final execution = _validate();
    try {
      return await operation(execution);
    } finally {
      _validate();
    }
  }

  Future<GuardedPendingTransaction?> withWalletConstruction(
    FutureOr<PendingTransaction?> Function(WalletBase wallet, ValidatedTradeExecution execution)
    operation,
  ) async {
    // Concrete handler activation must document wallet-internal async/ABA guarantees.
    final execution = _validate();
    late final PendingTransaction? pending;
    try {
      pending = await operation(_wallet, execution);
    } finally {
      _validate();
    }
    return pending == null ? null : GuardedPendingTransaction._(pending);
  }

  final WalletBase _wallet;
}

final class GuardedPendingTransaction {
  const GuardedPendingTransaction._(this._inner);

  final PendingTransaction _inner;
}

final class CommittedTradeExecution {
  const CommittedTradeExecution({
    required this.transactionId,
    required this.rawTransaction,
    required this.evmTxHash,
  });

  final String transactionId;
  final String rawTransaction;
  final String? evmTxHash;
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

  List<TradeExecutionHandler> _matchingHandlers(TradeExecution execution, {bool external = false}) {
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
      handler.validateForExecution(execution: validated, now: DateTime.now().toUtc());
    } catch (_) {
      return Future.value(null);
    }
    final validator = const PegarouteExecutionBindingValidator();
    final guard = TradeExecutionGuard._(() {
      final current = validator.validatePersisted(
        trade: trade,
        wallet: wallet,
        expectedRawExecutionJson: validated.rawExecutionJson,
      );
      handler.validateForExecution(execution: current, now: validator.now);
      return current;
    }, wallet);
    return _finishPrepare(handler: handler, guard: guard);
  }

  Future<PendingTransaction?> _finishPrepare({
    required TradeExecutionHandler handler,
    required TradeExecutionGuard guard,
  }) async {
    late final GuardedPendingTransaction? guarded;
    try {
      guarded = await handler.prepare(guard: guard);
    } catch (_) {
      return null;
    }
    if (guarded == null) return null;
    late final ValidatedTradeExecution current;
    try {
      current = guard.validate();
    } catch (_) {
      return null;
    }
    return _BoundPendingTransaction(
      inner: guarded._inner,
      handler: handler,
      guard: guard,
      execution: current,
    );
  }
}

class _BoundPendingTransaction with PendingTransaction {
  _BoundPendingTransaction({
    required this.inner,
    required this.handler,
    required this.guard,
    required this.execution,
  });

  final PendingTransaction inner;
  final TradeExecutionHandler handler;
  final TradeExecutionGuard guard;
  final ValidatedTradeExecution execution;
  bool _commitStarted = false;

  ValidatedTradeExecution _validate() => guard.validate();

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
  bool shouldCommitUR() => false;

  @override
  Future<void> commit() async {
    if (_commitStarted) {
      throw const PegarouteBindingException(
        'Pegaroute broadcast is already committed or ambiguous',
      );
    }
    _commitStarted = true;
    final before = _validate();
    final executionHash = inner.evmTxHashFromRawHex ?? inner.id;
    final lifecycle = handler is TradeExecutionLifecycleHandler
        ? handler as TradeExecutionLifecycleHandler
        : null;
    await lifecycle?.beforeBroadcast(execution: before, executionHash: executionHash);
    try {
      await inner.commit();
    } catch (_) {
      try {
        await lifecycle?.onBroadcastUnknown(execution: _validate(), executionHash: executionHash);
      } catch (_) {}
      try {
        _validate();
      } catch (_) {
        // A changed context must not trigger follow-up I/O after a failed send.
      }
      rethrow;
    }
    late final ValidatedTradeExecution current;
    try {
      current = _validate();
    } on Object {
      // The broadcast succeeded, but a changed context must suppress follow-up I/O.
      return;
    }
    try {
      await lifecycle?.onBroadcasted(execution: current, executionHash: executionHash);
    } on Object {
      // The network broadcast succeeded; lifecycle bookkeeping is best effort.
    }
    try {
      await handler.onCommitted(
        execution: current,
        receipt: CommittedTradeExecution(
          transactionId: inner.id,
          rawTransaction: inner.hex,
          evmTxHash: inner.evmTxHashFromRawHex,
        ),
      );
    } on Object {
      // Broadcast success must not become a user-visible send failure.
    }
  }

  @override
  Future<Map<String, String>> commitUR() async {
    throw const PegarouteBindingException('Pegaroute UR commit is unavailable');
  }
}

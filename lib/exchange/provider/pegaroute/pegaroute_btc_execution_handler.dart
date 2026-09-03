import 'dart:convert';

import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_handler_support.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cw_core/wallet_base.dart';

final class PegarouteBtcTransactionEvidence {
  PegarouteBtcTransactionEvidence({
    required this.rawHex,
    required this.transactionId,
    required this.chain,
    required this.destination,
    required this.amountBaseUnits,
    required this.paymentOutputCount,
    required List<List<int>> opReturnPayloads,
    required this.hasSilentPayment,
    required this.snapshot,
  }) : opReturnPayloads = List.unmodifiable(
          opReturnPayloads.map((payload) => List<int>.unmodifiable(payload)),
        );

  final String rawHex;
  final String transactionId;
  final String chain;
  final String destination;
  final String amountBaseUnits;
  final int paymentOutputCount;

  /// Strictly decoded OP_RETURN data pushes. The adapter must count every
  /// non-change, non-OP_RETURN output in [paymentOutputCount].
  final List<List<int>> opReturnPayloads;
  final bool hasSilentPayment;
  final PegarouteWalletSnapshot snapshot;
}

/// Adapter seam for the native Bitcoin wallet transaction decoder/builder.
/// No concrete adapter is registered until the native facade exposes all of
/// the evidence represented here.
abstract interface class PegarouteBtcWalletAdapter {
  Future<PegaroutePreparedTransaction<PegarouteBtcTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  });
}

final class PegarouteBtcExecutionHandler
    implements TradeExecutionHandler, TradeExecutionLifecycleHandler {
  const PegarouteBtcExecutionHandler({
    required this.walletContext,
    required this.adapter,
    this.lifecycleHandler,
  });

  final PegarouteWalletContext walletContext;
  final PegarouteBtcWalletAdapter adapter;
  final TradeExecutionLifecycleHandler? lifecycleHandler;

  @override
  bool supports(TradeExecution execution) =>
      execution.sourceChain == 'BTC' &&
      execution.sourceToken == 'BTC' &&
      execution.nativeToken == 'BTC' &&
      execution.family == 'utxo' &&
      execution.mode == 'payment-with-memo';

  @override
  bool supportsExternalSend(TradeExecution execution) => false;

  @override
  void validateForExecution({required ValidatedTradeExecution execution, required DateTime now}) {
    final value = execution.execution;
    if (value.sourceChain != 'BTC' ||
        value.sourceToken != 'BTC' ||
        value.nativeToken != 'BTC' ||
        value.family != 'utxo' ||
        value.mode != 'payment-with-memo' ||
        value.binding.isSendAll) {
      throw const PegarouteBindingException('BTC execution terms are not supported');
    }
    final payload = pegaroutePayload(execution);
    pegarouteRequireExactAmount(payload['amount'], value.binding);
    if (payload['to'] != pegarouteExpectedProviderTarget(execution)) {
      throw const PegarouteBindingException('BTC destination is not bound');
    }
    if (payload['memo'] != null &&
        (payload['memo'] is! String || (payload['memo'] as String).isEmpty)) {
      throw const PegarouteBindingException('BTC memo is invalid');
    }
  }

  @override
  Future<GuardedPendingTransaction?> prepare({required TradeExecutionGuard guard}) async {
    late final PegarouteWalletSnapshot before;
    late final PegaroutePreparedTransaction<PegarouteBtcTransactionEvidence> prepared;
    return guard.withWalletConstruction(
      (wallet, execution) async {
        before = walletContext.snapshot(wallet);
        pegarouteRequireBoundWalletSnapshot(execution, before);
        if (before.isHardwareWallet) {
          throw const PegarouteBindingException('BTC hardware-wallet execution is unavailable');
        }
        prepared = await adapter.prepare(
          wallet: wallet,
          snapshot: before,
          execution: execution,
        );
        return prepared.pending;
      },
      executionHash: (_) => prepared.evidence.transactionId,
      validatePrepared: (wallet, execution, pending) {
        final current = walletContext.snapshot(wallet);
        pegarouteRequireBoundWalletSnapshot(execution, current);
        if (!before.matches(current) || !identical(prepared.pending, pending)) {
          throw const PegarouteBindingException('BTC wallet context changed during preparation');
        }
        _validateEvidence(execution, before, prepared);
      },
    );
  }

  void _validateEvidence(
    ValidatedTradeExecution execution,
    PegarouteWalletSnapshot before,
    PegaroutePreparedTransaction<PegarouteBtcTransactionEvidence> prepared,
  ) {
    final evidence = prepared.evidence;
    final payload = pegaroutePayload(execution);
    final expectedMemo = payload['memo'] as String?;
    final expectedMemoBytes = expectedMemo == null ? null : utf8.encode(expectedMemo);
    final expectedTarget = pegarouteExpectedProviderTarget(execution);
    if (!before.matches(prepared.snapshot) ||
        !before.matches(evidence.snapshot) ||
        !pegarouteIsHex(evidence.rawHex) ||
        prepared.pending.hex != evidence.rawHex ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(evidence.transactionId) ||
        prepared.pending.id != evidence.transactionId ||
        evidence.chain != 'BTC' ||
        evidence.destination != expectedTarget ||
        evidence.amountBaseUnits != execution.execution.binding.sourceAmountBaseUnits ||
        evidence.paymentOutputCount != 1 ||
        evidence.hasSilentPayment ||
        evidence.opReturnPayloads.length > 1 ||
        evidence.opReturnPayloads.any((payload) => payload.any((byte) => byte < 0 || byte > 255)) ||
        (expectedMemoBytes == null && evidence.opReturnPayloads.isNotEmpty) ||
        (expectedMemoBytes != null &&
            (evidence.opReturnPayloads.length != 1 ||
                !_sameBytes(evidence.opReturnPayloads.single, expectedMemoBytes)))) {
      throw const PegarouteBindingException('decoded BTC transaction evidence is not exact');
    }
  }

  @override
  Future<void> onCommitted({
    required ValidatedTradeExecution execution,
    required CommittedTradeExecution receipt,
  }) async {}

  @override
  Future<void> beforeBroadcast({
    required ValidatedTradeExecution execution,
    required String executionHash,
    required int tradeInternalId,
  }) async {
    final lifecycle = lifecycleHandler;
    if (lifecycle == null) {
      throw const PegarouteBindingException('BTC lifecycle persistence is unavailable');
    }
    await lifecycle.beforeBroadcast(
      execution: execution,
      executionHash: executionHash,
      tradeInternalId: tradeInternalId,
    );
  }

  @override
  Future<void> onBroadcasted({
    required ValidatedTradeExecution execution,
    required String executionHash,
    required int tradeInternalId,
  }) async {
    final lifecycle = lifecycleHandler;
    if (lifecycle == null) return;
    await lifecycle.onBroadcasted(
      execution: execution,
      executionHash: executionHash,
      tradeInternalId: tradeInternalId,
    );
  }

  @override
  Future<void> onBroadcastUnknown({
    required ValidatedTradeExecution execution,
    required String executionHash,
    required int tradeInternalId,
  }) async {
    final lifecycle = lifecycleHandler;
    if (lifecycle == null) return;
    await lifecycle.onBroadcastUnknown(
      execution: execution,
      executionHash: executionHash,
      tradeInternalId: tradeInternalId,
    );
  }
}

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_handler_support.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cw_core/wallet_base.dart';

final class PegarouteBtcTransactionEvidence {
  const PegarouteBtcTransactionEvidence({
    required this.rawHex,
    required this.chain,
    required this.destination,
    required this.amountBaseUnits,
    required this.paymentOutputCount,
    required this.opReturnMemos,
    required this.hasSilentPayment,
    required this.snapshot,
  });

  final String rawHex;
  final String chain;
  final String destination;
  final String amountBaseUnits;
  final int paymentOutputCount;
  final List<String> opReturnMemos;
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
      execution.family == 'utxo' && execution.mode == 'payment-with-memo';

  @override
  bool supportsExternalSend(TradeExecution execution) => false;

  @override
  void validateForExecution({required ValidatedTradeExecution execution, required DateTime now}) {
    final value = execution.execution;
    if (value.sourceChain != 'BTC' ||
        value.sourceToken != 'BTC' ||
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
    if (payload['memo'] != null && payload['memo'] is! String) {
      throw const PegarouteBindingException('BTC memo is invalid');
    }
  }

  @override
  Future<GuardedPendingTransaction?> prepare({required TradeExecutionGuard guard}) async {
    return guard.withWalletConstruction((wallet, execution) async {
      final before = walletContext.snapshot(wallet);
      if (before.isHardwareWallet) {
        throw const PegarouteBindingException('BTC hardware-wallet execution is unavailable');
      }
      final prepared = await adapter.prepare(
        wallet: wallet,
        snapshot: before,
        execution: execution,
      );
      _validateEvidence(execution, before, prepared);
      return prepared.pending;
    });
  }

  void _validateEvidence(
    ValidatedTradeExecution execution,
    PegarouteWalletSnapshot before,
    PegaroutePreparedTransaction<PegarouteBtcTransactionEvidence> prepared,
  ) {
    final evidence = prepared.evidence;
    final payload = pegaroutePayload(execution);
    final expectedMemo = payload['memo'] as String?;
    final expectedTarget = pegarouteExpectedProviderTarget(execution);
    if (!before.matches(prepared.snapshot) ||
        !before.matches(evidence.snapshot) ||
        evidence.rawHex.isEmpty ||
        evidence.chain != 'BTC' ||
        evidence.destination != expectedTarget ||
        evidence.amountBaseUnits != execution.execution.binding.sourceAmountBaseUnits ||
        evidence.paymentOutputCount != 1 ||
        evidence.hasSilentPayment ||
        evidence.opReturnMemos.length > 1 ||
        (expectedMemo == null && evidence.opReturnMemos.isNotEmpty) ||
        (expectedMemo != null &&
            (evidence.opReturnMemos.length != 1 ||
                evidence.opReturnMemos.single != expectedMemo))) {
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
  }) async {
    final lifecycle = lifecycleHandler;
    if (lifecycle == null) {
      throw const PegarouteBindingException('BTC lifecycle persistence is unavailable');
    }
    await lifecycle.beforeBroadcast(execution: execution, executionHash: executionHash);
  }

  @override
  Future<void> onBroadcasted({
    required ValidatedTradeExecution execution,
    required String executionHash,
  }) async {
    final lifecycle = lifecycleHandler;
    if (lifecycle == null) return;
    await lifecycle.onBroadcasted(execution: execution, executionHash: executionHash);
  }

  @override
  Future<void> onBroadcastUnknown({
    required ValidatedTradeExecution execution,
    required String executionHash,
  }) async {
    final lifecycle = lifecycleHandler;
    if (lifecycle == null) return;
    await lifecycle.onBroadcastUnknown(execution: execution, executionHash: executionHash);
  }
}

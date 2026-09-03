import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_handler_support.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cw_core/wallet_base.dart';

final class PegarouteXmrTransactionEvidence {
  const PegarouteXmrTransactionEvidence({
    required this.chain,
    required this.destination,
    required this.amountBaseUnits,
    required this.paymentId,
    required this.memo,
    required this.snapshot,
  });

  final String chain;
  final String destination;
  final String amountBaseUnits;
  final String paymentId;
  final String? memo;
  final PegarouteWalletSnapshot snapshot;
}

abstract interface class PegarouteXmrWalletAdapter {
  Future<PegaroutePreparedTransaction<PegarouteXmrTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  });
}

final class PegarouteXmrExecutionHandler
    implements TradeExecutionHandler, TradeExecutionLifecycleHandler {
  const PegarouteXmrExecutionHandler({
    required this.walletContext,
    required this.adapter,
    this.lifecycleHandler,
  });

  final PegarouteWalletContext walletContext;
  final PegarouteXmrWalletAdapter adapter;
  final TradeExecutionLifecycleHandler? lifecycleHandler;

  @override
  bool supports(TradeExecution execution) =>
      execution.family == 'other' && execution.mode == 'deposit-transfer';

  @override
  bool supportsExternalSend(TradeExecution execution) => false;

  @override
  void validateForExecution({required ValidatedTradeExecution execution, required DateTime now}) {
    final value = execution.execution;
    if (value.sourceChain != 'XMR' ||
        value.sourceToken != 'XMR' ||
        value.nativeToken != 'XMR' ||
        value.family != 'other' ||
        value.mode != 'deposit-transfer' ||
        value.binding.isSendAll) {
      throw const PegarouteBindingException('XMR execution terms are not supported');
    }
    final payload = pegaroutePayload(execution);
    if (payload['chain'] != 'XMR' || payload['memo'] != null) {
      throw const PegarouteBindingException('XMR execution must be memo-free');
    }
    pegarouteRequireExactAmount(payload['amount'], value.binding);
    if (payload['to'] != pegarouteExpectedProviderTarget(execution)) {
      throw const PegarouteBindingException('XMR destination is not bound');
    }
  }

  @override
  Future<GuardedPendingTransaction?> prepare({required TradeExecutionGuard guard}) async {
    return guard.withWalletConstruction((wallet, execution) async {
      final before = walletContext.snapshot(wallet);
      if (before.isHardwareWallet) {
        throw const PegarouteBindingException('XMR hardware-wallet execution is unavailable');
      }
      final prepared = await adapter.prepare(
        wallet: wallet,
        snapshot: before,
        execution: execution,
      );
      final expectedTarget = pegarouteExpectedProviderTarget(execution);
      final payload = pegaroutePayload(execution);
      final amount = (payload['amount'] as Map)['baseUnits'];
      final evidence = prepared.evidence;
      if (!before.matches(prepared.snapshot) ||
          !before.matches(evidence.snapshot) ||
          evidence.chain != 'XMR' ||
          evidence.destination != expectedTarget ||
          evidence.amountBaseUnits != amount ||
          evidence.paymentId.isNotEmpty ||
          evidence.memo != null) {
        throw const PegarouteBindingException('XMR transaction evidence is not exact');
      }
      return prepared.pending;
    });
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
      throw const PegarouteBindingException('XMR lifecycle persistence is unavailable');
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

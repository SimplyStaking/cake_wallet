import 'package:cake_wallet/exchange/trade.dart';
import 'package:cw_core/wallet_base.dart';

import 'pegaroute_approval_store.dart';
import 'pegaroute_execution_binding.dart';
import 'pegaroute_execution_handler_support.dart';
import 'pegaroute_trusted_execution.dart';

enum PegaroutePreparationRetryAction { retryPreparation, checkApproval, continuePreparation }

/// Eligibility for re-entering preparation on the same confirmation sheet, not
/// permission to broadcast. Never infer "not submitted" from a UI error or a
/// missing Trade.txId: approval hashes and unknown funding live separately.
Future<PegaroutePreparationRetryAction?> pegaroutePreparationRetryAction({
  required Trade trade,
  required WalletBase wallet,
  DateTime Function()? clock,
}) async {
  final validator = PegarouteExecutionBindingValidator(clock: clock);
  final expected = validator.validatePersisted(trade: trade, wallet: wallet);
  final persisted = await Trade.getByTradeId(trade.id);
  if (persisted == null || trade.internalId <= 0 || persisted.internalId != trade.internalId) {
    return null;
  }
  final execution = validator.validatePersisted(
      trade: persisted, wallet: wallet, expectedRawExecutionJson: expected.rawExecutionJson);
  if (!pegarouteTrustedWallet(wallet) || !pegarouteTrustedExecution(execution.execution)) {
    return null;
  }
  pegarouteRequireUnexpiredFunding(execution, validator.now);
  // This transaction revalidates the stored execution and requires a created,
  // unfunded trade with no refund evidence and no funding lifecycle at all.
  // In particular, broadcasting/unknown/aborted markers must never be cleared.
  final approvals = await const PegarouteApprovalStore().read(execution);
  validator.validatePersisted(
      trade: trade, wallet: wallet, expectedRawExecutionJson: expected.rawExecutionJson);
  pegarouteRequireUnexpiredFunding(execution, validator.now);
  if (approvals.isEmpty) return PegaroutePreparationRetryAction.retryPreparation;
  if (execution.execution.payload['approval'] == null) return null;
  for (final approval in approvals) {
    if (!const {'reset', 'approve'}.contains(approval['step']) ||
        !const {'pending', 'confirmed'}.contains(approval['state']) ||
        approval['transactionHash'] is! String ||
        !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(approval['transactionHash'] as String)) {
      return null;
    }
  }
  if (approvals.any((approval) => approval['state'] == 'pending')) {
    return PegaroutePreparationRetryAction.checkApproval;
  }
  return PegaroutePreparationRetryAction.continuePreparation;
}

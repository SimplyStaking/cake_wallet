import 'package:cake_wallet/evm/evm.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/wallet_base.dart';

import 'pegaroute_approval_store.dart';
import 'pegaroute_execution_binding.dart';
import 'pegaroute_execution_handler_support.dart';
import 'pegaroute_native_eth.dart';
import 'pegaroute_trusted_execution.dart';

/// Ports Swaps.xyz's allowance -> optional USDT reset -> approve -> swap order.
/// Each returned approval is prepared only; the dispatcher confirms it separately.
final class PegarouteApprovalFlow {
  const PegarouteApprovalFlow({this.pollAttempts = 30, this.delay = Future<void>.delayed});
  final int pollAttempts;
  final Future<void> Function(Duration) delay;
  static const store = PegarouteApprovalStore();

  Future<PegarouteTrustedPending?> prepare(
      {required WalletBase wallet,
      required ValidatedTradeExecution execution,
      required TransactionPriority? priority,
      required void Function() validate}) async {
    final value = execution.execution;
    final approval = value.payload['approval'];
    if (value.family != 'evm' || value.mode != 'contract-call' || approval == null) return null;
    final data = approval as Map;
    final tokenAddress = data['tokenAddress'] as String;
    final spender = data['spender'] as String;
    final requiredAmount = BigInt.parse(value.binding.sourceAmountBaseUnits);
    if (requiredAmount <= BigInt.zero || requiredAmount.bitLength > 256) {
      throw const PegarouteBindingException('Unsupported approval amount');
    }
    validate();
    final rows = await store.read(execution);
    validate();
    for (final row in rows) {
      final state = row['state'];
      if (state == 'failed' || state == 'aborted')
        throw const TradeExecutionPrerequisiteException(
            'A previous approval did not complete. This swap has not been funded.');
      if (state != 'confirmed') {
        await confirm(
            wallet, execution, row['step'] as String, row['transactionHash'] as String, validate);
      }
    }
    final allowance =
        await evm!.getAllowance(wallet, tokenAddress, spender).timeout(const Duration(seconds: 6));
    validate();
    if (allowance == null)
      throw const TradeExecutionPrerequisiteException(
          'Token allowance is unavailable. Reopen this swap to check again.');
    if (allowance >= requiredAmount) return null;
    if (rows.any((row) => row['step'] == 'approve')) {
      throw const TradeExecutionPrerequisiteException(
          'The confirmed approval no longer covers this swap. No swap payment was submitted.');
    }
    final reset = value.binding.walletChainId == 1 &&
        tokenAddress.toLowerCase() == '0xdac17f958d2ee523a2206206994597c13d831ec7' &&
        allowance > BigInt.zero;
    if (reset && rows.any((row) => row['step'] == 'reset')) {
      throw const TradeExecutionPrerequisiteException('Token allowance changed after its reset.');
    }
    final step = reset ? 'reset' : 'approve';
    final units = reset ? BigInt.zero : requiredAmount;
    final symbol = value.sourceToken.split('-').first;
    final token = Erc20Token(
        name: symbol,
        symbol: symbol,
        contractAddress: tokenAddress,
        decimal: value.binding.sourceDecimals,
        chainId: value.binding.walletChainId);
    final amount = Money(units, token);
    final pending = await evm!
        .createTokenApproval(wallet, amount, spender, priority, useBlinkProtection: false);
    validate();
    final evidence = inspectPegarouteEvm(
        pending.hex,
        PegarouteWalletSnapshot(
            walletId: value.binding.walletId,
            address: value.binding.walletAddress,
            chainId: value.binding.walletChainId,
            generation: 0,
            isHardwareWallet: false));
    final expectedData = '0x095ea7b3${spender.substring(2).toLowerCase().padLeft(64, '0')}'
        '${units.toRadixString(16).padLeft(64, '0')}';
    // Cake's approval builder resolves by symbol internally. Bind the actual
    // signed token contract as well as spender/units, preserving canonical identity.
    if (evidence.to.toLowerCase() != tokenAddress.toLowerCase() ||
        evidence.valueBaseUnits != '0' ||
        evidence.data?.toLowerCase() != expectedData) {
      throw const PegarouteBindingException('Signed approval differs from bound instructions');
    }
    return _ApprovalPending(
        pending: PegarouteTrustedPending(pending, amount: amount),
        flow: this,
        wallet: wallet,
        execution: execution,
        step: step,
        description:
            reset ? 'Reset $symbol allowance to 0' : 'Approve ${amount.toStringWithSymbol()}');
  }

  Future<void> confirm(WalletBase wallet, ValidatedTradeExecution execution, String step,
      String hash, void Function() validate) async {
    final watch = Stopwatch()..start();
    for (var attempt = 0; attempt < pollAttempts; attempt++) {
      final remaining = 30000 - watch.elapsedMilliseconds;
      if (remaining <= 0) break;
      validate();
      bool? receipt;
      try {
        receipt = await evm!
            .getTransactionReceipt(wallet, hash)
            .timeout(Duration(milliseconds: remaining < 6000 ? remaining : 6000));
      } catch (_) {/* An unavailable receipt is pending, never permission to resend. */}
      validate();
      if (receipt != null) {
        await store.finish(execution, step, hash, receipt ? 'confirmed' : 'failed');
        validate();
        if (!receipt)
          throw const TradeExecutionPrerequisiteException(
              'The approval transaction failed on-chain. This swap has not been funded.');
        return;
      }
      if (attempt + 1 < pollAttempts) await delay(const Duration(seconds: 1));
    }
    throw const TradeExecutionPrerequisiteException(
        'Approval confirmation is still pending. Reopen this swap to check it; no swap payment was submitted.');
  }
}

final class _ApprovalPending extends PegarouteTrustedPending implements TradeExecutionPrerequisite {
  _ApprovalPending(
      {required PegarouteTrustedPending pending,
      required this.flow,
      required this.wallet,
      required this.execution,
      required this.step,
      required this.description})
      : super(pending.inner, amount: pending.amount);
  final PegarouteApprovalFlow flow;
  final WalletBase wallet;
  final ValidatedTradeExecution execution;
  final String step;
  @override
  final String description;

  @override
  Future<void> commit() => throw StateError('Approval requires the guarded confirmation flow');

  @override
  Future<void> commitPrerequisite(void Function() validate) async {
    validate();
    await PegarouteApprovalFlow.store.begin(execution, step, id);
    try {
      validate();
    } catch (_) {
      await PegarouteApprovalFlow.store.finish(execution, step, id, 'aborted');
      rethrow;
    }
    try {
      await super.commit();
    } catch (_) {
      // The pre-broadcast hash survives an ambiguous submission; reconcile it
      // on reopening rather than constructing another transaction with a new nonce.
      throw const TradeExecutionPrerequisiteException(
          'Approval submission is unconfirmed. Reopen this swap to check its transaction.');
    }
    await flow.confirm(wallet, execution, step, id, validate);
  }
}

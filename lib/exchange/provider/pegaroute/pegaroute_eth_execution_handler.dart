import 'dart:convert';

import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_handler_support.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cw_core/wallet_base.dart';

final class PegarouteEvmDepositWithExpiryEvidence {
  const PegarouteEvmDepositWithExpiryEvidence({
    required this.router,
    required this.vault,
    required this.asset,
    required this.amountBaseUnits,
    required this.memo,
    required this.expiry,
    required this.destinationAddress,
    required this.refundAddress,
  });

  final String router;
  final String vault;
  final String asset;
  final String amountBaseUnits;
  final String memo;
  final int expiry;
  final String destinationAddress;
  final String? refundAddress;
}

final class PegarouteEthTransactionEvidence {
  const PegarouteEthTransactionEvidence({
    required this.rawHex,
    required this.chainId,
    required this.to,
    required this.valueBaseUnits,
    required this.data,
    required this.gasLimit,
    required this.approvalPresent,
    required this.transactionHash,
    required this.snapshot,
    this.depositWithExpiry,
  });

  final String rawHex;
  final int chainId;
  final String to;
  final String valueBaseUnits;
  final String? data;
  final String? gasLimit;
  final bool approvalPresent;
  final String transactionHash;
  final PegarouteWalletSnapshot snapshot;
  final PegarouteEvmDepositWithExpiryEvidence? depositWithExpiry;
}

/// Adapter seam for an EVM wallet that returns decoded signed-transaction
/// evidence. Opaque calldata is intentionally not accepted by this handler.
abstract interface class PegarouteEthWalletAdapter {
  Future<PegaroutePreparedTransaction<PegarouteEthTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  });
}

final class PegarouteEthExecutionHandler
    implements TradeExecutionHandler, TradeExecutionLifecycleHandler {
  const PegarouteEthExecutionHandler({
    required this.walletContext,
    required this.adapter,
    this.lifecycleHandler,
  });

  final PegarouteWalletContext walletContext;
  final PegarouteEthWalletAdapter adapter;
  final TradeExecutionLifecycleHandler? lifecycleHandler;

  @override
  bool supports(TradeExecution execution) =>
      execution.family == 'evm' &&
      (execution.mode == 'native-transfer' || execution.mode == 'contract-call');

  @override
  bool supportsExternalSend(TradeExecution execution) => false;

  @override
  void validateForExecution({required ValidatedTradeExecution execution, required DateTime now}) {
    final value = execution.execution;
    if (value.sourceChain != 'ETH' ||
        value.sourceToken != 'ETH' ||
        value.binding.walletChainId != 1 ||
        value.binding.isSendAll) {
      throw const PegarouteBindingException('native ETH execution terms are not supported');
    }
    final payload = pegaroutePayload(execution);
    if (value.mode == 'native-transfer') {
      if (payload['data'] != null ||
          payload['approval'] != null ||
          payload['transferAmount'] != null) {
        throw const PegarouteBindingException('native ETH transfer contains call fields');
      }
    } else if (value.mode == 'contract-call') {
      final provider = _reviewedRoute(execution)['provider'];
      if (provider != 'thorchain' && provider != 'maya') {
        throw const PegarouteBindingException('opaque ETH contract call is unavailable');
      }
      if (payload['approval'] != null || payload['transferAmount'] != null) {
        throw const PegarouteBindingException('native ETH contract call contains token fields');
      }
    }
    if (payload['to'] != _expectedEthTarget(execution)) {
      throw const PegarouteBindingException('ETH destination is not bound');
    }
    pegarouteRequireExactAmount(payload['value'], value.binding);
  }

  @override
  Future<GuardedPendingTransaction?> prepare({required TradeExecutionGuard guard}) async {
    return guard.withWalletConstruction((wallet, execution) async {
      final before = walletContext.snapshot(wallet);
      if (before.isHardwareWallet || before.chainId != 1) {
        throw const PegarouteBindingException('ETH wallet context is unavailable');
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
    PegaroutePreparedTransaction<PegarouteEthTransactionEvidence> prepared,
  ) {
    final evidence = prepared.evidence;
    final value = execution.execution;
    final payload = pegaroutePayload(execution);
    final target = _expectedEthTarget(execution);
    final expectedValue = (payload['value'] as Map)['baseUnits'] as String;
    if (!before.matches(prepared.snapshot) ||
        !before.matches(evidence.snapshot) ||
        evidence.rawHex.isEmpty ||
        !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(evidence.transactionHash) ||
        evidence.chainId != 1 ||
        evidence.to != target ||
        evidence.valueBaseUnits != expectedValue ||
        evidence.approvalPresent ||
        evidence.data != payload['data'] ||
        evidence.gasLimit != payload['gasLimit']) {
      throw const PegarouteBindingException('decoded ETH transaction evidence is not exact');
    }

    if (value.mode == 'native-transfer') {
      if (evidence.depositWithExpiry != null) {
        throw const PegarouteBindingException('native ETH transfer has call semantics');
      }
      return;
    }

    final call = evidence.depositWithExpiry;
    final route = _reviewedRoute(execution);
    final routeExpiry = _routeExpiry(route['expiry']);
    final expectedMemo = route['memo'];
    if (call == null ||
        call.router != target ||
        call.vault != route['inboundAddress'] ||
        call.asset != '0x0000000000000000000000000000000000000000' ||
        call.amountBaseUnits != execution.execution.binding.sourceAmountBaseUnits ||
        expectedMemo is! String ||
        call.memo != expectedMemo ||
        routeExpiry == null ||
        routeExpiry.millisecondsSinceEpoch % 1000 != 0 ||
        call.expiry != routeExpiry.millisecondsSinceEpoch ~/ 1000 ||
        call.expiry <= DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 ||
        call.destinationAddress != execution.execution.binding.destinationAddress ||
        !_sameOptional(call.refundAddress, execution.execution.binding.refundAddress)) {
      throw const PegarouteBindingException('ETH depositWithExpiry evidence is not bound');
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
      throw const PegarouteBindingException('ETH lifecycle persistence is unavailable');
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

String _expectedEthTarget(ValidatedTradeExecution execution) {
  final route = _reviewedRoute(execution);
  if (execution.execution.mode == 'contract-call') {
    final router = route['router'];
    if (router is String && router.isNotEmpty) return router;
  }
  return pegarouteExpectedProviderTarget(execution);
}

Map<String, dynamic> _reviewedRoute(ValidatedTradeExecution execution) {
  final decoded = jsonDecode(execution.execution.binding.reviewedRouteJson);
  if (decoded is! Map) throw const PegarouteBindingException('reviewed route is invalid');
  return Map<String, dynamic>.from(decoded);
}

DateTime? _routeExpiry(Object? value) {
  if (value is! Map) return null;
  try {
    return TradeExecutionExpiry.fromJson(value).instant();
  } on FormatException {
    return null;
  }
}

bool _sameOptional(String? first, String? second) =>
    (first == null || first.isEmpty) && (second == null || second.isEmpty) || first == second;

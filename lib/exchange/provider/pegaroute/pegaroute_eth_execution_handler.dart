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
    required this.destinationChain,
    required this.destinationToken,
    required this.destinationAddress,
    required this.refundAddress,
  });

  final String router;
  final String vault;
  final String asset;
  final String amountBaseUnits;
  final String memo;
  final int expiry;
  final String destinationChain;
  final String destinationToken;
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
      execution.sourceChain == 'ETH' &&
      execution.sourceToken == 'ETH' &&
      execution.nativeToken == 'ETH' &&
      execution.binding.walletChainId == 1 &&
      execution.family == 'evm' &&
      (execution.mode == 'native-transfer' ||
          execution.mode == 'contract-call' &&
              (execution.routeProvider == 'thorchain' || execution.routeProvider == 'maya'));

  @override
  bool supportsExternalSend(TradeExecution execution) => false;

  @override
  void validateForExecution({required ValidatedTradeExecution execution, required DateTime now}) {
    final value = execution.execution;
    final payload = pegaroutePayload(execution);
    if (value.sourceChain != 'ETH' ||
        value.sourceToken != 'ETH' ||
        value.nativeToken != 'ETH' ||
        value.binding.walletChainId != 1 ||
        payload['chainId'] != 1 ||
        value.family != 'evm' ||
        (value.mode != 'native-transfer' && value.mode != 'contract-call') ||
        value.binding.isSendAll) {
      throw const PegarouteBindingException('native ETH execution terms are not supported');
    }
    if (value.mode == 'native-transfer') {
      if (payload['data'] != null ||
          payload['memo'] != null ||
          payload['approval'] != null ||
          payload['transferAmount'] != null) {
        throw const PegarouteBindingException('native ETH transfer contains call fields');
      }
    } else if (value.mode == 'contract-call') {
      final provider = _reviewedRoute(execution)['provider'];
      if (provider != 'thorchain' && provider != 'maya') {
        throw const PegarouteBindingException('opaque ETH contract call is unavailable');
      }
      if (payload['memo'] is! String ||
          (payload['memo'] as String).isEmpty ||
          payload['approval'] != null ||
          payload['transferAmount'] != null) {
        throw const PegarouteBindingException('native ETH contract call contains token fields');
      }
      _validateContractCallIntent(execution, now);
    }
    if (payload['to'] is! String ||
        !pegarouteSameAddress('ETH', payload['to'] as String, _expectedEthTarget(execution))) {
      throw const PegarouteBindingException('ETH destination is not bound');
    }
    pegarouteRequireExactAmount(payload['value'], value.binding);
  }

  @override
  Future<GuardedPendingTransaction?> prepare({required TradeExecutionGuard guard}) async {
    late final PegarouteWalletSnapshot before;
    late final PegaroutePreparedTransaction<PegarouteEthTransactionEvidence> prepared;
    return guard.withWalletConstruction(
      (wallet, execution) async {
        before = walletContext.snapshot(wallet);
        pegarouteRequireBoundWalletSnapshot(execution, before);
        if (before.isHardwareWallet || before.chainId != 1) {
          throw const PegarouteBindingException('ETH wallet context is unavailable');
        }
        prepared = await adapter.prepare(
          wallet: wallet,
          snapshot: before,
          execution: execution,
        );
        return prepared.pending;
      },
      executionHash: (_) => prepared.evidence.transactionHash,
      validatePrepared: (wallet, execution, pending) {
        final current = walletContext.snapshot(wallet);
        pegarouteRequireBoundWalletSnapshot(execution, current);
        if (!before.matches(current) || !identical(prepared.pending, pending)) {
          throw const PegarouteBindingException('ETH wallet context changed during preparation');
        }
        _validateEvidence(execution, before, prepared);
      },
    );
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
        !pegarouteIsHex(evidence.rawHex) ||
        prepared.pending.hex != evidence.rawHex ||
        !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(evidence.transactionHash) ||
        prepared.pending.evmTxHashFromRawHex != evidence.transactionHash ||
        evidence.chainId != 1 ||
        !pegarouteSameAddress('ETH', evidence.to, target) ||
        evidence.valueBaseUnits != expectedValue ||
        evidence.approvalPresent ||
        !_sameHex(evidence.data, payload['data']) ||
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
    final decodedCall = decodePegarouteDepositWithExpiryCalldata(payload['data']);
    final decodedIntent = _decodeThorMayaMemo(decodedCall.memo);
    if (call == null ||
        !pegarouteSameAddress('ETH', call.router, target) ||
        route['inboundAddress'] is! String ||
        !pegarouteSameAddress('ETH', call.vault, route['inboundAddress'] as String) ||
        !pegarouteSameAddress(
          'ETH',
          call.asset,
          '0x0000000000000000000000000000000000000000',
        ) ||
        call.amountBaseUnits != execution.execution.binding.sourceAmountBaseUnits ||
        expectedMemo is! String ||
        call.memo != expectedMemo ||
        !_sameDepositCall(call, decodedCall) ||
        decodedIntent == null ||
        decodedIntent.destinationChain != call.destinationChain ||
        decodedIntent.destinationToken != call.destinationToken ||
        !pegarouteSameAddress(
          call.destinationChain,
          decodedIntent.destinationAddress,
          call.destinationAddress,
        ) ||
        !_sameOptionalAddress(
          execution.execution.sourceChain,
          decodedIntent.refundAddress,
          call.refundAddress,
        ) ||
        routeExpiry == null ||
        routeExpiry.millisecondsSinceEpoch % 1000 != 0 ||
        call.expiry != routeExpiry.millisecondsSinceEpoch ~/ 1000 ||
        call.destinationChain != execution.execution.destinationChain ||
        call.destinationToken != execution.execution.destinationToken ||
        !pegarouteSameAddress(
          execution.execution.destinationChain,
          call.destinationAddress,
          execution.execution.binding.destinationAddress,
        ) ||
        !_sameOptionalAddress(
          execution.execution.sourceChain,
          call.refundAddress,
          execution.execution.binding.refundAddress,
        )) {
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
    required int tradeInternalId,
  }) async {
    final lifecycle = lifecycleHandler;
    if (lifecycle == null) {
      throw const PegarouteBindingException('ETH lifecycle persistence is unavailable');
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

void _validateContractCallIntent(ValidatedTradeExecution execution, DateTime now) {
  final value = execution.execution;
  final payload = pegaroutePayload(execution);
  final route = _reviewedRoute(execution);
  final decoded = decodePegarouteDepositWithExpiryCalldata(payload['data']);
  final intent = _decodeThorMayaMemo(decoded.memo);
  final routeExpiry = _routeExpiry(route['expiry']);
  final routeMemo = route['memo'];
  if (route['inboundAddress'] is! String ||
      !pegarouteSameAddress('ETH', decoded.vault, route['inboundAddress'] as String) ||
      !pegarouteSameAddress(
        'ETH',
        decoded.asset,
        '0x0000000000000000000000000000000000000000',
      ) ||
      decoded.amountBaseUnits != value.binding.sourceAmountBaseUnits ||
      routeMemo is! String ||
      decoded.memo != routeMemo ||
      decoded.memo != payload['memo'] ||
      routeExpiry == null ||
      routeExpiry.millisecondsSinceEpoch % 1000 != 0 ||
      decoded.expiry != routeExpiry.millisecondsSinceEpoch ~/ 1000 ||
      !now.toUtc().isBefore(routeExpiry) ||
      intent == null ||
      intent.destinationChain != value.destinationChain ||
      intent.destinationToken != value.destinationToken ||
      !pegarouteSameAddress(
        value.destinationChain,
        intent.destinationAddress,
        value.binding.destinationAddress,
      ) ||
      !_sameOptionalAddress(
        value.sourceChain,
        intent.refundAddress,
        value.binding.refundAddress,
      )) {
    throw const PegarouteBindingException('ETH depositWithExpiry intent is not bound');
  }
}

bool _sameHex(Object? first, Object? second) {
  if (first == null || second == null) return first == second;
  if (first is! String || second is! String) return false;
  return first.toLowerCase() == second.toLowerCase();
}

bool _sameOptionalAddress(String chain, String? first, String? second) {
  if ((first == null || first.isEmpty) && (second == null || second.isEmpty)) return true;
  if (first == null || second == null) return false;
  return pegarouteSameAddress(chain, first, second);
}

final class PegarouteDecodedDepositWithExpiry {
  const PegarouteDecodedDepositWithExpiry({
    required this.vault,
    required this.asset,
    required this.amountBaseUnits,
    required this.memo,
    required this.expiry,
  });

  final String vault;
  final String asset;
  final String amountBaseUnits;
  final String memo;
  final int expiry;
}

final class _DecodedThorMayaMemo {
  const _DecodedThorMayaMemo({
    required this.destinationChain,
    required this.destinationToken,
    required this.destinationAddress,
    required this.refundAddress,
  });

  final String destinationChain;
  final String destinationToken;
  final String destinationAddress;
  final String? refundAddress;
}

PegarouteDecodedDepositWithExpiry decodePegarouteDepositWithExpiryCalldata(Object? value) {
  if (value is! String || !value.startsWith('0x') || !pegarouteIsHex(value)) {
    throw const PegarouteBindingException('ETH depositWithExpiry calldata is invalid');
  }
  final hex = value.substring(2).toLowerCase();
  const selectorLength = 8;
  const wordLength = 64;
  const headWords = 5;
  const memoOffsetBytes = headWords * 32;
  if (hex.length < selectorLength + (headWords + 1) * wordLength ||
      hex.substring(0, selectorLength) != '44bc937b') {
    throw const PegarouteBindingException('ETH depositWithExpiry selector is invalid');
  }
  final args = hex.substring(selectorLength);
  String word(int index) => args.substring(index * wordLength, (index + 1) * wordLength);
  String addressWord(int index) {
    final encoded = word(index);
    if (encoded.substring(0, 24) != '000000000000000000000000') {
      throw const PegarouteBindingException('ETH depositWithExpiry address is invalid');
    }
    return '0x${encoded.substring(24)}';
  }

  BigInt uintWord(int index) => BigInt.parse(word(index), radix: 16);
  final offset = uintWord(3);
  if (offset != BigInt.from(memoOffsetBytes)) {
    throw const PegarouteBindingException('ETH depositWithExpiry memo offset is invalid');
  }
  final memoLength = uintWord(headWords);
  if (memoLength > BigInt.from(1 << 20)) {
    throw const PegarouteBindingException('ETH depositWithExpiry memo is too large');
  }
  final memoByteLength = memoLength.toInt();
  final paddedMemoBytes = ((memoByteLength + 31) ~/ 32) * 32;
  final expectedArgsHexLength = (headWords + 1) * wordLength + paddedMemoBytes * 2;
  if (args.length != expectedArgsHexLength) {
    throw const PegarouteBindingException('ETH depositWithExpiry calldata length is invalid');
  }
  final memoStart = (headWords + 1) * wordLength;
  final memoEnd = memoStart + memoByteLength * 2;
  if (args.substring(memoEnd).split('').any((value) => value != '0')) {
    throw const PegarouteBindingException('ETH depositWithExpiry memo padding is invalid');
  }
  late final String memo;
  try {
    final bytes = <int>[
      for (var index = memoStart; index < memoEnd; index += 2)
        int.parse(args.substring(index, index + 2), radix: 16),
    ];
    memo = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw const PegarouteBindingException('ETH depositWithExpiry memo is not UTF-8');
  }
  final expiry = uintWord(4);
  if (expiry > BigInt.from(0x7fffffffffffffff)) {
    throw const PegarouteBindingException('ETH depositWithExpiry expiry is invalid');
  }
  return PegarouteDecodedDepositWithExpiry(
    vault: addressWord(0),
    asset: addressWord(1),
    amountBaseUnits: uintWord(2).toString(),
    memo: memo,
    expiry: expiry.toInt(),
  );
}

_DecodedThorMayaMemo? _decodeThorMayaMemo(String memo) {
  final parts = memo.trim().split(':');
  final action = parts[0].toLowerCase();
  if (action != '=' && action != 's' && action != 'swap') return null;
  if (parts.length < 3) return null;
  final asset = parts[1].trim();
  final separator = asset.indexOf('.');
  // Provider shorthand is intentionally not guessed in Cake. A future
  // contract can supply a canonical decoded intent for those routes.
  if (separator <= 0 || separator == asset.length - 1) return null;
  final addressField = parts[2].trim();
  final refundSeparator = addressField.indexOf('/');
  final destination =
      (refundSeparator < 0 ? addressField : addressField.substring(0, refundSeparator)).trim();
  final refund = refundSeparator < 0 ? null : addressField.substring(refundSeparator + 1).trim();
  if (destination.isEmpty || refund == '') return null;
  return _DecodedThorMayaMemo(
    destinationChain: asset.substring(0, separator),
    destinationToken: asset.substring(separator + 1),
    destinationAddress: destination,
    refundAddress: refund,
  );
}

bool _sameDepositCall(
  PegarouteEvmDepositWithExpiryEvidence evidence,
  PegarouteDecodedDepositWithExpiry decoded,
) =>
    pegarouteSameAddress('ETH', evidence.vault, decoded.vault) &&
    pegarouteSameAddress('ETH', evidence.asset, decoded.asset) &&
    evidence.amountBaseUnits == decoded.amountBaseUnits &&
    evidence.memo == decoded.memo &&
    evidence.expiry == decoded.expiry;

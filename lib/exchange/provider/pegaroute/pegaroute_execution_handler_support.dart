import 'dart:convert';

import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/wallet_base.dart';

/// The wallet adapter must provide a monotonic generation. A value-only
/// snapshot is insufficient to detect an ABA wallet/chain switch.
abstract interface class PegarouteWalletContext {
  PegarouteWalletSnapshot snapshot(WalletBase wallet);
}

final class PegarouteWalletSnapshot {
  const PegarouteWalletSnapshot({
    required this.walletId,
    required this.address,
    required this.chainId,
    required this.generation,
    required this.isHardwareWallet,
  });

  final String walletId;
  final String address;
  final int? chainId;
  final int generation;
  final bool isHardwareWallet;

  bool matches(PegarouteWalletSnapshot other) =>
      walletId == other.walletId &&
      address == other.address &&
      chainId == other.chainId &&
      generation == other.generation &&
      isHardwareWallet == other.isHardwareWallet;
}

final class PegaroutePreparedTransaction<E> {
  const PegaroutePreparedTransaction({
    required this.pending,
    required this.evidence,
    required this.snapshot,
  });

  final PendingTransaction pending;
  final E evidence;
  final PegarouteWalletSnapshot snapshot;
}

void pegarouteRequireBoundWalletSnapshot(
  ValidatedTradeExecution execution,
  PegarouteWalletSnapshot snapshot,
) {
  final binding = execution.execution.binding;
  if (snapshot.walletId.isEmpty ||
      snapshot.address.isEmpty ||
      snapshot.generation < 0 ||
      snapshot.walletId != binding.walletId ||
      snapshot.chainId != binding.walletChainId ||
      !pegarouteSameAddress(
          execution.execution.sourceChain, snapshot.address, binding.walletAddress)) {
    throw const PegarouteBindingException('wallet generation snapshot is not bound');
  }
}

bool pegarouteSameAddress(String chain, String first, String second) {
  if (_evmChains.contains(chain)) return first.toLowerCase() == second.toLowerCase();
  return first == second;
}

bool pegarouteIsHex(String value, {bool allow0x = true}) {
  final raw =
      allow0x && (value.startsWith('0x') || value.startsWith('0X')) ? value.substring(2) : value;
  return raw.isNotEmpty && raw.length.isEven && RegExp(r'^[0-9a-fA-F]+$').hasMatch(raw);
}

String pegarouteExpectedProviderTarget(ValidatedTradeExecution execution) {
  final binding = execution.execution.binding;
  if (binding.providerDepositAddress?.isNotEmpty == true) {
    return binding.providerDepositAddress!;
  }
  final route = _reviewedRoute(binding.reviewedRouteJson);
  final inbound = route['inboundAddress'];
  if (inbound is String && inbound.isNotEmpty) return inbound;
  throw const PegarouteBindingException('provider deposit target is not bound');
}

Map<String, dynamic> pegaroutePayload(ValidatedTradeExecution execution) =>
    Map<String, dynamic>.from(execution.execution.payload);

void pegarouteRequireExactAmount(Object? value, TradeExecutionBinding binding) {
  if (value is! Map ||
      value['display'] != binding.sourceAmount ||
      value['baseUnits'] != binding.sourceAmountBaseUnits) {
    throw const PegarouteBindingException('prepared transaction amount is not exact');
  }
}

Map<String, dynamic> _reviewedRoute(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) throw const PegarouteBindingException('reviewed route is invalid');
  return Map<String, dynamic>.from(decoded);
}

const _evmChains = {'ETH', 'BSC', 'POLYGON', 'AVAX', 'ARBITRUM', 'BASE'};

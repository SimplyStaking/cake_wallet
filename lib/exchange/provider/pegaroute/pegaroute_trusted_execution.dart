import 'package:cake_wallet/evm/evm.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/output_info.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:web3dart/crypto.dart';

import 'pegaroute_api.dart';
import 'pegaroute_currency_mapper.dart';
import 'pegaroute_execution_binding.dart';
import 'pegaroute_execution_handler_support.dart';
import 'pegaroute_execution_lifecycle_store.dart';
import 'pegaroute_native_eth.dart';

const pegarouteEvmChains = {'ETH': 1, 'BSC': 56, 'BASE': 8453, 'ARBITRUM': 42161, 'POLYGON': 137};
const _evmWalletTypes = {
  WalletType.ethereum,
  WalletType.bsc,
  WalletType.base,
  WalletType.arbitrum,
  WalletType.polygon,
};
const _evmNativeCurrencies = {
  'ETH': CryptoCurrency.eth,
  'BSC': CryptoCurrency.bnb,
  'BASE': CryptoCurrency.baseEth,
  'ARBITRUM': CryptoCurrency.arbEth,
  'POLYGON': CryptoCurrency.maticpoly,
};

bool pegarouteTrustedWallet(WalletBase? wallet) =>
    wallet != null &&
    !wallet.isHardwareWallet &&
    wallet.isSoftwareWallet &&
    _evmWalletTypes.contains(wallet.type) &&
    pegarouteEvmChains.containsValue(wallet.chainId);

bool pegarouteTrustedSource(WalletBase? wallet, PegarouteAssetId source) =>
    pegarouteTrustedWallet(wallet) && pegarouteEvmChains[source.chain] == wallet!.chainId;

/// Selection covers transaction shapes Cake can construct, not provider routing policy.
bool pegarouteTrustedQuote(PegarouteAssetId source, PegarouteRoute route) {
  if (route.privateValue?.isEnabled ?? false) return false;
  if (!pegarouteEvmChains.containsKey(source.chain)) return false;
  if (route.provider == 'instaswap') return route.memo == null && route.router == null;
  return source.token == source.nativeToken &&
      const {'thorchain', 'maya', 'openocean'}.contains(route.provider);
}

bool pegarouteTrustedExecution(TradeExecution execution) {
  if (execution.privateIntent != false ||
      execution.binding.isSendAll ||
      execution.payload['approval'] != null ||
      execution.family != 'evm' ||
      !pegarouteEvmChains.containsKey(execution.sourceChain) ||
      pegarouteEvmChains[execution.sourceChain] != execution.binding.walletChainId ||
      execution.payload['chainId'] != execution.binding.walletChainId ||
      !const {'instaswap', 'thorchain', 'maya', 'openocean'}.contains(execution.routeProvider) ||
      !RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(execution.payload['to']?.toString() ?? ''))
    return false;
  final native = execution.sourceToken == execution.nativeToken;
  switch (execution.mode) {
    case 'native-transfer':
      return native &&
          execution.payload['data'] == null &&
          execution.payload['memo'] == null &&
          execution.payload['transferAmount'] == null;
    case 'contract-call':
      return native &&
          execution.routeProvider != 'instaswap' &&
          execution.payload['transferAmount'] == null &&
          pegarouteIsHex(execution.payload['data']?.toString() ?? '');
    case 'erc20-transfer':
      return !native &&
          execution.routeProvider == 'instaswap' &&
          execution.payload['memo'] == null &&
          execution.payload['data'] == null &&
          RegExp(r'^[^-]+-0x[0-9a-fA-F]{40}$').hasMatch(execution.sourceToken);
    default:
      return false;
  }
}

/// The authenticated provider owns contract/memo semantics. Cake owns wallet
/// construction, confirmation, network selection and immutable pending bytes.
class PegarouteTrustedWalletAdapter {
  const PegarouteTrustedWalletAdapter({required this.priority});
  final TransactionPriority? Function(WalletBase) priority;

  Future<PegarouteTrustedPending> prepare(WalletBase wallet, TradeExecution execution) async {
    if (!pegarouteTrustedExecution(execution) ||
        !pegarouteTrustedWallet(wallet) ||
        wallet.chainId != execution.binding.walletChainId ||
        evm == null) {
      throw const PegarouteBindingException('Unsupported Pegaroute wallet operation');
    }
    final nativeCurrency = _evmNativeCurrencies[execution.sourceChain]!;
    final units = BigInt.parse(execution.binding.sourceAmountBaseUnits);
    if (units <= BigInt.zero || units.bitLength > 256) {
      throw const PegarouteBindingException('Unsupported EVM source amount');
    }
    final target = execution.payload['to'] as String;
    late PendingTransaction pending;
    Money amount = Money(units, nativeCurrency);
    var signedTarget = target;
    var signedData = execution.payload['data'] as String?;
    var signedValue = units;
    if (execution.mode == 'native-transfer') {
      pending = await wallet.createTransaction(evm!.createEVMTransactionCredentialsRaw(
        [OutputInfo(address: target, cryptoAmount: amount, sendAll: false, isParsedAddress: false)],
        currency: nativeCurrency,
        priority: priority(wallet),
        feeRate: 0,
        useBlinkProtection: false,
      ));
    } else if (execution.mode == 'erc20-transfer') {
      final parts = execution.sourceToken.split('-');
      final token = Erc20Token(
          name: parts.first,
          symbol: parts.first,
          contractAddress: parts.last,
          decimal: execution.binding.sourceDecimals,
          chainId: execution.binding.walletChainId,
          tag: switch (execution.sourceChain) {
            'POLYGON' => 'POL',
            'ARBITRUM' => 'ARB',
            _ => execution.sourceChain,
          });
      amount = Money(units, token);
      // Standard ERC20 transfer constructed by Cake; no approval transaction.
      final data = '0xa9059cbb${target.substring(2).toLowerCase().padLeft(64, '0')}'
          '${units.toRadixString(16).padLeft(64, '0')}';
      signedTarget = parts.last;
      signedData = data;
      signedValue = BigInt.zero;
      pending = await evm!.createRawCallDataTransaction(
          wallet, parts.last, data, Money.zero(nativeCurrency), priority(wallet),
          useBlinkProtection: false, sourceTokenAddress: parts.last, sourceTokenAmount: units);
    } else {
      // Deliberately pass authenticated calldata through without ABI decoding.
      pending = await evm!.createRawCallDataTransaction(
          wallet, target, execution.payload['data'] as String, amount, priority(wallet),
          useBlinkProtection: false);
    }
    final evidence = inspectPegarouteEvm(
        pending.hex,
        PegarouteWalletSnapshot(
          walletId: execution.binding.walletId,
          address: execution.binding.walletAddress,
          chainId: execution.binding.walletChainId,
          generation: 0,
          isHardwareWallet: false,
        ));
    if (!pegarouteSameAddress(execution.sourceChain, evidence.to, signedTarget) ||
        evidence.valueBaseUnits != signedValue.toString() ||
        (evidence.data ?? '0x').toLowerCase() != (signedData ?? '0x').toLowerCase()) {
      throw const PegarouteBindingException(
          'Signed EVM transaction differs from bound instructions');
    }
    return PegarouteTrustedPending(pending, amount: amount);
  }
}

class PegarouteTrustedPending with PendingTransaction {
  PegarouteTrustedPending(this.inner, {required this.amount})
      : preparedHex = inner.hex,
        id = bytesToHex(keccak256(hexToBytes(inner.hex)), include0x: true) {
    if (preparedHex.isEmpty || id.isEmpty || inner.shouldCommitUR()) {
      throw const PegarouteBindingException('Pending transaction identity is unavailable');
    }
  }
  final PendingTransaction inner;
  final String preparedHex;
  @override
  final String id;
  @override
  final Money amount;
  @override
  String get hex => inner.hex;
  @override
  String get evmTxHashFromRawHex => id;
  @override
  Money get fee => inner.fee;
  @override
  String get amountFormatted => amount.toString();
  @override
  String get feeFormatted => inner.feeFormatted;
  @override
  String get feeFormattedValue => inner.feeFormattedValue;
  @override
  int? get outputCount => inner.outputCount;
  void validate() {
    if (inner.hex != preparedHex || inner.shouldCommitUR()) {
      throw const PegarouteBindingException('Prepared Pegaroute transaction changed');
    }
  }

  @override
  Future<void> commit() {
    validate();
    return inner.commit();
  }

  @override
  Future<Map<String, String>> commitUR() => throw UnsupportedError('Pegaroute UR unavailable');
}

final class PegarouteTrustedExecutionHandler
    implements TradeExecutionHandler, TradeExecutionLifecycleHandler {
  const PegarouteTrustedExecutionHandler(
      {required this.walletContext,
      required this.adapter,
      required this.lifecycle,
      required this.onSourceCommitted});
  final PegarouteWalletContext walletContext;
  final PegarouteTrustedWalletAdapter adapter;
  final PegarouteExecutionLifecycleStore lifecycle;
  final Future<void> Function(ValidatedTradeExecution, CommittedTradeExecution) onSourceCommitted;

  @override
  bool supports(TradeExecution execution) => pegarouteTrustedExecution(execution);
  @override
  bool supportsExternalSend(TradeExecution execution) => false;
  @override
  void validateForExecution({required ValidatedTradeExecution execution, required DateTime now}) {
    if (!supports(execution.execution))
      throw const PegarouteBindingException('Unsupported execution');
    pegarouteRequireUnexpiredFunding(execution, now);
  }

  @override
  Future<GuardedPendingTransaction?> prepare({required TradeExecutionGuard guard}) async {
    late PegarouteWalletSnapshot before;
    return guard.withWalletConstruction(
        (wallet, validated) async {
          before = walletContext.snapshot(wallet);
          pegarouteRequireBoundWalletSnapshot(validated, before);
          return adapter.prepare(wallet, validated.execution);
        },
        executionHash: (pending) => pending.id,
        validatePrepared: (wallet, validated, pending) {
          final current = walletContext.snapshot(wallet);
          pegarouteRequireBoundWalletSnapshot(validated, current);
          if (!before.matches(current))
            throw const PegarouteBindingException('Funding wallet changed');
          (pending as PegarouteTrustedPending).validate();
        });
  }

  @override
  Future<void> onCommitted(
          {required ValidatedTradeExecution execution, required CommittedTradeExecution receipt}) =>
      onSourceCommitted(execution, receipt);
  @override
  Future<void> beforeBroadcast(
          {required ValidatedTradeExecution execution,
          required String executionHash,
          required int tradeInternalId}) =>
      lifecycle.beforeBroadcast(
          execution: execution, executionHash: executionHash, tradeInternalId: tradeInternalId);
  @override
  Future<void> onBroadcasted(
          {required ValidatedTradeExecution execution,
          required String executionHash,
          required int tradeInternalId}) =>
      lifecycle.onBroadcasted(
          execution: execution, executionHash: executionHash, tradeInternalId: tradeInternalId);
  @override
  Future<void> onBroadcastUnknown(
          {required ValidatedTradeExecution execution,
          required String executionHash,
          required int tradeInternalId}) =>
      lifecycle.onBroadcastUnknown(
          execution: execution, executionHash: executionHash, tradeInternalId: tradeInternalId);
  @override
  Future<void> onBroadcastAborted(
          {required ValidatedTradeExecution execution,
          required String executionHash,
          required int tradeInternalId}) =>
      lifecycle.onBroadcastAborted(
          execution: execution, executionHash: executionHash, tradeInternalId: tradeInternalId);
}

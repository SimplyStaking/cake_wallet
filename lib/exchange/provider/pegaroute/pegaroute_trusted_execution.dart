import 'package:cake_wallet/evm/evm.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/evm_call_data_transaction_credentials.dart';
import 'package:cw_core/output_info.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:web3dart/crypto.dart';
import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:on_chain/solana/solana.dart' show SolanaTransaction;

import 'pegaroute_api.dart';
import 'pegaroute_currency_mapper.dart';
import 'pegaroute_execution_binding.dart';
import 'pegaroute_execution_handler_support.dart';
import 'pegaroute_execution_lifecycle_store.dart';
import 'pegaroute_native_eth.dart';
import 'pegaroute_deposit.dart';
import 'pegaroute_approval.dart';

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
    (_evmWalletTypes.contains(wallet.type) && pegarouteEvmChains.containsValue(wallet.chainId) ||
        pegarouteDepositWallet(wallet));

bool pegarouteTrustedSource(WalletBase? wallet, PegarouteAssetId source) =>
    pegarouteTrustedWallet(wallet) &&
    (pegarouteEvmChains.containsKey(source.chain)
        ? _evmWalletTypes.contains(wallet!.type) &&
            pegarouteEvmChains[source.chain] == wallet.chainId
        : pegarouteDepositSource(wallet!, source));

/// Selection covers transaction shapes Cake can construct, not provider routing policy.
bool pegarouteTrustedQuote(PegarouteAssetId source, PegarouteRoute route) {
  if (route.privateValue?.isEnabled ?? false) return false;
  if (!pegarouteEvmChains.containsKey(source.chain)) return pegarouteDepositQuote(source, route);
  if (route.provider == 'instaswap') return route.memo == null && route.router == null;
  return const {'thorchain', 'maya', 'openocean'}.contains(route.provider);
}

bool pegarouteTrustedExecution(TradeExecution execution) {
  if (execution.family != 'evm') return pegarouteDepositExecution(execution);
  if (execution.privateIntent != false ||
      execution.binding.isSendAll ||
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
          execution.payload['approval'] == null &&
          execution.payload['data'] == null &&
          execution.payload['memo'] == null &&
          execution.payload['transferAmount'] == null;
    case 'contract-call':
      return (!native || execution.payload['approval'] == null) &&
          execution.routeProvider != 'instaswap' &&
          execution.payload['transferAmount'] == null &&
          pegarouteIsHex(execution.payload['data']?.toString() ?? '');
    case 'erc20-transfer':
      return !native &&
          execution.payload['approval'] == null &&
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
        wallet.chainId != execution.binding.walletChainId) {
      throw const PegarouteBindingException('Unsupported Pegaroute wallet operation');
    }
    if (execution.family != 'evm') {
      if (pegarouteDepositWallets[execution.sourceChain] != wallet.type) {
        throw const PegarouteBindingException('Deposit source does not match the wallet');
      }
      final pending = await preparePegarouteDeposit(wallet, execution, priority(wallet));
      final deferredHash = execution.sourceChain == 'ZEC';
      var id = pending.id;
      if (execution.sourceChain == 'SOL') {
        // Cake's transfer builder returns Base58-encoded signed transactions.
        final transaction = SolanaTransaction.deserialize(Base58Decoder.decode(pending.hex));
        final signature = transaction.signatures.first;
        if (signature.length != 64 || signature.every((byte) => byte == 0)) {
          throw const PegarouteBindingException('Unsigned Solana deposit');
        }
        id = Base58Encoder.encode(signature);
      } else if (!deferredHash && !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(id)) {
        throw const PegarouteBindingException('Single deposit transaction ID is unavailable');
      }
      return PegarouteTrustedPending(pending,
          amount: pending.amount,
          isEvm: false,
          transactionId: deferredHash ? null : id,
          attemptIdentity: deferredHash ? pegarouteFundingIdentity(execution, '') : null);
    }
    if (evm == null) throw const PegarouteBindingException('EVM wallet is unavailable');
    await pegarouteRequireExistingAllowance(wallet, execution);
    final nativeCurrency = _evmNativeCurrencies[execution.sourceChain]!;
    final units = BigInt.parse(execution.binding.sourceAmountBaseUnits);
    if (units <= BigInt.zero || units.bitLength > 256) {
      throw const PegarouteBindingException('Unsupported EVM source amount');
    }
    final target = execution.payload['to'] as String;
    final suppliedGas = execution.payload['gasLimit'] as String?;
    final gasLimit = suppliedGas == null ? null : int.tryParse(suppliedGas);
    if (suppliedGas != null && (gasLimit == null || gasLimit < 21000)) {
      throw const PegarouteBindingException('Invalid supplied EVM gas limit');
    }
    Future<PendingTransaction> call(String to, String data, Money value,
        {String? token, BigInt? tokenAmount}) {
      if (gasLimit != null) {
        return wallet.createTransaction(EvmCallDataTransactionCredentials(
          to: to,
          data: data,
          value: value,
          priority: priority(wallet),
          gasLimit: gasLimit,
          sourceTokenAddress: token,
          sourceTokenAmount: tokenAmount,
          useBlinkProtection: false,
        ));
      }
      return evm!.createRawCallDataTransaction(wallet, to, data, value, priority(wallet),
          useBlinkProtection: false, sourceTokenAddress: token, sourceTokenAmount: tokenAmount);
    }

    late PendingTransaction pending;
    Money amount = Money(units, nativeCurrency);
    var signedTarget = target;
    var signedData = execution.payload['data'] as String?;
    var signedValue = units;
    if (execution.mode == 'native-transfer') {
      pending = gasLimit != null
          ? await call(target, '0x', amount)
          : await wallet.createTransaction(evm!.createEVMTransactionCredentialsRaw(
              [
                OutputInfo(
                    address: target, cryptoAmount: amount, sendAll: false, isParsedAddress: false)
              ],
              currency: nativeCurrency,
              priority: priority(wallet),
              feeRate: 0,
              useBlinkProtection: false,
            ));
    } else if (execution.sourceToken != execution.nativeToken) {
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
      final transfer = execution.mode == 'erc20-transfer';
      final data = transfer
          ? '0xa9059cbb${target.substring(2).toLowerCase().padLeft(64, '0')}'
              '${units.toRadixString(16).padLeft(64, '0')}'
          : execution.payload['data'] as String;
      signedTarget = transfer ? parts.last : target;
      signedData = data;
      signedValue = BigInt.zero;
      pending = await call(signedTarget, data, Money.zero(nativeCurrency),
          token: parts.last, tokenAmount: units);
    } else {
      // Deliberately pass authenticated calldata through without ABI decoding.
      pending = await call(target, execution.payload['data'] as String, amount);
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
        gasLimit != null && BigInt.parse(evidence.gasLimit!) < BigInt.from(gasLimit) ||
        evidence.valueBaseUnits != signedValue.toString() ||
        (evidence.data ?? '0x').toLowerCase() != (signedData ?? '0x').toLowerCase()) {
      throw const PegarouteBindingException(
          'Signed EVM transaction differs from bound instructions');
    }
    return PegarouteTrustedPending(pending, amount: amount);
  }
}

class PegarouteTrustedPending with PendingTransaction {
  PegarouteTrustedPending(this.inner,
      {required this.amount, this.isEvm = true, String? transactionId, this.attemptIdentity})
      : preparedHex = inner.hex,
        _preparedId =
            isEvm ? bytesToHex(keccak256(hexToBytes(inner.hex)), include0x: true) : transactionId {
    if ((attemptIdentity == null && (preparedHex.isEmpty || id.isEmpty)) ||
        attemptIdentity != null && inner.id.isNotEmpty ||
        inner.shouldCommitUR()) {
      throw const PegarouteBindingException('Pending transaction identity is unavailable');
    }
  }
  final PendingTransaction inner;
  final String preparedHex;
  final bool isEvm;
  final String? _preparedId;
  final String? attemptIdentity;
  String get executionIdentity => attemptIdentity ?? id;
  @override
  String get id => _preparedId ?? inner.id;
  @override
  final Money amount;
  @override
  String get hex => inner.hex;
  @override
  String? get evmTxHashFromRawHex => isEvm ? id : null;
  @override
  Money get fee => inner.fee;
  @override
  Money? get additionalCost => inner.additionalCost;
  @override
  PendingChange? get change => inner.change;
  @override
  set change(PendingChange? value) => inner.change = value;
  @override
  String? get feeRate => inner.feeRate;
  @override
  set feeRate(String? value) => inner.feeRate = value;
  @override
  String get amountFormatted => amount.toString();
  @override
  String get feeFormatted => inner.feeFormatted;
  @override
  String get feeFormattedValue => inner.feeFormattedValue;
  @override
  int? get outputCount => inner.outputCount;
  void validate() {
    if (inner.hex != preparedHex ||
        inner.shouldCommitUR() ||
        !isEvm && _preparedId != null && inner.id.isNotEmpty && inner.id != _preparedId) {
      throw const PegarouteBindingException('Prepared Pegaroute transaction changed');
    }
  }

  @override
  Future<void> commit() async {
    validate();
    try {
      await inner.commit();
    } catch (_) {
      // ZEC can finish broadcast then fail refreshing balances/history. Its
      // returned network ID establishes success; never prompt another payment.
      if (attemptIdentity == null || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(inner.id)) rethrow;
    }
    if (attemptIdentity != null && !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(inner.id)) {
      throw const PegarouteBindingException('ZEC broadcast result is unknown');
    }
    if (!isEvm && _preparedId != null && inner.id != _preparedId) {
      throw const PegarouteBindingException('Wallet returned a different deposit transaction ID');
    }
  }

  @override
  Future<Map<String, String>> commitUR() => throw UnsupportedError('Pegaroute UR unavailable');
}

final class PegarouteTrustedExecutionHandler
    implements TradeExecutionHandler, TradeExecutionLifecycleHandler, TradeExecutionReceiptHandler {
  const PegarouteTrustedExecutionHandler(
      {required this.walletContext,
      required this.adapter,
      required this.lifecycle,
      required this.onSourceCommitted,
      this.approvalFlow = const PegarouteApprovalFlow()});
  final PegarouteWalletContext walletContext;
  final PegarouteTrustedWalletAdapter adapter;
  final PegarouteExecutionLifecycleStore lifecycle;
  final Future<void> Function(ValidatedTradeExecution, CommittedTradeExecution) onSourceCommitted;
  final PegarouteApprovalFlow approvalFlow;

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
          void validate() {
            guard.validate();
            if (!before.matches(walletContext.snapshot(wallet))) {
              throw const PegarouteBindingException('Approval wallet changed');
            }
          }

          final approval = await approvalFlow.prepare(
              wallet: wallet,
              execution: validated,
              priority: adapter.priority(wallet),
              validate: validate);
          return approval ?? await adapter.prepare(wallet, validated.execution);
        },
        executionHash: (pending) => (pending as PegarouteTrustedPending).executionIdentity,
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
  Future<void> onBroadcastedWithReceipt(
          {required ValidatedTradeExecution execution,
          required String executionHash,
          required int tradeInternalId,
          required CommittedTradeExecution receipt}) =>
      lifecycle.onBroadcasted(
          execution: execution,
          executionHash: executionHash,
          tradeInternalId: tradeInternalId,
          transactionId: receipt.transactionId);
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

String pegarouteFundingIdentity(TradeExecution execution, String transactionId) =>
    execution.sourceChain == 'ZEC'
        ? 'pegaroute:funding:${execution.binding.tradeId}'
        : transactionId;

/// Recheck allowance immediately before constructing the final swap. The
/// prerequisite flow owns approval transactions and their separate confirmations.
Future<void> pegarouteRequireExistingAllowance(WalletBase wallet, TradeExecution execution) async {
  final approval = execution.payload['approval'];
  if (execution.family != 'evm' || approval == null) return;
  final value = approval as Map;
  final allowance = await evm!
      .getAllowance(wallet, value['tokenAddress'] as String, value['spender'] as String)
      .timeout(const Duration(seconds: 6));
  if (allowance == null || allowance < BigInt.parse(execution.binding.sourceAmountBaseUnits)) {
    throw const TradeExecutionPrerequisiteException(
        'Token allowance no longer covers this swap. Reopen the swap to check its approval.');
  }
}

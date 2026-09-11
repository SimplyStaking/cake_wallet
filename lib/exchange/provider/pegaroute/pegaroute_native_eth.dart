import 'dart:typed_data';

import 'package:cake_wallet/evm/evm.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/output_info.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:mobx/mobx.dart';
import 'package:web3dart/crypto.dart';
import 'package:web3dart/web3dart.dart' as web3;

import 'pegaroute_eth_execution_handler.dart';
import 'pegaroute_execution_binding.dart';
import 'pegaroute_execution_handler_support.dart';

bool pegarouteNativeEthWallet(WalletBase? wallet) =>
    wallet != null &&
    wallet.type == WalletType.ethereum &&
    wallet.chainId == 1 &&
    !wallet.isHardwareWallet &&
    wallet.isSoftwareWallet;

bool pegarouteNativeEthDeposit(TradeExecution execution) =>
    execution.routeProvider == 'instaswap' &&
    execution.family == 'evm' &&
    execution.mode == 'native-transfer' &&
    execution.sourceChain == 'ETH' &&
    execution.sourceToken == 'ETH' &&
    execution.nativeToken == 'ETH' &&
    execution.privateIntent == false &&
    execution.binding.walletChainId == 1 &&
    !execution.binding.isSendAll &&
    execution.payload['data'] == null &&
    execution.payload['memo'] == null &&
    execution.payload['approval'] == null &&
    execution.payload['transferAmount'] == null;

/// Observes Cake's existing wallet/network observables, including ABA switches.
/// The provider uses a short-lived instance; the dispatcher owns an app-lifetime one.
final class PegarouteActiveWalletContext implements PegarouteWalletContext {
  PegarouteActiveWalletContext(this.currentWallet) {
    dispose = reaction(
      (_) {
        final wallet = currentWallet();
        return (wallet, wallet?.chainId, wallet?.walletAddresses.address);
      },
      (_) => _generation++,
    );
  }

  final WalletBase? Function() currentWallet;
  late final ReactionDisposer dispose;
  int _generation = 0;

  @override
  PegarouteWalletSnapshot snapshot(WalletBase wallet) {
    if (!identical(currentWallet(), wallet) || !pegarouteNativeEthWallet(wallet)) {
      throw const PegarouteBindingException('The active software Ethereum wallet changed');
    }
    return PegarouteWalletSnapshot(
      walletId: wallet.id,
      address: wallet.walletAddresses.address,
      chainId: wallet.chainId,
      generation: _generation,
      isHardwareWallet: wallet.isHardwareWallet,
    );
  }
}

/// Delegates fees and signing to Cake's ordinary send implementation.
final class PegarouteNativeEthWalletAdapter implements PegarouteEthWalletAdapter {
  const PegarouteNativeEthWalletAdapter({required this.priority});

  final TransactionPriority? Function(WalletBase) priority;

  @override
  Future<PegaroutePreparedTransaction<PegarouteEthTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  }) async {
    final value = execution.execution;
    if (!pegarouteNativeEthDeposit(value) || !pegarouteNativeEthWallet(wallet) || evm == null) {
      throw const PegarouteBindingException('Only public native ETH deposits are available');
    }
    final pending = await wallet.createTransaction(evm!.createEVMTransactionCredentialsRaw(
      [
        OutputInfo(
          address: value.payload['to'] as String,
          cryptoAmount:
              Money(BigInt.parse(value.binding.sourceAmountBaseUnits), CryptoCurrency.eth),
          sendAll: false,
          isParsedAddress: false,
        ),
      ],
      currency: CryptoCurrency.eth,
      priority: priority(wallet),
      feeRate: 0,
      useBlinkProtection: false,
    ));
    if (pending.shouldCommitUR()) {
      throw const PegarouteBindingException('Pegaroute UR execution is unavailable');
    }
    final evidence = inspectPegarouteNativeEth(pending.hex, snapshot);
    return PegaroutePreparedTransaction(
      pending: _NativeEthPending(pending, evidence.rawHex, evidence.transactionHash),
      evidence: evidence,
      snapshot: snapshot,
    );
  }
}

/// Cake's Ethereum client emits type-2 transactions. Inspect the network bytes,
/// recover the signer, and reject every non-native-transfer shape.
PegarouteEthTransactionEvidence inspectPegarouteNativeEth(
  String rawHex,
  PegarouteWalletSnapshot snapshot,
) {
  try {
    final bytes = hexToBytes(rawHex);
    if (bytes.isEmpty || bytes.first != 2) throw const FormatException('Expected type 2');
    final fields = _nativeTransactionFields(bytes.sublist(1));
    if (fields.length != 12 || bytesToHex(web3.encode(fields)) != bytesToHex(bytes.sublist(1))) {
      throw const FormatException('Noncanonical transaction');
    }
    Uint8List field(int i) => fields[i] as Uint8List;
    BigInt number(int i) {
      final value = field(i);
      if (value.length > 32 || value.isNotEmpty && value.first == 0) {
        throw const FormatException('Noncanonical integer');
      }
      return value.isEmpty ? BigInt.zero : bytesToUnsignedInt(value);
    }

    final chain = number(0);
    number(1); // nonce is also required to be canonical
    final tip = number(2);
    final maxFee = number(3);
    final gas = number(4);
    final amount = number(6);
    final parity = number(9);
    final r = number(10);
    final s = number(11);
    final order =
        BigInt.parse('fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141', radix: 16);
    if (chain != BigInt.one ||
        field(5).length != 20 ||
        field(7).isNotEmpty ||
        fields[8] is! List ||
        (fields[8] as List).isNotEmpty ||
        gas < BigInt.from(21000) ||
        maxFee <= BigInt.zero ||
        tip > maxFee ||
        parity > BigInt.one ||
        r <= BigInt.zero ||
        r >= order ||
        s <= BigInt.zero ||
        s > order ~/ BigInt.two) {
      throw const FormatException('Unsupported native ETH transaction');
    }
    final digest = keccak256(Uint8List.fromList([2, ...web3.encode(fields.sublist(0, 9))]));
    final recovered = ecRecover(digest, MsgSignature(r, s, parity.toInt() + 27));
    final publicKey = Uint8List(64);
    if (recovered.length > 64) throw const FormatException('Invalid public key');
    publicKey.setRange(64 - recovered.length, 64, recovered);
    final signer = bytesToHex(publicKeyToAddress(publicKey), include0x: true);
    if (!pegarouteSameAddress('ETH', signer, snapshot.address)) {
      throw const FormatException('Signed by a different wallet');
    }
    return PegarouteEthTransactionEvidence(
      rawHex: rawHex,
      chainId: 1,
      to: bytesToHex(field(5), include0x: true),
      valueBaseUnits: amount.toString(),
      data: null,
      gasLimit: gas.toString(),
      approvalPresent: false,
      transactionHash: bytesToHex(keccak256(bytes), include0x: true),
      snapshot: snapshot,
    );
  } catch (_) {
    throw const PegarouteBindingException('Signed native ETH deposit could not be verified');
  }
}

// Narrow RLP reader: one transaction list with byte fields and an empty access
// list. Round-trip encoding above additionally rejects noncanonical lengths.
List<Object> _nativeTransactionFields(Uint8List bytes) {
  if (bytes.length > 1024) throw const FormatException('Oversized native transaction');
  var cursor = 0;
  Object read({bool root = false}) {
    final prefix = bytes[cursor++];
    if (prefix < 0x80) return Uint8List.fromList([prefix]);
    final list = prefix >= 0xc0;
    final short = list ? 0xc0 : 0x80;
    final long = list ? 0xf7 : 0xb7;
    var length = prefix - short;
    if (prefix > long) {
      final lengthBytes = prefix - long;
      if (lengthBytes > 2) throw const FormatException('Oversized RLP length');
      length = 0;
      for (var i = 0; i < lengthBytes; i++) {
        length = (length << 8) | bytes[cursor++];
      }
    }
    final end = cursor + length;
    if (end > bytes.length) throw const FormatException('Truncated RLP');
    if (list) {
      if (!root && length != 0) throw const FormatException('Unsupported access list');
      final result = <Object>[];
      while (cursor < end) {
        result.add(read());
      }
      if (cursor != end) throw const FormatException('Invalid RLP length');
      return result;
    }
    final result = Uint8List.fromList(bytes.sublist(cursor, end));
    cursor = end;
    return result;
  }

  final fields = read(root: true);
  if (cursor != bytes.length || fields is! List<Object> || fields is Uint8List) {
    throw const FormatException('Invalid transaction list');
  }
  return fields;
}

/// The existing EVM pending `id` adds an extra type prefix. Use the verified
/// network hash here and keep normal sends unchanged.
final class _NativeEthPending with PendingTransaction {
  _NativeEthPending(this.inner, this.preparedHex, this.id);
  final PendingTransaction inner;
  final String preparedHex;
  @override
  final String id;
  @override
  String get hex => inner.hex;
  @override
  String get evmTxHashFromRawHex => bytesToHex(keccak256(hexToBytes(hex)), include0x: true);
  @override
  Money get amount => inner.amount;
  @override
  Money get fee => inner.fee;
  @override
  String get amountFormatted => inner.amountFormatted;
  @override
  String get feeFormatted => inner.feeFormatted;
  @override
  String get feeFormattedValue => inner.feeFormattedValue;
  @override
  Future<void> commit() {
    if (inner.hex != preparedHex || inner.shouldCommitUR()) {
      throw const PegarouteBindingException('Prepared ETH deposit changed');
    }
    return inner.commit();
  }

  @override
  Future<Map<String, String>> commitUR() => throw UnsupportedError('Pegaroute UR unavailable');
}

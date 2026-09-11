import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/solana_serialized_transaction_credentials.dart';
import 'package:cw_solana/prepare_serialized_transaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_chain/solana/solana.dart';

final _key = SolanaPrivateKey.fromSeed(List.filled(32, 1)); // Synthetic fixture only.

class _Rpc implements SolanaRPC {
  String genesis = '5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d';
  BigInt? fee = BigInt.from(5000);
  String? wire;
  bool wrongId = false;
  void Function()? duringFee;
  final calls = <String>[];
  @override
  Future<T> request<T>(SolanaRPCRequest<T> request, [Duration? timeout]) async {
    calls.add(request.method);
    if (request is SolanaRPCGetGenesisHash) return genesis as T;
    if (request is SolanaRPCGetFeeForMessage) {
      duringFee?.call();
      return fee as T;
    }
    final send = request as SolanaRPCSendTransaction;
    expect(send.skipPreflight, false);
    wire = send.encodedTransaction;
    final tx = SolanaTransaction.deserialize(Base58Decoder.decode(wire!), verifySignatures: true);
    return (wrongId ? 'different-id' : Base58Encoder.encode(tx.signatures.first)) as T;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  for (final versioned in [false, true]) {
    test(
        'wallet signs exact ${versioned ? 'v0 with lookup table' : 'legacy'} message and broadcasts fixed bytes',
        () async {
      final owner = _key.publicKey().toAddress();
      final raw = [
        1,
        ...List.filled(64, 0),
        if (versioned) 0x80,
        1,
        0,
        0,
        1,
        ...Base58Decoder.decode(owner.address),
        ...List.filled(32, 3),
        0,
        if (versioned) ...[1, ...List.filled(32, 7), 1, 0, 0],
      ];
      final unsigned = SolanaTransaction.deserialize(raw);
      final rpc = _Rpc();
      final pending = await prepareSerializedSolanaTransaction(
        credentials: SolanaSerializedTransactionCredentials(
            transactionBase58: Base58Encoder.encode(raw),
            amount: Money(BigInt.from(1000000), CryptoCurrency.sol),
            destinationAddress: owner.address),
        privateKey: _key,
        provider: rpc,
        isCurrentProvider: () => true,
        nativeBalance: Money(BigInt.from(1000000000), CryptoCurrency.sol),
      );
      expect(rpc.wire, isNull);
      final signed =
          SolanaTransaction.deserialize(Base58Decoder.decode(pending.hex), verifySignatures: true);
      expect(signed.serializeMessage(), unsigned.serializeMessage());
      expect(pending.fee.amount, BigInt.from(5000));
      await pending.commit();
      expect(rpc.wire, pending.hex);
      expect(pending.id, Base58Encoder.encode(signed.signatures.first));
      expect(rpc.calls, ['getGenesisHash', 'getFeeForMessage', 'sendTransaction']);
    });
  }

  for (final failure in [
    'payer',
    'network',
    'fee',
    'balance',
    'connection-during-prepare',
    'connection-before-send',
    'returned-id'
  ]) {
    test('serialized transaction $failure failure cannot silently alter or redirect a send',
        () async {
      final tx = SolanaTransaction(
        payerKey: failure == 'payer'
            ? SolanaPrivateKey.fromSeed(List.filled(32, 2)).publicKey().toAddress()
            : _key.publicKey().toAddress(),
        recentBlockhash: SolAddress(Base58Encoder.encode(List.filled(32, 3))),
        instructions: [],
      );
      final rpc = _Rpc();
      var current = true;
      if (failure == 'network') rpc.genesis = 'testnet';
      if (failure == 'fee') rpc.fee = null;
      if (failure == 'connection-during-prepare') rpc.duringFee = () => current = false;
      if (failure == 'returned-id') rpc.wrongId = true;
      final future = prepareSerializedSolanaTransaction(
        credentials: SolanaSerializedTransactionCredentials(
            transactionBase58: tx.serializeString(),
            amount: Money(BigInt.from(1000000), CryptoCurrency.sol),
            destinationAddress: _key.publicKey().toAddress().address),
        privateKey: _key,
        provider: rpc,
        isCurrentProvider: () => current,
        nativeBalance:
            Money(BigInt.from(failure == 'balance' ? 1 : 1000000000), CryptoCurrency.sol),
      );
      if (failure == 'connection-before-send' || failure == 'returned-id') {
        final pending = await future;
        if (failure == 'connection-before-send') current = false;
        await expectLater(pending.commit(), throwsStateError);
      } else {
        await expectLater(future, throwsStateError);
      }
      if (failure != 'returned-id') expect(rpc.wire, isNull);
    });
  }
}

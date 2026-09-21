import 'dart:convert';

import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/solana_serialized_transaction_credentials.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_solana_wire.dart';
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
  test('declared codec selects either complete interpretation of the dual-valid fixture', () {
    // Bounded prefix-guided search: one- and two-signer legacy skeletons,
    // each with a non-payer program and one instruction. Synthetic bytes only.
    const text =
        'AQ1111111111111111111111111111111111111111111111111111111111111111111111111111111111114BAAEC111111111111111111111111111111111111111111111111111111111111111111111111111111111113Af7WSE8efr5vJivgfkFD6thBoFiNLgZ2ZpXpg1LFufkeAQEBAJEC111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111114GEEebwT22DHx6T4H2LL1Trgk8RyGeGCe1bRBvB9Ecjou1aa9Hfeou7J5bY12edu9gri19pMCG3vtQanJfoeZNHAaZiYzjptpmg7gKEnta9rkFqf7o3iQWbHhMWFMN8e4CevBZdeALBLn7rt6BqnF1urALQBEZeg1gSm29fQNByqPQfkKRBQPMZmXupq5HRZhQWc3z7v8kA5yS821E7pu3rdFady2UXWBMVUroR74Kou';
    final from64 = base64Decode(text);
    final from58 = Base58Decoder.decode(text);
    expect(base64Encode(from64), text);
    expect(Base58Encoder.encode(from58), text);
    expect(from64.length, 444);
    expect(from58.length, 434);
    expect(from64, isNot(from58));
    expect(decodePegarouteSolanaTransaction(text, 'base64'), from64);
    expect(decodePegarouteSolanaTransaction(text, 'base58'), from58);
    expect(() => decodePegarouteSolanaTransaction(text, 'hex'), throwsFormatException);
  });

  test('codec bounds accept 1232 bytes and reject 1233 bytes', () {
    final maximum = List.filled(1232, 9);
    final oversized = List.filled(1233, 9);
    for (final entry in <String, String Function(List<int>)>{
      'base58': Base58Encoder.encode,
      'base64': base64Encode,
      'hex': BytesUtils.toHexString,
    }.entries) {
      expect(decodePegarouteSolanaTransaction(entry.value(maximum), entry.key), maximum);
      expect(() => decodePegarouteSolanaTransaction(entry.value(oversized), entry.key),
          throwsFormatException);
    }
    expect(
        decodePegarouteSolanaTransaction('0x${BytesUtils.toHexString(maximum)}', 'hex'), maximum);
    expect(() => decodePegarouteSolanaTransaction('0x${BytesUtils.toHexString(oversized)}', 'hex'),
        throwsFormatException);
    expect('0x${BytesUtils.toHexString(maximum)}'.length, 2466);
    expect(
        () => decodePegarouteSolanaTransaction('1' * 2467, 'base58'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'reason', 'Solana transaction text is too long')));
  });

  test('canonical two-padding Base64 accepts while alternate and malformed forms fail', () {
    final raw = [9];
    final text = base64Encode(raw);
    expect(text.endsWith('=='), isTrue);
    expect(decodePegarouteSolanaTransaction(text, 'base64'), raw);
    final standard = base64Encode([255]);
    expect(standard.contains('/'), isTrue);
    for (final invalid in [
      text.substring(0, text.length - 2),
      '${text.substring(0, text.length - 3)}R==', // Nonzero unused padding bits.
      text.replaceAll('=', '%3D'),
      standard.replaceAll('/', '_').replaceAll('+', '-'),
    ]) {
      expect(() => decodePegarouteSolanaTransaction(invalid, 'base64'), throwsFormatException);
    }
    expect(() => decodePegarouteSolanaTransaction('0X${BytesUtils.toHexString(raw)}', 'hex'),
        throwsFormatException);
  });

  test('invalid declared codec never falls back to another valid interpretation', () {
    final raw = [9];
    final text = base64Encode(raw);
    expect(decodePegarouteSolanaTransaction(text, 'base64'), raw);
    expect(() => decodePegarouteSolanaTransaction(text, 'base58'), throwsFormatException);
    for (final encoding in ['', 'BASE64', 'base64 ', 'unknown']) {
      expect(() => decodePegarouteSolanaTransaction(text, encoding), throwsFormatException);
    }
  });

  test('strict codecs reject empty text, whitespace and malformed alphabets', () {
    for (final entry in {
      'base58': ['', ' 3MN', '3MN\n', '3 MN', '0OIl'],
      'base64': ['', ' CQ==', 'CQ==\n', 'C Q==', 'CQ==='],
      'hex': ['', ' 0x09', '09\n', '0 9', '0x1', '0xzz'],
    }.entries) {
      for (final text in entry.value) {
        expect(() => decodePegarouteSolanaTransaction(text, entry.key), throwsFormatException);
      }
    }
  });
  for (final versioned in [false, true]) {
    for (final encoding in ['base58', 'base64', 'hex', '0xhex']) {
      test(
          '$encoding wallet signs exact ${versioned ? 'v0 with lookup table' : 'legacy'} message and broadcasts fixed bytes',
          () async {
        final owner = _key.publicKey().toAddress();
        final raw = [
          1,
          ...List.filled(64, 0),
          if (versioned) 0x80,
          1,
          0,
          1,
          2,
          ...Base58Decoder.decode(owner.address),
          ...List.filled(32, 7),
          ...List.filled(32, 3),
          1,
          1,
          1,
          versioned ? 2 : 0,
          128,
          1,
          ...List.filled(128, 9),
          if (versioned) ...[1, ...List.filled(32, 7), 1, 0, 0],
        ];
        final unsigned = SolanaTransaction.deserialize(raw);
        final rpc = _Rpc();
        final pending = await prepareSerializedSolanaTransaction(
          credentials: SolanaSerializedTransactionCredentials(
              transactionBase58: Base58Encoder.encode(decodePegarouteSolanaTransaction(
                  switch (encoding) {
                    'base64' => base64Encode(raw),
                    'hex' => BytesUtils.toHexString(raw).toUpperCase(),
                    '0xhex' => '0x${BytesUtils.toHexString(raw)}',
                    _ => Base58Encoder.encode(raw),
                  },
                  encoding == '0xhex' ? 'hex' : encoding)),
              amount: Money(BigInt.from(1000000), CryptoCurrency.sol),
              destinationAddress: owner.address),
          privateKey: _key,
          provider: rpc,
          isCurrentProvider: () => true,
          nativeBalance: Money(BigInt.from(1000000000), CryptoCurrency.sol),
        );
        expect(rpc.wire, isNull);
        final signed = SolanaTransaction.deserialize(Base58Decoder.decode(pending.hex),
            verifySignatures: true);
        expect(signed.serializeMessage(), unsigned.serializeMessage());
        expect(pending.fee.amount, BigInt.from(5000));
        await pending.commit();
        expect(rpc.wire, pending.hex);
        expect(pending.id, Base58Encoder.encode(signed.signatures.first));
        expect(rpc.calls, ['getGenesisHash', 'getFeeForMessage', 'sendTransaction']);
      });
    }
  }

  for (final otherSignature in ['valid', 'missing', 'corrupt']) {
    test('two-signer transaction preserves or rejects $otherSignature cosigner signature',
        () async {
      final other = SolanaPrivateKey.fromSeed(List.filled(32, 2));
      final tx = SolanaTransaction.deserialize([
        2,
        ...List.filled(128, 0),
        2,
        0,
        1,
        3,
        ...Base58Decoder.decode(_key.publicKey().toAddress().address),
        ...Base58Decoder.decode(other.publicKey().toAddress().address),
        ...List.filled(32, 7),
        ...List.filled(32, 3),
        1,
        2,
        2,
        0,
        1,
        0,
      ]);
      final signature = other.sign(tx.serializeMessage());
      if (otherSignature != 'missing') {
        tx.addSignature(other.publicKey().toAddress(), signature);
      }
      final raw = tx.serialize();
      if (otherSignature == 'corrupt') raw[65] ^= 1;
      final rpc = _Rpc();
      final future = prepareSerializedSolanaTransaction(
        credentials: SolanaSerializedTransactionCredentials(
          transactionBase58:
              Base58Encoder.encode(decodePegarouteSolanaTransaction(base64Encode(raw), 'base64')),
          amount: Money(BigInt.from(1000000), CryptoCurrency.sol),
          destinationAddress: _key.publicKey().toAddress().address,
        ),
        privateKey: _key,
        provider: rpc,
        isCurrentProvider: () => true,
        nativeBalance: Money(BigInt.from(1000000000), CryptoCurrency.sol),
      );
      if (otherSignature == 'valid') {
        final pending = await future;
        final signed = SolanaTransaction.deserialize(Base58Decoder.decode(pending.hex),
            verifySignatures: true);
        expect(signed.serializeMessage(), tx.serializeMessage());
        expect(signed.signatures[1], signature);
        await pending.commit();
        expect(rpc.wire, pending.hex);
      } else {
        await expectLater(future, throwsA(anything));
        expect(rpc.wire, isNull);
        expect(rpc.calls, ['getGenesisHash', 'getFeeForMessage']);
      }
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

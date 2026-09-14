// Offline exercise of Cake's real gas/fee/balance construction and signed bytes.
// ignore_for_file: cw_custom_lints/no_restricted_imports_in_lib
import 'dart:typed_data';

import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_native_eth.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_handler_support.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/evm_call_data_transaction_credentials.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_evm/clients/evm_chain_client.dart';
import 'package:cw_evm/evm_chain_transaction_history.dart';
import 'package:cw_evm/evm_chain_transaction_priority.dart';
import 'package:cw_evm/evm_chain_wallet.dart';
import 'package:cw_evm/evm_erc20_balance.dart';
import 'package:cw_evm/pending_evm_chain_transaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web3dart/crypto.dart';
import 'package:web3dart/crypto.dart' as crypto;
import 'package:web3dart/web3dart.dart';

final _key = EthPrivateKey.fromInt(BigInt.one); // Public synthetic key.
const _to = '0x0000000000000000000000000000000000000001';

class _Encryption extends Mock implements EncryptionFileUtils {}

class _History extends Mock implements EVMChainTransactionHistory {}

class _Addresses extends Mock implements WalletAddresses {}

class _Info extends Mock implements WalletInfo {}

WalletInfo _info() {
  final info = _Info();
  when(() => info.id).thenReturn('gas-fixture');
  when(() => info.name).thenReturn('gas-fixture');
  when(() => info.type).thenReturn(WalletType.ethereum);
  when(() => info.address).thenReturn(_key.address.hex);
  when(() => info.getUsedAddresses()).thenAnswer((_) async => {});
  when(() => info.getHiddenAddresses()).thenAnswer((_) async => {});
  when(() => info.getManualAddresses()).thenAnswer((_) async => {});
  return info;
}

class _Wallet extends EVMChainWallet {
  _Wallet(_Client client)
      : super(
          walletInfo: _info(),
          derivationInfo: DerivationInfo(),
          client: client,
          nativeCurrency: CryptoCurrency.eth,
          privateKey: '1'.padLeft(64, '0'),
          password: 'offline',
          encryptionFileUtils: _Encryption(),
          initialBalance: EVMChainERC20Balance(Money.parse('1', CryptoCurrency.eth)),
        );
  @override
  Future<void> initErc20Tokens() async {}
  @override
  Future<void> save() async {}
}

class _Client implements EVMChainClient {
  int estimate = 271613;
  int gasPrice = 5000000000;
  int signs = 0;
  int broadcasts = 0;
  @override
  Uint8List hexToBytes(String value) => crypto.hexToBytes(value);
  @override
  Future<int?> getGasBaseFee() async => null;
  @override
  Future<int> getGasUnitPrice() async => gasPrice;
  @override
  Future<int> getEstimatedGasUnitsForTransaction(
      {required EthereumAddress toAddress,
      required EthereumAddress senderAddress,
      required EtherAmount value,
      String? contractAddress,
      EtherAmount? gasPrice,
      EtherAmount? maxFeePerGas,
      Uint8List? data}) async {
    expect(toAddress.hex, _to);
    expect(value.getInWei, BigInt.parse('1000000000000000'));
    expect(bytesToHex(data!), '12345678');
    return estimate;
  }

  @override
  Future<PendingEVMChainTransaction> signTransaction(
      {required Credentials privateKey,
      required String toAddress,
      required Money amount,
      required Money gasFee,
      required int estimatedGasUnits,
      required int maxFeePerGas,
      required EVMChainTransactionPriority? priority,
      required CryptoCurrency currency,
      required String feeCurrency,
      String? contractAddress,
      String? data,
      int? gasPrice,
      bool useBlinkProtection = true}) async {
    signs++;
    expect(useBlinkProtection, false);
    expect(gasFee.amount, BigInt.from(estimatedGasUnits) * BigInt.from(maxFeePerGas));
    final tx = Transaction(
        to: EthereumAddress.fromHex(toAddress),
        value: EtherAmount.inWei(amount.amount),
        data: hexToBytes(data!),
        nonce: 0,
        maxGas: estimatedGasUnits,
        maxPriorityFeePerGas: EtherAmount.inWei(BigInt.zero),
        maxFeePerGas: EtherAmount.inWei(BigInt.from(maxFeePerGas)));
    final raw = await signTransactionRaw(tx, privateKey, chainId: 1);
    return PendingEVMChainTransaction(
        signedTransaction: prependTransactionType(2, raw),
        amount: amount,
        fee: gasFee,
        sendTransaction: () async {
          broadcasts++;
        });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Client client;
  late _Wallet wallet;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'evm_scam_check_v2_done_gas-fixture': true});
    client = _Client();
    wallet = _Wallet(client);
    final history = _History();
    when(() => history.init()).thenAnswer((_) async {});
    wallet.transactionHistory = history;
    final addresses = _Addresses();
    when(() => addresses.init()).thenAnswer((_) async {});
    wallet.walletAddresses = addresses;
    await wallet.init();
  });
  EvmCallDataTransactionCredentials credentials(int gas) => EvmCallDataTransactionCredentials(
      to: _to,
      data: '0x12345678',
      value: Money.parse('0.001', CryptoCurrency.eth),
      priority: null,
      gasLimit: gas,
      useBlinkProtection: false);
  for (final estimate in [271613, 400000, 0]) {
    test('estimate $estimate uses the supplied floor for signed gas and confirmation fee',
        () async {
      client.estimate = estimate;
      final pending = await wallet.createTransaction(credentials(351834));
      final evidence = inspectPegarouteEvm(
          pending.hex,
          PegarouteWalletSnapshot(
              walletId: wallet.id,
              address: _key.address.hex,
              chainId: 1,
              generation: 0,
              isHardwareWallet: false));
      final expected = estimate > 351834 ? estimate : 351834;
      expect(evidence.gasLimit, '$expected');
      expect(pending.fee.amount, BigInt.from(expected) * BigInt.from(client.gasPrice));
      expect(client.broadcasts, 0);
    });
  }
  test('larger supplied gas is included in the balance check before signing', () async {
    // Covers the smaller estimate but not the provider's larger gas limit.
    wallet.balance[CryptoCurrency.eth] =
        EVMChainERC20Balance(Money.parse('0.0025', CryptoCurrency.eth));
    await expectLater(wallet.createTransaction(credentials(351834)), throwsException);
    expect(client.signs, 0);
    expect(client.broadcasts, 0);
  });
  test('missing gas price cannot create a zero-fee confirmation with supplied gas', () async {
    client.gasPrice = 0;
    await expectLater(wallet.createTransaction(credentials(351834)), throwsException);
    expect(client.signs, 0);
  });
  test('invalid supplied gas stops before signing', () async {
    await expectLater(wallet.createTransaction(credentials(1)), throwsException);
    expect(client.signs, 0);
  });
}

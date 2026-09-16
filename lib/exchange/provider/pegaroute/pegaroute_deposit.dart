import 'dart:convert';
import 'pegaroute_solana_wire.dart';

import 'package:cake_wallet/bitcoin/bitcoin.dart';
import 'package:cake_wallet/monero/monero.dart';
import 'package:cake_wallet/solana/solana.dart';
import 'package:cake_wallet/tron/tron.dart';
import 'package:cake_wallet/zcash/zcash.dart';
import 'package:cake_wallet/view_model/send/output.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/output_info.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/spl_token.dart';
import 'package:cw_core/solana_serialized_transaction_credentials.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/unspent_coin_type.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:blockchain_utils/blockchain_utils.dart';

import 'pegaroute_api.dart';
import 'pegaroute_currency_mapper.dart';
import 'pegaroute_execution_binding.dart';

const pegarouteDepositWallets = {
  'BTC': WalletType.bitcoin,
  'BCH': WalletType.bitcoinCash,
  'LTC': WalletType.litecoin,
  'DOGE': WalletType.dogecoin,
  'XMR': WalletType.monero,
  'SOL': WalletType.solana,
  'TRON': WalletType.tron,
  'ZEC': WalletType.zcash,
};
const _currencies = {
  'BTC': CryptoCurrency.btc,
  'BCH': CryptoCurrency.bch,
  'LTC': CryptoCurrency.ltc,
  'DOGE': CryptoCurrency.doge,
  'XMR': CryptoCurrency.xmr,
  'SOL': CryptoCurrency.sol,
  'TRON': CryptoCurrency.trx,
  'ZEC': CryptoCurrency.zec,
};
const _utxo = {'BTC', 'BCH', 'LTC', 'DOGE'};

bool pegarouteDepositWallet(WalletBase wallet) {
  if (!pegarouteDepositWallets.containsValue(wallet.type) ||
      !const {null, '', 'mainnet'}.contains(wallet.walletInfo.network)) return false;
  if (electrumWalletTypes.contains(wallet.type) && (bitcoin == null || bitcoin!.isTestnet(wallet)))
    return false;
  return switch (wallet.type) {
    WalletType.monero => monero != null,
    WalletType.solana => solana != null,
    WalletType.tron => tron != null,
    WalletType.zcash => zcash != null,
    _ => true,
  };
}

bool pegarouteDepositSource(WalletBase wallet, PegarouteAssetId source) =>
    pegarouteDepositWallet(wallet) &&
    pegarouteDepositWallets[source.chain] == wallet.type &&
    (source.token == source.nativeToken || source.chain == 'SOL');

bool pegarouteDepositQuote(PegarouteAssetId source, PegarouteRoute route) =>
    source.chain == 'SOL' && route.provider == 'openocean' ||
    pegarouteDepositWallets.containsKey(source.chain) &&
        const {'instaswap', 'thorchain', 'maya'}.contains(route.provider) &&
        (source.token == source.nativeToken ||
            source.chain == 'SOL' && route.provider == 'instaswap') &&
        (_utxo.contains(source.chain) || route.memo == null);

bool pegarouteDepositExecution(TradeExecution execution) {
  if (execution.sourceChain == 'SOL' &&
      execution.family == 'solana' &&
      execution.mode == 'serialized-tx' &&
      execution.routeProvider == 'openocean') {
    return execution.privateIntent == false && !execution.binding.isSendAll;
  }
  if (!const {'instaswap', 'thorchain', 'maya'}.contains(execution.routeProvider) ||
      execution.privateIntent != false ||
      execution.binding.isSendAll ||
      execution.payload['to'] is! String) return false;
  final native = execution.sourceToken == execution.nativeToken;
  if (_utxo.contains(execution.sourceChain)) {
    return native && execution.family == 'utxo' && execution.mode == 'payment-with-memo';
  }
  if (execution.payload['memo'] != null) return false;
  return switch (execution.sourceChain) {
    'ZEC' => native && execution.family == 'utxo' && execution.mode == 'payment-with-memo',
    'XMR' => native && execution.family == 'other' && execution.mode == 'deposit-transfer',
    'SOL' => execution.family == 'solana' &&
        execution.mode == 'deposit-transfer' &&
        (native || execution.routeProvider == 'instaswap'),
    'TRON' => native && execution.family == 'tron' && execution.mode == 'deposit-transfer',
    _ => false,
  };
}

Future<PendingTransaction> preparePegarouteDeposit(
    WalletBase wallet, TradeExecution execution, TransactionPriority? priority) async {
  final source = execution.sourceChain;
  CryptoCurrency currency = _currencies[source]!;
  if (source == 'SOL' && execution.sourceToken != execution.nativeToken) {
    final parts = execution.sourceToken.split('-');
    currency = SPLToken(
        name: parts.first,
        symbol: parts.first,
        mintAddress: parts.last,
        mint: parts.last,
        decimal: execution.binding.sourceDecimals);
  }
  final amount = Money(BigInt.parse(execution.binding.sourceAmountBaseUnits), currency);
  if (source == 'SOL' && execution.mode == 'serialized-tx') {
    return wallet.createTransaction(SolanaSerializedTransactionCredentials(
        transactionBase58: Base58Encoder.encode(decodePegarouteSolanaTransaction(
            execution.payload['serializedTransaction'] as String,
            execution.payload['encoding'] as String)),
        amount: amount,
        destinationAddress: execution.binding.destinationAddress));
  }
  var memo = execution.payload['memo'] as String?;
  // Cake's UTXO builder autodetects hex. Encode text explicitly, including
  // memos such as "1234", so the provider's intended bytes are preserved.
  if (_utxo.contains(source) && memo != null) {
    memo = BytesUtils.toHexString(utf8.encode(memo));
  }
  final output = OutputInfo(
      address: execution.payload['to'] as String,
      cryptoAmount: amount,
      sendAll: false,
      isParsedAddress: false,
      memo: memo);
  final outputs = List<OutputInfo>.unmodifiable([output]);
  final Object credentials;
  if (_utxo.contains(source)) {
    credentials = bitcoin!.createBitcoinTransactionCredentials(
      [_BoundDepositOutput(output)],
      priority: priority ?? bitcoin!.getMediumTransactionPriority(),
      coinTypeToSpendFrom: UnspentCoinType.nonMweb,
      payjoinUri: null,
    );
  } else if (source == 'XMR') {
    credentials = monero!.createMoneroTransactionCreationCredentialsRaw(
        outputs: outputs, priority: priority ?? monero!.getDefaultTransactionPriority());
  } else if (source == 'SOL') {
    credentials = solana!.createSolanaTransactionCredentialsRaw(outputs, currency: currency);
  } else if (source == 'TRON') {
    credentials =
        tron!.createTronTransactionCredentials([_BoundDepositOutput(output)], currency: currency);
  } else {
    // The existing ZEC builder deducts fees from the recipient on an exact
    // balance send, even without send-all. Preserve the exact provider deposit.
    final available = wallet.balance[CryptoCurrency.zec]?.available;
    if (available == null || amount.amount >= available.amount) {
      throw const PegarouteBindingException('ZEC deposit needs additional balance for fees');
    }
    credentials =
        zcash!.createZcashTransactionCredentialsRaw(outputs, currency: currency, feeRate: 0);
  }
  final pending = await wallet.createTransaction(credentials);
  if (pending.amount.amount != amount.amount || pending.shouldCommitUR()) {
    throw const PegarouteBindingException('Cake deposit amount changed');
  }
  return pending;
}

/// Immutable bridge for existing facades that accept UI Output rather than
/// OutputInfo. No screen state or Output autorun is created or shared.
final class _BoundDepositOutput implements Output {
  const _BoundDepositOutput(this.info);
  final OutputInfo info;
  @override
  Money get cryptoAmountMoney => info.cryptoAmount;
  @override
  String get address => info.address;
  @override
  String get fiatAmount => '';
  @override
  String get note => '';
  @override
  String get memo => info.memo ?? '';
  @override
  bool get sendAll => false;
  @override
  bool get isParsedAddress => false;
  @override
  String get extractedAddress => '';
  @override
  Map<String, dynamic> get extra => const {};
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Immutable deposit output');
}

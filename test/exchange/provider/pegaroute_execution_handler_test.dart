import 'dart:convert';

import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_btc_execution_handler.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_eth_execution_handler.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_handler_support.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_xmr_execution_handler.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/transaction_history.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:flutter_test/flutter_test.dart';

const _route =
    '{"provider":"instaswap","providerType":"fixture","subprovider":null,"private":false,"expectedOutput":"0.99","fees":null,"estimatedTimeSeconds":0,"memo":null,"inboundAddress":"provider-inbound","router":"0x0000000000000000000000000000000000000005","minAmount":null,"expiry":null,"gasRate":null,"resolvedFee":null,"openOceanRoute":null}';

TradeExecutionBinding _binding({
  required String sourceAmount,
  required String sourceAmountBaseUnits,
  required int? walletChainId,
  String? providerDepositAddress,
  int sourceDecimals = 0,
  int destinationDecimals = 8,
  String senderAddress = 'sender',
  String destinationAddress = 'destination',
  TradeExecutionExpiry? routeExpiry,
  String reviewedRouteJson = _route,
}) =>
    TradeExecutionBinding(
      tradeId: 'trade-fixture',
      providerRaw: 17,
      quoteId: 'quote-fixture',
      quoteExpiresAt: DateTime.utc(2099),
      routeExpiry: routeExpiry,
      providerDepositAddress: providerDepositAddress,
      sourceAmount: sourceAmount,
      sourceAmountBaseUnits: sourceAmountBaseUnits,
      sourceDecimals: sourceDecimals,
      destinationDecimals: destinationDecimals,
      senderAddress: senderAddress,
      refundAddress: null,
      destinationAddress: destinationAddress,
      isSendAll: false,
      walletId: 'wallet-fixture',
      walletChainId: walletChainId,
      walletAddress: senderAddress,
      reviewedRouteJson: reviewedRouteJson,
      providerReferenceId: null,
    );

ValidatedTradeExecution _validated(TradeExecution execution) =>
    ValidatedTradeExecution(execution: execution, rawExecutionJson: execution.encode());

void main() {
  final now = DateTime.utc(2026);

  test('BTC handler requires an exact payment-with-memo envelope', () {
    final execution = TradeExecution(
      family: 'utxo',
      mode: 'payment-with-memo',
      sourceChain: 'BTC',
      sourceToken: 'BTC',
      nativeToken: 'BTC',
      destinationChain: 'ETH',
      destinationToken: 'ETH',
      binding: _binding(
        sourceAmount: '1',
        sourceAmountBaseUnits: '1',
        walletChainId: null,
        providerDepositAddress: 'provider-btc',
      ),
      routeProvider: 'instaswap',
      payload: {
        'to': 'provider-btc',
        'amount': {'display': '1', 'baseUnits': '1'},
        'memo': null,
        'gasRate': '1',
      },
    );
    final handler = PegarouteBtcExecutionHandler(
      walletContext: _UnsupportedWalletContext(),
      adapter: _UnsupportedBtcAdapter(),
    );

    expect(handler.supports(execution), isTrue);
    expect(
      () => handler.validateForExecution(execution: _validated(execution), now: now),
      returnsNormally,
    );
  });

  test('XMR handler rejects a memo or payment id', () {
    final execution = TradeExecution(
      family: 'other',
      mode: 'deposit-transfer',
      sourceChain: 'XMR',
      sourceToken: 'XMR',
      nativeToken: 'XMR',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      binding: _binding(
        sourceAmount: '1',
        sourceAmountBaseUnits: '1',
        walletChainId: null,
        providerDepositAddress: 'provider-xmr',
      ),
      routeProvider: 'instaswap',
      payload: {
        'chain': 'XMR',
        'to': 'provider-xmr',
        'amount': {'display': '1', 'baseUnits': '1'},
        'memo': 'unexpected',
      },
    );
    final handler = PegarouteXmrExecutionHandler(
      walletContext: _UnsupportedWalletContext(),
      adapter: _UnsupportedXmrAdapter(),
    );

    expect(handler.supports(execution), isTrue);
    expect(
      () => handler.validateForExecution(execution: _validated(execution), now: now),
      throwsA(isA<PegarouteBindingException>()),
    );
  });

  test('native ETH handler requires chain id 1 and no calldata', () {
    final execution = TradeExecution(
      family: 'evm',
      mode: 'native-transfer',
      sourceChain: 'ETH',
      sourceToken: 'ETH',
      nativeToken: 'ETH',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      binding: _binding(
        sourceAmount: '1',
        sourceAmountBaseUnits: '1',
        walletChainId: 1,
        providerDepositAddress: '0x0000000000000000000000000000000000000005',
      ),
      routeProvider: 'instaswap',
      payload: {
        'chainId': 1,
        'to': '0x0000000000000000000000000000000000000005',
        'data': null,
        'value': {'display': '1', 'baseUnits': '1'},
        'gasLimit': '21000',
        'memo': null,
        'approval': null,
        'transferAmount': null,
      },
    );
    final handler = PegarouteEthExecutionHandler(
      walletContext: _UnsupportedWalletContext(),
      adapter: _UnsupportedEthAdapter(),
    );

    expect(handler.supports(execution), isTrue);
    expect(
      () => handler.validateForExecution(execution: _validated(execution), now: now),
      returnsNormally,
    );
  });

  test('handler support predicates are source-chain exact', () {
    final btc = TradeExecution(
      family: 'utxo',
      mode: 'payment-with-memo',
      sourceChain: 'BTC',
      sourceToken: 'BTC',
      nativeToken: 'BTC',
      destinationChain: 'ETH',
      destinationToken: 'ETH',
      binding: _binding(
        sourceAmount: '1',
        sourceAmountBaseUnits: '1',
        walletChainId: null,
        providerDepositAddress: 'provider-btc',
      ),
      routeProvider: 'instaswap',
      payload: const {
        'to': 'provider-btc',
        'amount': {'display': '1', 'baseUnits': '1'},
        'memo': null,
        'gasRate': '1',
      },
    );
    final raw = json.decode(btc.encode()) as Map<String, dynamic>;
    raw['sourceChain'] = 'LTC';
    raw['sourceToken'] = 'LTC';
    raw['nativeToken'] = 'LTC';
    final ltc = TradeExecution.fromJson(raw);
    final handler = PegarouteBtcExecutionHandler(
      walletContext: _UnsupportedWalletContext(),
      adapter: _UnsupportedBtcAdapter(),
    );

    expect(handler.supports(btc), isTrue);
    expect(handler.supports(ltc), isFalse);
  });

  test('strictly decodes depositWithExpiry calldata', () {
    const vault = '0x0000000000000000000000000000000000000007';
    const asset = '0x0000000000000000000000000000000000000000';
    const memo = '=:BTC.BTC:bc1qfixture/0x0000000000000000000000000000000000000002';
    final calldata = _depositWithExpiryCalldata(
      vault: vault,
      asset: asset,
      amount: BigInt.from(42),
      memo: memo,
      expiry: BigInt.from(4102444800),
    );

    final decoded = decodePegarouteDepositWithExpiryCalldata(calldata);
    expect(decoded.vault, vault);
    expect(decoded.asset, asset);
    expect(decoded.amountBaseUnits, '42');
    expect(decoded.memo, memo);
    expect(decoded.expiry, 4102444800);
    expect(
      () => decodePegarouteDepositWithExpiryCalldata('0x00000000${calldata.substring(10)}'),
      throwsA(isA<PegarouteBindingException>()),
    );
    expect(
      () => decodePegarouteDepositWithExpiryCalldata('${calldata}00'),
      throwsA(isA<PegarouteBindingException>()),
    );
  });

  test('BTC preparation binds raw bytes and rejects a later ABA generation', () async {
    final execution = TradeExecution(
      family: 'utxo',
      mode: 'payment-with-memo',
      sourceChain: 'BTC',
      sourceToken: 'BTC',
      nativeToken: 'BTC',
      destinationChain: 'ETH',
      destinationToken: 'ETH',
      binding: _binding(
        sourceAmount: '1',
        sourceAmountBaseUnits: '100000000',
        sourceDecimals: 8,
        destinationDecimals: 18,
        walletChainId: null,
        providerDepositAddress: 'provider-inbound',
        reviewedRouteJson: _route.replaceFirst('"memo":null', '"memo":"memo"'),
      ),
      routeProvider: 'instaswap',
      payload: const {
        'to': 'provider-inbound',
        'amount': {'display': '1', 'baseUnits': '100000000'},
        'memo': 'memo',
        'gasRate': '1',
      },
    );
    final context = _WalletContext();
    final adapter = _BtcAdapter(context);
    final pending = await RegistryTradeExecutionDispatcher([
      PegarouteBtcExecutionHandler(walletContext: context, adapter: adapter),
    ]).prepare(
      wallet: _Wallet(type: WalletType.bitcoin, chainId: null),
      trade: _trade(execution, from: CryptoCurrency.btc, to: CryptoCurrency.eth),
    );

    expect(pending, isNotNull);
    context.generation++;
    await expectLater(pending!.commit(), throwsA(isA<PegarouteBindingException>()));
    expect(adapter.pending.commits, 0);
  });

  test('XMR preparation rejects evidence for different serialized bytes', () async {
    final execution = TradeExecution(
      family: 'other',
      mode: 'deposit-transfer',
      sourceChain: 'XMR',
      sourceToken: 'XMR',
      nativeToken: 'XMR',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      binding: _binding(
        sourceAmount: '1',
        sourceAmountBaseUnits: '1000000000000',
        sourceDecimals: 12,
        walletChainId: null,
        providerDepositAddress: 'provider-inbound',
      ),
      routeProvider: 'instaswap',
      payload: const {
        'chain': 'XMR',
        'to': 'provider-inbound',
        'amount': {'display': '1', 'baseUnits': '1000000000000'},
        'memo': null,
      },
    );
    final context = _WalletContext();
    final pending = await RegistryTradeExecutionDispatcher([
      PegarouteXmrExecutionHandler(
        walletContext: context,
        adapter: _XmrAdapter(context, evidenceRawHex: '0304'),
      ),
    ]).prepare(
      wallet: _Wallet(type: WalletType.monero, chainId: null),
      trade: _trade(execution, from: CryptoCurrency.xmr, to: CryptoCurrency.btc),
    );

    expect(pending, isNull);
  });

  test('native ETH preparation requires a hash derived from the exact pending bytes', () async {
    const sender = '0x0000000000000000000000000000000000000002';
    const target = '0x0000000000000000000000000000000000000001';
    final execution = TradeExecution(
      family: 'evm',
      mode: 'native-transfer',
      sourceChain: 'ETH',
      sourceToken: 'ETH',
      nativeToken: 'ETH',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      binding: _binding(
        sourceAmount: '1',
        sourceAmountBaseUnits: '1000000000000000000',
        sourceDecimals: 18,
        walletChainId: 1,
        senderAddress: sender,
        destinationAddress: 'bc1qfixture',
        reviewedRouteJson:
            '{"provider":"instaswap","providerType":"fixture","subprovider":null,"private":false,"expectedOutput":"0.99","fees":null,"estimatedTimeSeconds":0,"memo":null,"inboundAddress":"$target","router":null,"minAmount":null,"expiry":null,"gasRate":null,"resolvedFee":null,"openOceanRoute":null}',
      ),
      routeProvider: 'instaswap',
      payload: const {
        'chainId': 1,
        'to': target,
        'data': null,
        'value': {'display': '1', 'baseUnits': '1000000000000000000'},
        'gasLimit': '21000',
        'memo': null,
        'approval': null,
        'transferAmount': null,
      },
    );
    final context = _WalletContext();
    final pending = await RegistryTradeExecutionDispatcher([
      PegarouteEthExecutionHandler(
        walletContext: context,
        adapter: _EthAdapter(
          context,
          evidenceHash: '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
      ),
    ]).prepare(
      wallet: _Wallet(type: WalletType.ethereum, chainId: 1, address: sender),
      trade: _trade(execution, from: CryptoCurrency.eth, to: CryptoCurrency.btc),
    );

    expect(pending, isNull);
  });

  test('THOR ETH calls require decoded, non-shorthand payout intent', () async {
    const sender = '0x0000000000000000000000000000000000000002';
    const router = '0x0000000000000000000000000000000000000005';
    const vault = '0x0000000000000000000000000000000000000007';
    final expiry = TradeExecutionExpiry.fromProviderValue(4102444800);

    Future<PendingTransaction?> prepare(String memo) {
      final data = _depositWithExpiryCalldata(
        vault: vault,
        asset: '0x0000000000000000000000000000000000000000',
        amount: BigInt.parse('1000000000000000000'),
        memo: memo,
        expiry: BigInt.from(4102444800),
      );
      final route = json.encode({
        'provider': 'thorchain',
        'providerType': 'fixture',
        'subprovider': null,
        'private': false,
        'expectedOutput': '0.99',
        'fees': null,
        'estimatedTimeSeconds': 0,
        'memo': memo,
        'inboundAddress': vault,
        'router': router,
        'minAmount': null,
        'expiry': expiry.toJson(),
        'gasRate': null,
        'resolvedFee': null,
        'openOceanRoute': null,
      });
      final execution = TradeExecution(
        family: 'evm',
        mode: 'contract-call',
        sourceChain: 'ETH',
        sourceToken: 'ETH',
        nativeToken: 'ETH',
        destinationChain: 'BTC',
        destinationToken: 'BTC',
        binding: _binding(
          sourceAmount: '1',
          sourceAmountBaseUnits: '1000000000000000000',
          sourceDecimals: 18,
          walletChainId: 1,
          senderAddress: sender,
          destinationAddress: 'bc1qfixture',
          routeExpiry: expiry,
          reviewedRouteJson: route,
        ),
        routeProvider: 'thorchain',
        payload: {
          'chainId': 1,
          'to': router,
          'data': data,
          'value': {'display': '1', 'baseUnits': '1000000000000000000'},
          'gasLimit': null,
          'memo': memo,
          'approval': null,
          'transferAmount': null,
        },
      );
      final context = _WalletContext();
      return RegistryTradeExecutionDispatcher([
        PegarouteEthExecutionHandler(
          walletContext: context,
          adapter: _EthContractAdapter(context, router: router, vault: vault, memo: memo),
        ),
      ]).prepare(
        wallet: _Wallet(type: WalletType.ethereum, chainId: 1, address: sender),
        trade: _trade(execution, from: CryptoCurrency.eth, to: CryptoCurrency.btc),
      );
    }

    expect(await prepare('=:BTC.BTC:bc1qfixture'), isNotNull);
    expect(await prepare('=:b:bc1qfixture'), isNull);
  });
}

String _depositWithExpiryCalldata({
  required String vault,
  required String asset,
  required BigInt amount,
  required String memo,
  required BigInt expiry,
}) {
  String word(BigInt value) => value.toRadixString(16).padLeft(64, '0');
  String address(String value) => value.substring(2).toLowerCase().padLeft(64, '0');
  final memoHex = utf8.encode(memo).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final paddedMemo = memoHex.padRight(((memoHex.length + 63) ~/ 64) * 64, '0');
  return '0x44bc937b${address(vault)}${address(asset)}${word(amount)}${word(BigInt.from(160))}'
      '${word(expiry)}${word(BigInt.from(utf8.encode(memo).length))}$paddedMemo';
}

Trade _trade(
  TradeExecution execution, {
  required CryptoCurrency from,
  required CryptoCurrency to,
}) =>
    Trade(
      id: execution.binding.tradeId,
      amount: execution.binding.sourceAmount,
      from: from,
      to: to,
      provider: ExchangeProviderDescription.pegaroute,
      senderAddress: execution.binding.senderAddress,
      refundAddress: execution.binding.refundAddress,
      payoutAddress: execution.binding.destinationAddress,
      walletId: execution.binding.walletId,
      fromWalletAddress: execution.binding.walletAddress,
      chainId: execution.binding.walletChainId,
      providerName: execution.routeProvider,
      providerId: execution.binding.providerReferenceId,
      executionJson: execution.encode(),
    );

final class _Addresses implements WalletAddresses {
  _Addresses(this.address);

  @override
  final String address;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Wallet
    extends WalletBase<Balance, TransactionHistoryBase<TransactionInfo>, TransactionInfo> {
  _Wallet({required WalletType type, required this.chainId, String address = 'sender'})
      : _addresses = _Addresses(address),
        super(
          WalletInfo.external(
            id: 'wallet-fixture',
            name: 'wallet-fixture',
            type: type,
            isRecovery: false,
            restoreHeight: 0,
            date: DateTime.utc(2026),
            dirPath: '',
            path: '',
            address: address,
          ),
          DerivationInfo(),
        );

  final _Addresses _addresses;

  @override
  final int? chainId;

  @override
  WalletAddresses get walletAddresses => _addresses;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Pending with PendingTransaction {
  _Pending({required this.id, required this.hex, this.evmHash});

  @override
  final String id;

  @override
  final String hex;

  final String? evmHash;
  int commits = 0;

  @override
  String? get evmTxHashFromRawHex => evmHash;

  @override
  Money get amount => Money.zero(CryptoCurrency.eth);

  @override
  Money get fee => Money.zero(CryptoCurrency.eth);

  @override
  String get amountFormatted => '0';

  @override
  Future<void> commit() async {
    commits++;
  }

  @override
  Future<Map<String, String>> commitUR() => throw UnimplementedError();
}

final class _WalletContext implements PegarouteWalletContext {
  int generation = 0;

  @override
  PegarouteWalletSnapshot snapshot(WalletBase wallet) => PegarouteWalletSnapshot(
        walletId: wallet.id,
        address: wallet.walletAddresses.address,
        chainId: wallet.chainId,
        generation: generation,
        isHardwareWallet: false,
      );
}

final class _BtcAdapter implements PegarouteBtcWalletAdapter {
  _BtcAdapter(this.context)
      : pending = _Pending(
          id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          hex: '0102',
        );

  final _WalletContext context;
  final _Pending pending;

  @override
  Future<PegaroutePreparedTransaction<PegarouteBtcTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  }) async =>
      PegaroutePreparedTransaction(
        pending: pending,
        evidence: PegarouteBtcTransactionEvidence(
          rawHex: '0102',
          transactionId: pending.id,
          chain: 'BTC',
          destination: 'provider-inbound',
          amountBaseUnits: '100000000',
          paymentOutputCount: 1,
          opReturnPayloads: [utf8.encode('memo')],
          hasSilentPayment: false,
          snapshot: context.snapshot(wallet),
        ),
        snapshot: context.snapshot(wallet),
      );
}

final class _XmrAdapter implements PegarouteXmrWalletAdapter {
  _XmrAdapter(this.context, {required this.evidenceRawHex})
      : pending = _Pending(
          id: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
          hex: '0102',
        );

  final _WalletContext context;
  final String evidenceRawHex;
  final _Pending pending;

  @override
  Future<PegaroutePreparedTransaction<PegarouteXmrTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  }) async =>
      PegaroutePreparedTransaction(
        pending: pending,
        evidence: PegarouteXmrTransactionEvidence(
          rawHex: evidenceRawHex,
          transactionId: pending.id,
          chain: 'XMR',
          destination: 'provider-inbound',
          amountBaseUnits: '1000000000000',
          paymentOutputCount: 1,
          paymentId: '',
          memo: null,
          snapshot: context.snapshot(wallet),
        ),
        snapshot: context.snapshot(wallet),
      );
}

final class _EthAdapter implements PegarouteEthWalletAdapter {
  _EthAdapter(this.context, {required this.evidenceHash})
      : pending = _Pending(
          id: '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          hex: '0x0102',
          evmHash: '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        );

  final _WalletContext context;
  final String evidenceHash;
  final _Pending pending;

  @override
  Future<PegaroutePreparedTransaction<PegarouteEthTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  }) async =>
      PegaroutePreparedTransaction(
        pending: pending,
        evidence: PegarouteEthTransactionEvidence(
          rawHex: pending.hex,
          chainId: 1,
          to: '0x0000000000000000000000000000000000000001',
          valueBaseUnits: '1000000000000000000',
          data: null,
          gasLimit: '21000',
          approvalPresent: false,
          transactionHash: evidenceHash,
          snapshot: context.snapshot(wallet),
        ),
        snapshot: context.snapshot(wallet),
      );
}

final class _EthContractAdapter implements PegarouteEthWalletAdapter {
  _EthContractAdapter(
    this.context, {
    required this.router,
    required this.vault,
    required this.memo,
  });

  final _WalletContext context;
  final String router;
  final String vault;
  final String memo;

  @override
  Future<PegaroutePreparedTransaction<PegarouteEthTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  }) async {
    const hash = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final pending = _Pending(id: hash, hex: '0x0102', evmHash: hash);
    return PegaroutePreparedTransaction(
      pending: pending,
      evidence: PegarouteEthTransactionEvidence(
        rawHex: pending.hex,
        chainId: 1,
        to: router,
        valueBaseUnits: '1000000000000000000',
        data: execution.execution.payload['data'] as String,
        gasLimit: null,
        approvalPresent: false,
        transactionHash: hash,
        snapshot: context.snapshot(wallet),
        depositWithExpiry: PegarouteEvmDepositWithExpiryEvidence(
          router: router,
          vault: vault,
          asset: '0x0000000000000000000000000000000000000000',
          amountBaseUnits: '1000000000000000000',
          memo: memo,
          expiry: 4102444800,
          destinationChain: 'BTC',
          destinationToken: 'BTC',
          destinationAddress: 'bc1qfixture',
          refundAddress: null,
        ),
      ),
      snapshot: context.snapshot(wallet),
    );
  }
}

final class _UnsupportedWalletContext implements PegarouteWalletContext {
  @override
  PegarouteWalletSnapshot snapshot(WalletBase wallet) =>
      throw UnsupportedError('wallet construction is not part of this test');
}

final class _UnsupportedBtcAdapter implements PegarouteBtcWalletAdapter {
  @override
  Future<PegaroutePreparedTransaction<PegarouteBtcTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  }) =>
      throw UnsupportedError('wallet construction is not part of this test');
}

final class _UnsupportedXmrAdapter implements PegarouteXmrWalletAdapter {
  @override
  Future<PegaroutePreparedTransaction<PegarouteXmrTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  }) =>
      throw UnsupportedError('wallet construction is not part of this test');
}

final class _UnsupportedEthAdapter implements PegarouteEthWalletAdapter {
  @override
  Future<PegaroutePreparedTransaction<PegarouteEthTransactionEvidence>> prepare({
    required WalletBase wallet,
    required PegarouteWalletSnapshot snapshot,
    required ValidatedTradeExecution execution,
  }) =>
      throw UnsupportedError('wallet construction is not part of this test');
}

import 'dart:async';

import 'package:cake_wallet/evm/evm.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/trade_state.dart';
import 'package:cake_wallet/exchange/trade_refund.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/db/sqlite.dart';
import 'package:cw_core/format_amount.dart';
import 'package:cw_core/generate_name.dart';
import 'package:sqflite/sqflite.dart';

enum _PegarouteTransition { stale, same, advance }

class Trade {
  Trade({
    this.internalId = 0,
    required this.id,
    required this.amount,
    ExchangeProviderDescription? provider,
    this.from,
    this.to,
    TradeState? state,
    this.receiveAmount,
    this.createdAt,
    this.expiredAt,
    this.inputAddress,
    this.extraId,
    this.outputTransaction,
    this.refundAddress,
    this.senderAddress,
    this.walletId,
    this.payoutAddress,
    this.toAddressExtraId,
    this.password,
    this.providerId,
    this.providerName,
    this.fromWalletAddress,
    this.memo,
    this.fee,
    this.txId,
    this.isRefund,
    this.isSendAll,
    this.router,
    // The following fields are used for SwapXyz trades only
    this.needToRegisterInSwapXyz,
    this.sourceTokenAddress,
    this.sourceTokenDecimals,
    this.routerData,
    this.routerValue,
    this.routerChainId,
    this.sourceTokenAmountRaw,
    this.requiresTokenApproval,
    this.chainId,
    this.executionJson,
    this.refundJson,
  }) {
    if (provider != null) providerRaw = provider.raw;
    if (state != null) stateRaw = state.raw;
  }

  static const tableName = 'Trade';
  static const selfIdColumn = 'tradeId';

  static const boxName = 'Trades';
  static const boxKey = 'tradesBoxKey';

  static final StreamController<void> onChanged = StreamController<void>.broadcast();

  int internalId;

  String id;

  int providerRaw = 0;

  ExchangeProviderDescription get provider =>
      ExchangeProviderDescription.deserialize(raw: providerRaw);

  CryptoCurrency? from;
  CryptoCurrency? to;

  String stateRaw = '';

  TradeState get state => TradeState.deserialize(raw: stateRaw);

  DateTime? createdAt;
  DateTime? expiredAt;
  String amount;
  String? receiveAmount;
  String? inputAddress;
  String? extraId;
  String? outputTransaction;
  String? refundAddress;
  String? senderAddress;
  String? walletId;
  String? payoutAddress;

  // holds the receive address memo or destination tag that was passed for this trade
  String? toAddressExtraId;
  String? password;
  String? providerId;
  String? providerName;
  String? fromWalletAddress;
  String? memo;
  String? txId;
  bool? isRefund;
  bool? isSendAll;
  String? router;

  // The following fields are used for SwapXyz trades only
  bool? needToRegisterInSwapXyz;
  String? sourceTokenAddress;
  int? sourceTokenDecimals;
  String? routerData;
  String? routerValue;
  int? routerChainId;
  String? sourceTokenAmountRaw;
  bool? requiresTokenApproval;

  int? chainId;
  double? fee;
  String? executionJson;
  String? refundJson;

  String get chainName {
    if (chainId == null) return '';

    return evm!.getChainNameByChainId(chainId!).capitalized();
  }

  // ── SQLite CRUD ──────────────────────────────────────

  Future<int> save() async {
    final json = toSqliteMap();
    if (json[selfIdColumn] == 0) {
      json[selfIdColumn] = null;
    }
    internalId = await db!.insert(
      tableName,
      json,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    onChanged.add(null);
    return internalId;
  }

  static Future<List<Trade>> getAll({String? orderBy}) async {
    final list = await db!.query(
      tableName,
      orderBy: orderBy ?? 'createdAt DESC',
    );
    return List.generate(
      list.length,
      (i) => Trade.fromSqliteRow(list[i]),
    );
  }

  static Future<Trade?> getByTradeId(String id) async {
    final list = await db!.query(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (list.isEmpty) return null;
    return Trade.fromSqliteRow(list.first);
  }

  static Future<int> deleteTrade(Trade trade) async {
    final rows = await db!.delete(
      tableName,
      where: '$selfIdColumn = ?',
      whereArgs: [trade.internalId],
    );
    onChanged.add(null);
    return rows;
  }

  /// Merge a validated Pegaroute status against the row that is current at
  /// commit time. The execution envelope is immutable context, so a status
  /// update must prove that it was validated against the same raw envelope.
  Future<Trade> mergeAndSavePegaroute(
    Trade updated, {
    required String expectedRawExecutionJson,
  }) async {
    if (providerRaw != 17 || updated.providerRaw != 17 || updated.id != id) {
      throw StateError('invalid Pegaroute trade update');
    }
    if (expectedRawExecutionJson.isEmpty ||
        executionJson != expectedRawExecutionJson ||
        (updated.executionJson != null && updated.executionJson != expectedRawExecutionJson)) {
      throw StateError('Pegaroute execution context changed');
    }

    late Trade committed;
    await db!.transaction((txn) async {
      final rows = await txn.query(
        tableName,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Pegaroute trade no longer exists');

      final latest = Trade.fromSqliteRow(rows.first);
      if (latest.providerRaw != 17 || latest.executionJson != expectedRawExecutionJson) {
        throw StateError('Pegaroute execution context changed');
      }

      final transition = _pegarouteTransition(latest.stateRaw, updated.stateRaw);
      if (transition != _PegarouteTransition.stale) {
        _mergePegarouteEvidence(
          latest,
          updated,
          advancing: transition == _PegarouteTransition.advance,
        );
      }

      final values = latest.toSqliteMap()..remove(selfIdColumn);
      final changed = await txn.update(
        tableName,
        values,
        where: '$selfIdColumn = ?',
        whereArgs: [latest.internalId],
      );
      if (changed != 1) throw StateError('Pegaroute trade changed during status merge');
      committed = latest;
    });

    final localFrom = from;
    final localTo = to;
    final localAmount = amount;
    final localPayoutAddress = payoutAddress;
    final localMemo = memo;
    _synchronizeFrom(committed);
    // SQLite may deserialize a qualified token as a generic currency. Keep
    // the live reviewed objects and local intent on the polling instance.
    from = localFrom ?? from;
    to = localTo ?? to;
    if (localAmount.isNotEmpty) amount = localAmount;
    if (localPayoutAddress != null) payoutAddress = localPayoutAddress;
    if (localMemo != null) memo = localMemo;
    onChanged.add(null);
    return this;
  }

  // ── SQLite serialization ─────────────────────────────
  void mergeFindTradeByIdResult(Trade updated) {
    if (providerRaw == 17) {
      final transition = _pegarouteTransition(stateRaw, updated.stateRaw);
      if (transition != _PegarouteTransition.stale) {
        _mergePegarouteEvidence(
          this,
          updated,
          advancing: transition == _PegarouteTransition.advance,
        );
      }
      return;
    }

    if (updated.stateRaw.isNotEmpty) {
      stateRaw = updated.stateRaw;
    }
    if (createdAt == null && updated.createdAt != null) {
      createdAt = updated.createdAt;
    }
    if (updated.expiredAt != null) expiredAt = updated.expiredAt;
    if (updated.isRefund != null) isRefund = updated.isRefund;

    if (updated.receiveAmount != null) receiveAmount = updated.receiveAmount;
    if (updated.inputAddress != null) inputAddress = updated.inputAddress;
    if (updated.extraId != null) extraId = updated.extraId;
    if (updated.outputTransaction != null) {
      outputTransaction = updated.outputTransaction;
    }
    if (senderAddress == null && updated.senderAddress != null) {
      senderAddress = updated.senderAddress;
    }
    if (refundAddress == null && refundJson?.isNotEmpty != true && updated.refundAddress != null) {
      refundAddress = updated.refundAddress;
    }
    if (updated.payoutAddress != null) payoutAddress = updated.payoutAddress;
    if (updated.password != null) password = updated.password;
    if (updated.providerId != null) providerId = updated.providerId;
    if (updated.providerName != null) providerName = updated.providerName;
    if (updated.memo != null) memo = updated.memo;
    if (updated.txId != null) txId = updated.txId;
    if (updated.refundJson != null) {
      final currentRefundJson = refundJson?.isNotEmpty == true
          ? refundJson
          : refundAddress == null
              ? null
              : TradeRefund(configuredAddress: refundAddress).encode();
      refundJson = TradeRefund.mergeJson(currentRefundJson, updated.refundJson!);
    }
  }

  static const _pegarouteNormalStateRank = {
    'created': 0,
    'confirming': 1,
    'exchanging': 2,
    'sending': 3,
  };

  static _PegarouteTransition _pegarouteTransition(String current, String next) {
    if (next.isEmpty) return _PegarouteTransition.stale;
    if (current == next) return _PegarouteTransition.same;
    if (current.isEmpty) return _PegarouteTransition.advance;
    if (current == 'success' || current == 'refunded') return _PegarouteTransition.stale;
    if (next == 'refunded') return _PegarouteTransition.advance;
    if (current == 'refund') {
      return _PegarouteTransition.stale;
    }
    if (current == 'failed') return _PegarouteTransition.stale;

    final currentRank = _pegarouteNormalStateRank[current];
    if (currentRank == null) return _PegarouteTransition.stale;
    if (next == 'refund' || next == 'failed' || next == 'success') {
      return _PegarouteTransition.advance;
    }
    final nextRank = _pegarouteNormalStateRank[next];
    return nextRank != null && nextRank > currentRank
        ? _PegarouteTransition.advance
        : _PegarouteTransition.stale;
  }

  static void _mergePegarouteEvidence(
    Trade current,
    Trade updated, {
    required bool advancing,
  }) {
    if (current.createdAt == null && updated.createdAt != null) {
      current.createdAt = updated.createdAt;
    }

    String? merge(String? existing, String? incoming) {
      if (incoming == null || incoming.isEmpty) return existing;
      return advancing || existing == null ? incoming : existing;
    }

    current.stateRaw = updated.stateRaw;
    // The reviewed asset pair, amount, payout, and memo are local intent. A
    // provider status can never replace them, even on a forward transition.
    if (current.isRefund != true && updated.isRefund == true) current.isRefund = true;
    current.receiveAmount = merge(current.receiveAmount, updated.receiveAmount);
    current.inputAddress = merge(current.inputAddress, updated.inputAddress);
    current.extraId = merge(current.extraId, updated.extraId);
    current.outputTransaction = merge(current.outputTransaction, updated.outputTransaction);
    if (current.payoutAddress == null) current.payoutAddress = updated.payoutAddress;
    if (current.providerId == null) current.providerId = updated.providerId;
    if (current.providerName == null) current.providerName = updated.providerName;
    if (current.memo == null) current.memo = updated.memo;
    current.txId = merge(current.txId, updated.txId);

    // These values are bound local intent. A status may fill a legacy hole,
    // but it cannot replace the address the user originally configured.
    if (current.senderAddress == null && updated.senderAddress != null) {
      current.senderAddress = updated.senderAddress;
    }
    if (current.refundAddress == null && updated.refundAddress != null) {
      current.refundAddress = updated.refundAddress;
    }
    if (updated.refundJson != null) {
      final currentRefundJson = current.refundJson?.isNotEmpty == true
          ? current.refundJson
          : current.refundAddress == null
              ? null
              : TradeRefund(configuredAddress: current.refundAddress).encode();
      current.refundJson = TradeRefund.mergeJson(currentRefundJson, updated.refundJson!);
    }
  }

  void _synchronizeFrom(Trade other) {
    internalId = other.internalId;
    id = other.id;
    providerRaw = other.providerRaw;
    from = other.from;
    to = other.to;
    stateRaw = other.stateRaw;
    createdAt = other.createdAt;
    expiredAt = other.expiredAt;
    amount = other.amount;
    receiveAmount = other.receiveAmount;
    inputAddress = other.inputAddress;
    extraId = other.extraId;
    outputTransaction = other.outputTransaction;
    refundAddress = other.refundAddress;
    senderAddress = other.senderAddress;
    walletId = other.walletId;
    payoutAddress = other.payoutAddress;
    toAddressExtraId = other.toAddressExtraId;
    password = other.password;
    providerId = other.providerId;
    providerName = other.providerName;
    fromWalletAddress = other.fromWalletAddress;
    memo = other.memo;
    txId = other.txId;
    isRefund = other.isRefund;
    isSendAll = other.isSendAll;
    router = other.router;
    needToRegisterInSwapXyz = other.needToRegisterInSwapXyz;
    sourceTokenAddress = other.sourceTokenAddress;
    sourceTokenDecimals = other.sourceTokenDecimals;
    routerData = other.routerData;
    routerValue = other.routerValue;
    routerChainId = other.routerChainId;
    sourceTokenAmountRaw = other.sourceTokenAmountRaw;
    requiresTokenApproval = other.requiresTokenApproval;
    chainId = other.chainId;
    fee = other.fee;
    executionJson = other.executionJson;
    refundJson = other.refundJson;
  }

  Map<String, dynamic> toSqliteMap() {
    return <String, dynamic>{
      selfIdColumn: internalId,
      'id': id,
      'providerRaw': providerRaw,
      'fromTitle': from?.title,
      'fromName': from?.name,
      'fromTag': from?.tag,
      'fromFullName': from?.fullName,
      'fromDecimals': from?.decimals,
      'fromRaw': from?.raw,
      'fromIconPath': from?.iconPath,
      'fromFlatIconPath': from?.flatIconPath,
      'fromChainIconPath': from?.chainIconPath,
      'toTitle': to?.title,
      'toName': to?.name,
      'toTag': to?.tag,
      'toFullName': to?.fullName,
      'toDecimals': to?.decimals,
      'toRaw': to?.raw,
      'toIconPath': to?.iconPath,
      'toFlatIconPath': to?.flatIconPath,
      'toChainIconPath': to?.chainIconPath,
      'stateRaw': stateRaw,
      'createdAt': createdAt?.millisecondsSinceEpoch,
      'expiredAt': expiredAt?.millisecondsSinceEpoch,
      'amount': amount,
      'receiveAmount': receiveAmount,
      'inputAddress': inputAddress,
      'extraId': extraId,
      'outputTransaction': outputTransaction,
      'refundAddress': refundAddress,
      'senderAddress': senderAddress,
      'walletId': walletId,
      'payoutAddress': payoutAddress,
      'toAddressExtraId': toAddressExtraId,
      'password': password,
      'providerId': providerId,
      'providerName': providerName,
      'fromWalletAddress': fromWalletAddress,
      'memo': memo,
      'txId': txId,
      'isRefund': isRefund == true ? 1 : 0,
      'isSendAll': isSendAll == true ? 1 : 0,
      'router': router,
      'needToRegisterInSwapXyz': needToRegisterInSwapXyz == true ? 1 : 0,
      'sourceTokenAddress': sourceTokenAddress,
      'sourceTokenDecimals': sourceTokenDecimals,
      'routerData': routerData,
      'routerValue': routerValue,
      'routerChainId': routerChainId,
      'sourceTokenAmountRaw': sourceTokenAmountRaw,
      'requiresTokenApproval': requiresTokenApproval == true ? 1 : 0,
      'chainId': chainId,
      'fee': fee,
      'executionJson': executionJson,
      'refundJson': refundJson,
    };
  }

  factory Trade.fromSqliteRow(Map<String, dynamic> row) {
    final trade = Trade(
      id: row['id'] as String? ?? '',
      amount: row['amount'] as String? ?? '',
      receiveAmount: row['receiveAmount'] as String?,
      createdAt: row['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              row['createdAt'] as int,
            )
          : null,
      expiredAt: row['expiredAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              row['expiredAt'] as int,
            )
          : null,
      inputAddress: row['inputAddress'] as String?,
      extraId: row['extraId'] as String?,
      outputTransaction: row['outputTransaction'] as String?,
      refundAddress: row['refundAddress'] as String?,
      senderAddress: row['senderAddress'] as String?,
      walletId: row['walletId'] as String?,
      payoutAddress: row['payoutAddress'] as String?,
      toAddressExtraId: row['toAddressExtraId'] as String?,
      password: row['password'] as String?,
      providerId: row['providerId'] as String?,
      providerName: row['providerName'] as String?,
      fromWalletAddress: row['fromWalletAddress'] as String?,
      memo: row['memo'] as String?,
      fee: row['fee'] as double?,
      txId: row['txId'] as String?,
      isRefund: (row['isRefund'] as int?) == 1,
      isSendAll: (row['isSendAll'] as int?) == 1,
      router: row['router'] as String?,
      from: _currencyFromRow(row, 'from'),
      to: _currencyFromRow(row, 'to'),
      needToRegisterInSwapXyz: (row['needToRegisterInSwapXyz'] as int?) == 1,
      sourceTokenAddress: row['sourceTokenAddress'] as String?,
      sourceTokenDecimals: row['sourceTokenDecimals'] as int?,
      routerData: row['routerData'] as String?,
      routerValue: row['routerValue'] as String?,
      routerChainId: row['routerChainId'] as int?,
      sourceTokenAmountRaw: row['sourceTokenAmountRaw'] as String?,
      requiresTokenApproval: (row['requiresTokenApproval'] as int?) == 1,
      chainId: row['chainId'] as int?,
      executionJson: row['executionJson'] as String?,
      refundJson: row['refundJson'] as String?,
    );
    trade.internalId = row[selfIdColumn] as int? ?? 0;
    trade.providerRaw = row['providerRaw'] as int? ?? 0;
    trade.stateRaw = row['stateRaw'] as String? ?? '';
    return trade;
  }

  static CryptoCurrency? _currencyFromRow(Map<String, dynamic> row, String prefix) {
    final title = row['${prefix}Title'] as String?;
    if (title == null || title.isEmpty) return null;

    final tag = row['${prefix}Tag'] as String?;

    final live = CryptoCurrency.safeParseCurrencyFromString(title, tag: tag);
    if (live != null) return live;

    return CryptoCurrency(
      title: title,
      name: row['${prefix}Name'] as String? ?? '',
      tag: tag,
      fullName: row['${prefix}FullName'] as String?,
      decimals: row['${prefix}Decimals'] as int? ?? 1,
      raw: row['${prefix}Raw'] as int? ?? -1,
      iconPath: row['${prefix}IconPath'] as String?,
      flatIconPath: row['${prefix}FlatIconPath'] as String?,
      chainIconPath: row['${prefix}ChainIconPath'] as String?,
    );
  }

  String amountFormatted() => formatAmount(amount);
  String receiveAmountFormatted() => formatAmount(receiveAmount ?? '');
}

import 'dart:async';

import 'package:cake_wallet/evm/evm.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_asset_identity.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_currency_mapper.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/trade_state.dart';
import 'package:cake_wallet/exchange/trade_refund.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/db/sqlite.dart';
import 'package:cw_core/format_amount.dart';
import 'package:cw_core/generate_name.dart';
import 'package:sqflite/sqflite.dart';

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
    this.executionLifecycleJson,
  }) {
    if (provider != null) providerRaw = provider.raw;
    if (state != null) stateRaw = state.raw;
    _persistedAsPegaroute =
        internalId != 0 && providerRaw == ExchangeProviderDescription.pegaroute.raw;
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
  String? executionLifecycleJson;

  // Retain provenance even if a caller changes the public id/provider fields.
  bool _persistedAsPegaroute = false;

  String get chainName {
    if (chainId == null) return '';

    return evm!.getChainNameByChainId(chainId!).capitalized();
  }

  // ── SQLite CRUD ──────────────────────────────────────

  Future<int> save() async {
    final isPegaroute = providerRaw == ExchangeProviderDescription.pegaroute.raw;
    if (_persistedAsPegaroute || isPegaroute && internalId != 0) {
      throw StateError('Persisted Pegaroute trades require provider-owned updates');
    }
    final json = toSqliteMap();
    if (json[selfIdColumn] == 0) {
      json[selfIdColumn] = null;
    }
    internalId = await db!.transaction((txn) async {
      // A different provider (or a caller changing providerRaw) must not use
      // INSERT OR REPLACE to delete a protected row through either unique key.
      final protected = await txn.query(
        tableName,
        columns: [selfIdColumn],
        where:
            'providerRaw = ? AND (id = ?${json[selfIdColumn] == null ? '' : ' OR $selfIdColumn = ?'})',
        whereArgs: [
          ExchangeProviderDescription.pegaroute.raw,
          json['id'],
          if (json[selfIdColumn] != null) json[selfIdColumn],
        ],
        limit: 1,
      );
      if (protected.isNotEmpty) {
        throw StateError('Generic save cannot replace a Pegaroute trade');
      }
      if (isPegaroute) {
        const validator = PegarouteExecutionBindingValidator();
        // Validate the serialized snapshot, including restored token identity,
        // before insertion and the actual SQLite representation before commit.
        validator.validatePersisted(trade: Trade.fromSqliteRow(json));
        final insertedId =
            await txn.insert(tableName, json, conflictAlgorithm: ConflictAlgorithm.abort);
        final rows =
            await txn.query(tableName, where: '$selfIdColumn = ?', whereArgs: [insertedId]);
        validator.validatePersisted(
          trade: Trade.fromSqliteRow(rows.single),
          expectedRawExecutionJson: json['executionJson'] as String,
        );
        return insertedId;
      }
      return txn.insert(tableName, json, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    _persistedAsPegaroute = isPegaroute;
    onChanged.add(null);
    return internalId;
  }

  static Future<List<Trade>> getAll({String? orderBy}) async {
    final list = await db!.query(tableName, orderBy: orderBy ?? 'createdAt DESC');
    return List.generate(list.length, (i) => Trade.fromSqliteRow(list[i]));
  }

  static Future<Trade?> getByTradeId(String id) async {
    final list = await db!.query(tableName, where: 'id = ?', whereArgs: [id], limit: 1);
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

  /// Kept as a hard boundary for callers that still compile against the old
  /// API. Pegaroute status writes belong to its provider, where the response
  /// and persisted execution binding can remain private to one operation.
  Future<Trade> mergeAndSavePegaroute(
    Trade updated, {
    required String expectedRawExecutionJson,
  }) async =>
      throw StateError('Pegaroute status writes are provider-owned');

  // ── SQLite serialization ─────────────────────────────
  void mergeFindTradeByIdResult(Trade updated) {
    if (providerRaw == 17) {
      // A Pegaroute response is not a writable Trade value. The provider
      // owns response validation and the atomic status transaction.
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

  /// Copies only the committed provider result into the live caller. The
  /// reviewed local asset and intent objects remain authoritative.
  void synchronizeFromPegarouteRefresh(Trade other) {
    final localFrom = from;
    final localTo = to;
    final localAmount = amount;
    final localPayoutAddress = payoutAddress;
    final localMemo = memo;
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
    executionLifecycleJson = other.executionLifecycleJson;
    from = localFrom ?? from;
    to = localTo ?? to;
    if (localAmount.isNotEmpty) amount = localAmount;
    if (localPayoutAddress != null) payoutAddress = localPayoutAddress;
    if (localMemo != null) memo = localMemo;
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
      'executionLifecycleJson': executionLifecycleJson,
      if (providerRaw == ExchangeProviderDescription.pegaroute.raw) ...{
        'fromAssetIdentityJson': PegarouteAssetIdentity.encode(from),
        'toAssetIdentityJson': PegarouteAssetIdentity.encode(to),
      },
    };
  }

  factory Trade.fromSqliteRow(Map<String, dynamic> row) {
    final trade = Trade(
      id: row['id'] as String? ?? '',
      amount: row['amount'] as String? ?? '',
      receiveAmount: row['receiveAmount'] as String?,
      createdAt: row['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['createdAt'] as int)
          : null,
      expiredAt: row['expiredAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['expiredAt'] as int)
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
      executionLifecycleJson: row['executionLifecycleJson'] as String?,
    );
    trade.internalId = row[selfIdColumn] as int? ?? 0;
    trade.providerRaw = row['providerRaw'] as int? ?? 0;
    trade.stateRaw = row['stateRaw'] as String? ?? '';
    trade._persistedAsPegaroute =
        trade.internalId != 0 && trade.providerRaw == ExchangeProviderDescription.pegaroute.raw;
    return trade;
  }

  static CryptoCurrency? _currencyFromRow(Map<String, dynamic> row, String prefix) {
    if (row['providerRaw'] == ExchangeProviderDescription.pegaroute.raw &&
        row['${prefix}AssetIdentityJson'] != null) {
      // A corrupt identity never falls back to a title/tag alias. Keep the row
      // readable for history while execution/status validation fails closed.
      try {
        final raw = row['${prefix}AssetIdentityJson'];
        if (raw is! String) return null;
        final currency = PegarouteAssetIdentity.decode(raw);
        if (currency.title != row['${prefix}Title'] ||
            currency.name != row['${prefix}Name'] ||
            currency.tag != row['${prefix}Tag'] ||
            currency.decimals != row['${prefix}Decimals']) {
          return null;
        }
        return currency;
      } on FormatException {
        return null;
      } on PegarouteCurrencyException {
        return null;
      }
    }
    final title = row['${prefix}Title'] as String?;
    if (title == null || title.isEmpty) return null;

    final tag = row['${prefix}Tag'] as String?;

    final live = CryptoCurrency.safeParseCurrencyFromString(title, tag: tag);
    if (live != null) {
      if (row['providerRaw'] == ExchangeProviderDescription.pegaroute.raw &&
          (live.title != title || live.tag != tag || live.decimals != row['${prefix}Decimals'])) {
        return null;
      }
      return live;
    }

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

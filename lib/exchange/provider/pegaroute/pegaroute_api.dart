import 'dart:convert';

import 'package:http/http.dart' as very_insecure_http_do_not_use;

import 'package:cw_core/utils/proxy_wrapper.dart';

import 'pegaroute_configuration.dart';

typedef PegarouteGet = Future<very_insecure_http_do_not_use.Response> Function(
    Uri uri, Map<String, String> headers);
typedef PegaroutePost = Future<very_insecure_http_do_not_use.Response> Function(
    Uri uri, Map<String, String> headers, String body);

class PegarouteCodecException implements Exception {
  const PegarouteCodecException(this.message);

  final String message;

  @override
  String toString() => 'Pegaroute codec error: $message';
}

class PegarouteUnavailableException implements Exception {
  const PegarouteUnavailableException();

  @override
  String toString() => 'Pegaroute execution is unavailable';
}

class PegarouteApiError implements Exception {
  const PegarouteApiError({
    required this.httpStatus,
    required this.code,
    required this.message,
    required this.userMessage,
    required this.retryable,
    this.retryAfterSeconds,
    this.provider,
    this.details,
  });

  factory PegarouteApiError.fromJson(int httpStatus, Object? value) {
    final root = _object(value);
    final error = _object(root['error']);
    return PegarouteApiError(
      httpStatus: httpStatus,
      code: _requiredString(error, 'code'),
      message: _requiredString(error, 'message'),
      userMessage: _requiredString(error, 'userMessage'),
      retryable: _requiredBool(error, 'retryable'),
      retryAfterSeconds: _optionalNum(error, 'retryAfterSeconds'),
      provider: _optionalString(error, 'provider'),
      details: error['details'] is Map ? Map<String, dynamic>.from(error['details'] as Map) : null,
    );
  }

  final int httpStatus;
  final String code;
  final String message;
  final String userMessage;
  final bool retryable;
  final num? retryAfterSeconds;
  final String? provider;
  final Map<String, dynamic>? details;

  bool get requiresReview => code == 'PROVIDER_CHANGED';

  @override
  String toString() => 'PegarouteApiError($httpStatus, $code)';
}

class PegaroutePrivateValue {
  const PegaroutePrivateValue(this.value);

  factory PegaroutePrivateValue.fromJson(Object? value) {
    if (value is bool) return PegaroutePrivateValue(value);
    if (value is String && value.trim().isNotEmpty) return PegaroutePrivateValue(value);
    throw const PegarouteCodecException('private must be a boolean or non-empty string');
  }

  final Object value;

  Object toJson() => value;
}

class PegarouteQuoteRequest {
  const PegarouteQuoteRequest({
    required this.fromChain,
    required this.fromToken,
    required this.toChain,
    required this.toToken,
    required this.amount,
    this.destinationAddress,
    this.senderAddress,
    this.refundAddress,
  });

  final String fromChain;
  final String fromToken;
  final String toChain;
  final String toToken;
  final String amount;
  final String? destinationAddress;
  final String? senderAddress;
  final String? refundAddress;

  factory PegarouteQuoteRequest.fromIntent({
    required String fromChain,
    required String fromToken,
    required String toChain,
    required String toToken,
    required String amount,
    required PegarouteAddressIntent intent,
  }) =>
      PegarouteQuoteRequest(
        fromChain: fromChain,
        fromToken: fromToken,
        toChain: toChain,
        toToken: toToken,
        amount: amount,
        destinationAddress: intent.destinationAddress,
        senderAddress: intent.senderAddress,
        refundAddress: intent.refundAddress,
      );

  Map<String, String> toQuery() {
    if (refundAddress != null && senderAddress == null) {
      throw const PegarouteCodecException('refundAddress requires senderAddress');
    }

    return _nonEmpty({
      'fromChain': fromChain,
      'fromToken': fromToken,
      'toChain': toChain,
      'toToken': toToken,
      'amount': amount,
      'destinationAddress': destinationAddress,
      'senderAddress': senderAddress,
      'refundAddress': refundAddress,
    });
  }
}

class PegarouteAddressIntent {
  PegarouteAddressIntent({
    required String destinationAddress,
    required String senderAddress,
    String? refundAddress,
  })  : destinationAddress = destinationAddress.trim(),
        senderAddress = senderAddress.trim(),
        refundAddress = _normalizeRefund(senderAddress.trim(), refundAddress) {
    if (this.destinationAddress.isEmpty || this.senderAddress.isEmpty) {
      throw const PegarouteCodecException('destination and sender are required');
    }
  }

  final String destinationAddress;
  final String senderAddress;
  final String? refundAddress;

  static String? _normalizeRefund(String sender, String? refund) {
    final normalized = refund?.trim();
    if (normalized == null || normalized.isEmpty || normalized == sender) return null;
    return normalized;
  }
}

class PegarouteSwapRequest extends PegarouteQuoteRequest {
  const PegarouteSwapRequest({
    required String fromChain,
    required String fromToken,
    required String toChain,
    required String toToken,
    required String amount,
    required String destinationAddress,
    required String senderAddress,
    String? refundAddress,
    this.quoteId,
    this.routeProvider,
  }) : super(
          fromChain: fromChain,
          fromToken: fromToken,
          toChain: toChain,
          toToken: toToken,
          amount: amount,
          destinationAddress: destinationAddress,
          senderAddress: senderAddress,
          refundAddress: refundAddress,
        );

  final String? quoteId;
  final String? routeProvider;

  factory PegarouteSwapRequest.fromIntent({
    required String fromChain,
    required String fromToken,
    required String toChain,
    required String toToken,
    required String amount,
    required PegarouteAddressIntent intent,
    String? quoteId,
    String? routeProvider,
  }) =>
      PegarouteSwapRequest(
        fromChain: fromChain,
        fromToken: fromToken,
        toChain: toChain,
        toToken: toToken,
        amount: amount,
        destinationAddress: intent.destinationAddress,
        senderAddress: intent.senderAddress,
        refundAddress: intent.refundAddress,
        quoteId: quoteId,
        routeProvider: routeProvider,
      );

  Map<String, dynamic> toJson() => {
        ...toQuery(),
        if (quoteId != null) 'quoteId': quoteId,
        if (routeProvider != null) 'routeProvider': routeProvider,
      };
}

class PegarouteTokenAmount {
  const PegarouteTokenAmount({required this.display, required this.baseUnits});

  factory PegarouteTokenAmount.fromJson(Object? value) {
    final map = _object(value);
    final display = _requiredString(map, 'display');
    final baseUnits = _requiredString(map, 'baseUnits');
    if (!RegExp(r'^[0-9]+$').hasMatch(baseUnits)) {
      throw const PegarouteCodecException('baseUnits must be an unsigned decimal string');
    }
    if (!_isDecimal(display)) throw const PegarouteCodecException('display must be decimal');
    return PegarouteTokenAmount(display: display, baseUnits: baseUnits);
  }

  final String display;
  final String baseUnits;

  Map<String, String> toJson() => {'display': display, 'baseUnits': baseUnits};
}

class PegarouteEvmApproval {
  const PegarouteEvmApproval(
      {required this.spender, required this.tokenAddress, required this.amount});

  factory PegarouteEvmApproval.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteEvmApproval(
      spender: _requiredString(map, 'spender'),
      tokenAddress: _requiredString(map, 'tokenAddress'),
      amount: PegarouteTokenAmount.fromJson(map['amount']),
    );
  }

  final String spender;
  final String tokenAddress;
  final PegarouteTokenAmount amount;

  Map<String, dynamic> toJson() => {
        'spender': spender,
        'tokenAddress': tokenAddress,
        'amount': amount.toJson(),
      };
}

class PegarouteExecution {
  PegarouteExecution({
    required this.family,
    required this.mode,
    this.chainId,
    this.chain,
    this.to,
    this.data,
    this.value,
    this.gasLimit,
    this.memo,
    this.approval,
    this.amount,
    this.transferAmount,
    this.asset,
    this.assetDecimals,
    this.serializedTransaction,
    this.minOut,
    this.gasRate,
  });

  factory PegarouteExecution.fromJson(Object? value) {
    final map = _object(value);
    final family = _requiredString(map, 'family');
    final mode = _requiredString(map, 'mode');
    final execution = PegarouteExecution(
      family: family,
      mode: mode,
      chainId: _optionalInt(map, 'chainId'),
      chain: _optionalString(map, 'chain'),
      to: _optionalString(map, 'to'),
      data: _optionalString(map, 'data'),
      value: map['value'] == null ? null : PegarouteTokenAmount.fromJson(map['value']),
      gasLimit: _optionalString(map, 'gasLimit'),
      memo: _optionalString(map, 'memo'),
      approval: map['approval'] == null ? null : PegarouteEvmApproval.fromJson(map['approval']),
      amount: map['amount'] == null ? null : PegarouteTokenAmount.fromJson(map['amount']),
      transferAmount: map['transferAmount'] == null
          ? null
          : PegarouteTokenAmount.fromJson(map['transferAmount']),
      asset: _optionalString(map, 'asset'),
      assetDecimals: _optionalInt(map, 'assetDecimals'),
      serializedTransaction: _optionalString(map, 'serializedTransaction'),
      minOut: map['minOut'] == null ? null : PegarouteTokenAmount.fromJson(map['minOut']),
      gasRate: _optionalString(map, 'gasRate'),
    );
    execution.validate();
    return execution;
  }

  final String family;
  final String mode;
  final int? chainId;
  final String? chain;
  final String? to;
  final String? data;
  final PegarouteTokenAmount? value;
  final String? gasLimit;
  final String? memo;
  final PegarouteEvmApproval? approval;
  final PegarouteTokenAmount? amount;
  final PegarouteTokenAmount? transferAmount;
  final String? asset;
  final int? assetDecimals;
  final String? serializedTransaction;
  final PegarouteTokenAmount? minOut;
  final String? gasRate;

  void validate() {
    const depositFamilies = {'solana', 'sui', 'xrp', 'tron', 'near', 'hypercore', 'cardano'};
    if (family == 'evm') {
      if (chainId == null || to == null || to!.isEmpty) _invalid('EVM destination');
      switch (mode) {
        case 'contract-call':
          if (data == null || data!.isEmpty || transferAmount != null) _invalid('EVM call data');
          break;
        case 'native-transfer':
          if (value == null || data != null || approval != null || transferAmount != null) {
            _invalid('EVM native transfer');
          }
          break;
        case 'erc20-transfer':
          if (transferAmount == null || value != null || approval != null) {
            _invalid('EVM token transfer');
          }
          break;
        default:
          _invalid('unknown EVM mode');
      }
      return;
    }
    if (family == 'utxo' && mode == 'payment-with-memo') {
      _requireTransfer();
      return;
    }
    if (family == 'cosmos' && (mode == 'bank-send' || mode == 'msg-deposit')) {
      _requireTransfer();
      if (mode == 'msg-deposit' && (asset == null || assetDecimals == null)) {
        _invalid('Cosmos deposit asset');
      }
      return;
    }
    if ((depositFamilies.contains(family) || family == 'other') && mode == 'deposit-transfer') {
      _requireTransfer();
      if (family == 'other' && (chain == null || chain!.isEmpty)) _invalid('deposit chain');
      return;
    }
    if ((family == 'solana' || family == 'sui') && mode == 'serialized-tx') {
      if (serializedTransaction == null || serializedTransaction!.isEmpty) {
        _invalid('serialized transaction');
      }
      return;
    }
    _invalid('unsupported execution family/mode');
  }

  void _requireTransfer() {
    if (to == null || to!.isEmpty || amount == null) _invalid('transfer destination/amount');
  }

  Map<String, dynamic> toJson() => {
        'family': family,
        'mode': mode,
        if (chainId != null) 'chainId': chainId,
        if (chain != null) 'chain': chain,
        if (to != null) 'to': to,
        if (data != null) 'data': data,
        if (value != null) 'value': value!.toJson(),
        if (gasLimit != null) 'gasLimit': gasLimit,
        if (memo != null) 'memo': memo,
        if (approval != null) 'approval': approval!.toJson(),
        if (amount != null) 'amount': amount!.toJson(),
        if (transferAmount != null) 'transferAmount': transferAmount!.toJson(),
        if (asset != null) 'asset': asset,
        if (assetDecimals != null) 'assetDecimals': assetDecimals,
        if (serializedTransaction != null) 'serializedTransaction': serializedTransaction,
        if (minOut != null) 'minOut': minOut!.toJson(),
        if (gasRate != null) 'gasRate': gasRate,
      };
}

class PegarouteRoute {
  const PegarouteRoute({
    required this.provider,
    required this.expectedOutput,
    this.providerType,
    this.subprovider,
    this.privateValue,
    this.memo,
    this.inboundAddress,
    this.router,
    this.minAmount,
    this.estimatedTimeSeconds,
    this.fees,
  });

  factory PegarouteRoute.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteRoute(
      provider: _requiredString(map, 'provider'),
      expectedOutput: _requiredString(map, 'expectedOutput'),
      providerType: _optionalString(map, 'providerType'),
      subprovider: _optionalString(map, 'subprovider'),
      privateValue: map['private'] == null ? null : PegaroutePrivateValue.fromJson(map['private']),
      memo: _optionalString(map, 'memo'),
      inboundAddress: _optionalString(map, 'inboundAddress'),
      router: _optionalString(map, 'router'),
      minAmount: _optionalString(map, 'minAmount'),
      estimatedTimeSeconds: _optionalNum(map, 'estimatedTimeSeconds'),
      fees: map['fees'] == null ? null : PegarouteFees.fromJson(map['fees']),
    );
  }

  final String provider;
  final String expectedOutput;
  final String? providerType;
  final String? subprovider;
  final PegaroutePrivateValue? privateValue;
  final String? memo;
  final String? inboundAddress;
  final String? router;
  final String? minAmount;
  final num? estimatedTimeSeconds;
  final PegarouteFees? fees;
}

class PegarouteFees {
  const PegarouteFees(
      {this.affiliate, this.liquidity, this.outbound, this.subAffiliate, this.total});

  factory PegarouteFees.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteFees(
      affiliate: _optionalString(map, 'affiliate'),
      liquidity: _optionalString(map, 'liquidity'),
      outbound: _optionalString(map, 'outbound'),
      subAffiliate: _optionalString(map, 'subAffiliate'),
      total: _optionalString(map, 'total'),
    );
  }

  final String? affiliate;
  final String? liquidity;
  final String? outbound;
  final String? subAffiliate;
  final String? total;
}

class PegarouteWarning {
  const PegarouteWarning(
      {required this.provider,
      required this.code,
      required this.message,
      required this.userMessage});

  factory PegarouteWarning.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteWarning(
      provider: _requiredString(map, 'provider'),
      code: _requiredString(map, 'code'),
      message: _requiredString(map, 'message'),
      userMessage: _requiredString(map, 'userMessage'),
    );
  }

  final String provider;
  final String code;
  final String message;
  final String userMessage;
}

class PegarouteQuoteResponse {
  const PegarouteQuoteResponse(
      {required this.quoteId,
      required this.expiresAt,
      required this.routes,
      required this.warnings});

  factory PegarouteQuoteResponse.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteQuoteResponse(
      quoteId: _requiredString(map, 'quoteId'),
      expiresAt: _requiredString(map, 'expiresAt'),
      routes: _list(map, 'routes').map(PegarouteRoute.fromJson).toList(),
      warnings: _list(map, 'warnings').map(PegarouteWarning.fromJson).toList(),
    );
  }

  final String quoteId;
  final String expiresAt;
  final List<PegarouteRoute> routes;
  final List<PegarouteWarning> warnings;
}

class PegarouteProviderInfo {
  const PegarouteProviderInfo({required this.name, this.referenceId, this.details});

  factory PegarouteProviderInfo.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteProviderInfo(
      name: _requiredString(map, 'name'),
      referenceId: _optionalString(map, 'referenceId'),
      details: map['details'] is Map ? Map<String, dynamic>.from(map['details'] as Map) : null,
    );
  }

  final String name;
  final String? referenceId;
  final Map<String, dynamic>? details;

  PegarouteInstaswapSnapshot? get instaswapSwapLite {
    final value = details?['instaswapSwapLite'];
    return value == null ? null : PegarouteInstaswapSnapshot.fromJson(value);
  }
}

class PegarouteInstaswapSnapshot {
  const PegarouteInstaswapSnapshot({
    required this.txid,
    required this.depositAddress,
    this.estimatedOut,
    this.estimatedOutUsd,
    this.depositAmount,
    this.depositAmountExact,
    this.depositAmountUsd,
    this.feeBreakdown,
    this.etaSeconds,
    this.depositTokenSymbol,
    this.expiresAt,
    this.instructions,
  });

  factory PegarouteInstaswapSnapshot.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteInstaswapSnapshot(
      txid: _requiredString(map, 'txid'),
      depositAddress: _requiredString(map, 'depositAddress'),
      estimatedOut: _optionalNum(map, 'estimatedOut'),
      estimatedOutUsd: _optionalNum(map, 'estimatedOutUsd'),
      depositAmount: _optionalNum(map, 'depositAmount'),
      depositAmountExact: _optionalString(map, 'depositAmountExact'),
      depositAmountUsd: _optionalNum(map, 'depositAmountUsd'),
      feeBreakdown: map['feeBreakdown'] == null
          ? null
          : _list(map, 'feeBreakdown').map(PegarouteInstaswapFeeLine.fromJson).toList(),
      etaSeconds: _optionalNum(map, 'etaSeconds'),
      depositTokenSymbol: _optionalString(map, 'depositTokenSymbol'),
      expiresAt: _optionalString(map, 'expiresAt'),
      instructions: _optionalString(map, 'instructions'),
    );
  }

  final String txid;
  final String depositAddress;
  final num? estimatedOut;
  final num? estimatedOutUsd;
  final num? depositAmount;
  final String? depositAmountExact;
  final num? depositAmountUsd;
  final List<PegarouteInstaswapFeeLine>? feeBreakdown;
  final num? etaSeconds;
  final String? depositTokenSymbol;
  final String? expiresAt;
  final String? instructions;
}

class PegarouteInstaswapFeeLine {
  const PegarouteInstaswapFeeLine({this.type, this.name, this.amountUsd, this.asset, this.amount});

  factory PegarouteInstaswapFeeLine.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteInstaswapFeeLine(
      type: _optionalString(map, 'type'),
      name: _optionalString(map, 'name'),
      amountUsd: _optionalNum(map, 'amountUsd'),
      asset: _optionalString(map, 'asset'),
      amount: _optionalNum(map, 'amount'),
    );
  }

  final String? type;
  final String? name;
  final num? amountUsd;
  final String? asset;
  final num? amount;
}

class PegarouteRefund {
  const PegarouteRefund(
      {required this.status,
      required this.chain,
      required this.amount,
      required this.originalAmount,
      required this.feeDeducted,
      required this.feeDescription,
      required this.refundAddress,
      this.txHash,
      this.completedAt});

  factory PegarouteRefund.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteRefund(
      status: _requiredString(map, 'status'),
      chain: _requiredString(map, 'chain'),
      amount: _requiredString(map, 'amount'),
      originalAmount: _requiredString(map, 'originalAmount'),
      feeDeducted: _requiredString(map, 'feeDeducted'),
      feeDescription: _requiredString(map, 'feeDescription'),
      refundAddress: _requiredString(map, 'refundAddress'),
      txHash: _optionalString(map, 'txHash'),
      completedAt: _optionalString(map, 'completedAt'),
    );
  }

  final String status;
  final String chain;
  final String amount;
  final String originalAmount;
  final String feeDeducted;
  final String feeDescription;
  final String refundAddress;
  final String? txHash;
  final String? completedAt;
}

class PegarouteStreamingProgress {
  const PegarouteStreamingProgress(
      {required this.completedSubSwaps,
      required this.totalSubSwaps,
      this.lastSubSwapTimestamp,
      this.partialOutput,
      this.partialRefund});

  factory PegarouteStreamingProgress.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteStreamingProgress(
      completedSubSwaps: _requiredNum(map, 'completedSubSwaps'),
      totalSubSwaps: _requiredNum(map, 'totalSubSwaps'),
      lastSubSwapTimestamp: _optionalString(map, 'lastSubSwapTimestamp'),
      partialOutput: _optionalString(map, 'partialOutput'),
      partialRefund: map['partialRefund'] == null ? null : _object(map['partialRefund']),
    );
  }

  final num completedSubSwaps;
  final num totalSubSwaps;
  final String? lastSubSwapTimestamp;
  final String? partialOutput;
  final Map<String, dynamic>? partialRefund;
}

class PegarouteStatusResponse {
  const PegarouteStatusResponse(
      {required this.transactionId,
      required this.status,
      required this.internalStatus,
      required this.input,
      required this.output,
      this.route,
      this.error,
      this.refund,
      this.streamingProgress,
      this.execution,
      this.provider});

  factory PegarouteStatusResponse.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteStatusResponse(
      transactionId: _requiredString(map, 'transactionId'),
      status: _requiredString(map, 'status'),
      internalStatus: _requiredString(map, 'internalStatus'),
      input: PegarouteStatusInput.fromJson(map['input']),
      output: PegarouteStatusOutput.fromJson(map['output']),
      route: map['route'] == null ? null : PegarouteRoute.fromJson(map['route']),
      error: map['error'] == null ? null : PegarouteApiTransactionError.fromJson(map['error']),
      refund: map['refund'] == null ? null : PegarouteRefund.fromJson(map['refund']),
      streamingProgress: map['streamingProgress'] == null
          ? null
          : PegarouteStreamingProgress.fromJson(map['streamingProgress']),
      execution: map['execution'] == null ? null : PegarouteExecution.fromJson(map['execution']),
      provider: map['provider'] == null ? null : PegarouteProviderInfo.fromJson(map['provider']),
    );
  }

  final String transactionId;
  final String status;
  final String internalStatus;
  final PegarouteStatusInput input;
  final PegarouteStatusOutput output;
  final PegarouteRoute? route;
  final PegarouteApiTransactionError? error;
  final PegarouteRefund? refund;
  final PegarouteStreamingProgress? streamingProgress;
  final PegarouteExecution? execution;
  final PegarouteProviderInfo? provider;
}

class PegarouteStatusInput {
  const PegarouteStatusInput(
      {required this.chain,
      required this.token,
      required this.amount,
      this.address,
      this.refundAddress,
      this.txHash,
      this.providerReferenceId,
      this.instaswapSwapLite});

  factory PegarouteStatusInput.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteStatusInput(
      chain: _requiredString(map, 'chain'),
      token: _requiredString(map, 'token'),
      amount: _requiredString(map, 'amount'),
      address: _optionalString(map, 'address'),
      refundAddress: _optionalString(map, 'refundAddress'),
      txHash: _optionalString(map, 'txHash'),
      providerReferenceId: _optionalString(map, 'providerReferenceId'),
      instaswapSwapLite: map['instaswapSwapLite'] == null
          ? null
          : PegarouteInstaswapSnapshot.fromJson(map['instaswapSwapLite']),
    );
  }

  final String chain;
  final String token;
  final String amount;
  final String? address;
  final String? refundAddress;
  final String? txHash;
  final String? providerReferenceId;
  final PegarouteInstaswapSnapshot? instaswapSwapLite;
}

class PegarouteStatusOutput {
  const PegarouteStatusOutput(
      {required this.chain, required this.token, required this.address, this.amount, this.txHash});

  factory PegarouteStatusOutput.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteStatusOutput(
      chain: _requiredString(map, 'chain'),
      token: _requiredString(map, 'token'),
      address: _requiredString(map, 'address'),
      amount: _optionalString(map, 'amount'),
      txHash: _optionalString(map, 'txHash'),
    );
  }

  final String chain;
  final String token;
  final String address;
  final String? amount;
  final String? txHash;
}

class PegarouteCatalogResponse {
  const PegarouteCatalogResponse(this.chains);

  factory PegarouteCatalogResponse.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteCatalogResponse(
      _list(map, 'chains').map(PegarouteCatalogChain.fromJson).toList(),
    );
  }

  final List<PegarouteCatalogChain> chains;
}

class PegarouteCatalogChain {
  const PegarouteCatalogChain({required this.id, required this.name, this.chainId});

  factory PegarouteCatalogChain.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteCatalogChain(
      id: _requiredString(map, 'id'),
      name: _requiredString(map, 'name'),
      chainId: _optionalInt(map, 'chainId'),
    );
  }

  final String id;
  final String name;
  final int? chainId;
}

class PegarouteTokenCatalogResponse {
  const PegarouteTokenCatalogResponse({required this.chain, required this.tokens});

  factory PegarouteTokenCatalogResponse.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteTokenCatalogResponse(
      chain: _requiredString(map, 'chain'),
      tokens: _list(map, 'tokens').map(PegarouteCatalogToken.fromJson).toList(),
    );
  }

  final String chain;
  final List<PegarouteCatalogToken> tokens;
}

class PegarouteCatalogToken {
  const PegarouteCatalogToken({required this.id, required this.symbol});

  factory PegarouteCatalogToken.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteCatalogToken(
      id: _requiredString(map, 'id'),
      symbol: _requiredString(map, 'symbol'),
    );
  }

  final String id;
  final String symbol;
}

class PegarouteApiTransactionError {
  const PegarouteApiTransactionError(
      {required this.code, required this.message, required this.userMessage, this.provider});

  factory PegarouteApiTransactionError.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteApiTransactionError(
      code: _requiredString(map, 'code'),
      message: _requiredString(map, 'message'),
      userMessage: _requiredString(map, 'userMessage'),
      provider: _optionalString(map, 'provider'),
    );
  }

  final String code;
  final String message;
  final String userMessage;
  final String? provider;
}

class PegarouteApiClient {
  PegarouteApiClient(
      {PegarouteConfiguration? configuration, PegarouteGet? get, PegaroutePost? post})
      : configuration = configuration ?? PegarouteConfiguration.generated(),
        _get = get ?? ((uri, headers) => ProxyWrapper().get(clearnetUri: uri, headers: headers)),
        _post = post ??
            ((uri, headers, body) =>
                ProxyWrapper().post(clearnetUri: uri, headers: headers, body: body));

  final PegarouteConfiguration configuration;
  final PegarouteGet _get;
  final PegaroutePost _post;

  Map<String, String> get _headers => {'X-API-Key': configuration.apiKey};

  Uri _uri(String path, [Map<String, String>? query]) {
    final origin = configuration.origin;
    if (origin == null) throw const PegarouteUnavailableException();
    return origin.replace(path: path, queryParameters: query);
  }

  Future<PegarouteQuoteResponse> quote(PegarouteQuoteRequest request) async {
    final response = await _get(_uri('/quote', request.toQuery()), _headers);
    return _decode(response, PegarouteQuoteResponse.fromJson);
  }

  Future<PegarouteCatalogResponse> chains() async {
    final response = await _get(_uri('/chains'), _headers);
    return _decode(response, PegarouteCatalogResponse.fromJson);
  }

  Future<PegarouteTokenCatalogResponse> tokens(String chain) async {
    final response = await _get(_uri('/tokens', {'chain': chain}), _headers);
    return _decode(response, PegarouteTokenCatalogResponse.fromJson);
  }

  Future<PegarouteStatusResponse> status(String id) async {
    final response = await _get(_uri('/swap/$id'), _headers);
    return _decode(response, PegarouteStatusResponse.fromJson);
  }

  Future<PegarouteSwapResponse> swap(PegarouteSwapRequest request) async {
    final response = await _post(
      _uri('/swap'),
      {..._headers, 'Content-Type': 'application/json'},
      json.encode(request.toJson()),
    );
    if (response.statusCode != 202 && response.statusCode >= 200 && response.statusCode < 300) {
      throw const PegarouteCodecException('swap response must use HTTP 202');
    }
    return _decode(response, PegarouteSwapResponse.fromJson);
  }

  T _decode<T>(very_insecure_http_do_not_use.Response response, T Function(Object?) decoder) {
    Object? value;
    try {
      value = _json(response.body);
    } on PegarouteCodecException {
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw PegarouteApiError(
          httpStatus: response.statusCode,
          code: 'INVALID_RESPONSE',
          message: 'The provider returned an invalid response',
          userMessage: 'The provider returned an invalid response',
          retryable: false,
        );
      }
      rethrow;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PegarouteApiError.fromJson(response.statusCode, value);
    }
    return decoder(value);
  }

  static Object? _json(String body) {
    try {
      return json.decode(body);
    } catch (_) {
      throw const PegarouteCodecException('response is not valid JSON');
    }
  }
}

class PegarouteSwapResponse {
  const PegarouteSwapResponse(
      {required this.transactionId,
      required this.status,
      required this.route,
      required this.execution,
      required this.provider});

  factory PegarouteSwapResponse.fromJson(Object? value) {
    final map = _object(value);
    final status = _requiredString(map, 'status');
    if (status != 'pending') throw const PegarouteCodecException('swap status must be pending');
    return PegarouteSwapResponse(
      transactionId: _requiredString(map, 'transactionId'),
      status: status,
      route: PegarouteRoute.fromJson(map['route']),
      execution: PegarouteExecution.fromJson(map['execution']),
      provider: PegarouteProviderInfo.fromJson(map['provider']),
    );
  }

  final String transactionId;
  final String status;
  final PegarouteRoute route;
  final PegarouteExecution execution;
  final PegarouteProviderInfo provider;
}

Map<String, String> _nonEmpty(Map<String, String?> values) => Map.fromEntries(
      values.entries.where((entry) => entry.value != null && entry.value!.isNotEmpty).map(
            (entry) => MapEntry(entry.key, entry.value!),
          ),
    );

Map<String, dynamic> _object(Object? value) {
  if (value is! Map) throw const PegarouteCodecException('expected JSON object');
  return Map<String, dynamic>.from(value);
}

List<dynamic> _list(Map<String, dynamic> map, String key) {
  if (map[key] is! List) throw PegarouteCodecException('$key must be an array');
  return map[key] as List<dynamic>;
}

String _requiredString(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! String || value.isEmpty)
    throw PegarouteCodecException('$key must be a non-empty string');
  return value;
}

String? _optionalString(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String) throw PegarouteCodecException('$key must be a string or null');
  return value;
}

bool _requiredBool(Map<String, dynamic> map, String key) {
  if (map[key] is! bool) throw PegarouteCodecException('$key must be boolean');
  return map[key] as bool;
}

num? _optionalNum(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! num) throw PegarouteCodecException('$key must be numeric or null');
  return value;
}

num _requiredNum(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! num) throw PegarouteCodecException('$key must be numeric');
  return value;
}

int? _optionalInt(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! int) throw PegarouteCodecException('$key must be an integer or null');
  return value;
}

bool _isDecimal(String value) => RegExp(r'^(0|[1-9][0-9]*)(\.[0-9]+)?$').hasMatch(value);

Never _invalid(String field) => throw PegarouteCodecException('invalid $field');

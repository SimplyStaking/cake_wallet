import 'dart:convert';

import 'package:http/http.dart' as very_insecure_http_do_not_use;

import 'package:cw_core/utils/proxy_wrapper.dart';

import 'pegaroute_configuration.dart';
import 'pegaroute_execution_binding.dart';

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
    this.newQuote,
    this.originalProvider,
    this.newProvider,
  });

  factory PegarouteApiError.fromJson(int httpStatus, Object? value) {
    final root = _object(value);
    final error = _object(root['error']);
    final detailsValue = error['details'];
    if (error.containsKey('details') && (detailsValue == null || detailsValue is! Map)) {
      throw const PegarouteCodecException('details must be an object');
    }
    final code = _requiredString(error, 'code');
    final newQuote = root['newQuote'];
    final originalProvider = root['originalProvider'];
    final replacementProvider = root['newProvider'];
    if (code == 'PROVIDER_CHANGED' &&
        (newQuote == null ||
            originalProvider is! String ||
            originalProvider.isEmpty ||
            replacementProvider is! String ||
            replacementProvider.isEmpty)) {
      throw const PegarouteCodecException('PROVIDER_CHANGED terms are incomplete');
    }
    return PegarouteApiError(
      httpStatus: httpStatus,
      code: code,
      message: _requiredString(error, 'message'),
      userMessage: _requiredString(error, 'userMessage'),
      retryable: _requiredBool(error, 'retryable'),
      retryAfterSeconds: _optionalNullableNum(error, 'retryAfterSeconds'),
      provider: _optionalString(error, 'provider'),
      details: detailsValue == null ? null : Map<String, dynamic>.from(detailsValue as Map),
      newQuote: code == 'PROVIDER_CHANGED' ? PegarouteQuoteResponse.fromJson(newQuote) : null,
      originalProvider: code == 'PROVIDER_CHANGED' ? originalProvider as String : null,
      newProvider: code == 'PROVIDER_CHANGED' ? replacementProvider as String : null,
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
  final PegarouteQuoteResponse? newQuote;
  final String? originalProvider;
  final String? newProvider;

  bool get requiresReview => code == 'PROVIDER_CHANGED';

  @override
  String toString() => 'PegarouteApiError($httpStatus, $code)';
}

class PegaroutePrivateValue {
  const PegaroutePrivateValue(this.value);

  factory PegaroutePrivateValue.fromJson(Object? value) {
    if (value is bool) return PegaroutePrivateValue(value);
    if (value is String && value.trim().isNotEmpty && value.length <= 64) {
      return PegaroutePrivateValue(value);
    }
    throw const PegarouteCodecException('private must be a boolean or non-empty string');
  }

  final Object value;

  Object toJson() => value;
}

class PegarouteQuoteRequest {
  factory PegarouteQuoteRequest({
    required String fromChain,
    required String fromToken,
    required String toChain,
    required String toToken,
    required String amount,
    String? destinationAddress,
    String? senderAddress,
    String? refundAddress,
    String? integrationId,
  }) =>
      PegarouteQuoteRequest._(
        fromChain: fromChain,
        fromToken: fromToken,
        toChain: toChain,
        toToken: toToken,
        amount: amount,
        destinationAddress: destinationAddress,
        senderAddress: senderAddress,
        refundAddress: refundAddress,
        integrationId: integrationId,
      );

  PegarouteQuoteRequest._({
    required String fromChain,
    required String fromToken,
    required String toChain,
    required String toToken,
    required String amount,
    String? destinationAddress,
    String? senderAddress,
    String? refundAddress,
    String? integrationId,
  })  : fromChain = _requiredRequestId(fromChain, 'fromChain'),
        fromToken = _requiredRequestId(fromToken, 'fromToken'),
        toChain = _requiredRequestId(toChain, 'toChain'),
        toToken = _requiredRequestId(toToken, 'toToken'),
        amount = _positiveAmount(amount),
        destinationAddress = _optionalRequestId(destinationAddress, 'destinationAddress'),
        senderAddress = _normalizeRequestSender(senderAddress),
        refundAddress = _normalizeRequestRefund(
          _normalizeRequestSender(senderAddress),
          refundAddress,
        ),
        integrationId = _optionalRequestId(integrationId, 'integrationId');

  final String fromChain;
  final String fromToken;
  final String toChain;
  final String toToken;
  final String amount;
  final String? destinationAddress;
  final String? senderAddress;
  final String? refundAddress;
  final String? integrationId;

  factory PegarouteQuoteRequest.fromIntent({
    required String fromChain,
    required String fromToken,
    required String toChain,
    required String toToken,
    required String amount,
    required PegarouteAddressIntent intent,
    String? integrationId,
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
        integrationId: integrationId,
      );

  Map<String, String> toQuery() {
    if (refundAddress != null && senderAddress == null) {
      throw const PegarouteCodecException('refundAddress requires senderAddress');
    }

    final result = _nonEmpty({
      'fromChain': fromChain,
      'fromToken': fromToken,
      'toChain': toChain,
      'toToken': toToken,
      'amount': amount,
      'destinationAddress': destinationAddress,
      'senderAddress': senderAddress,
      'refundAddress': refundAddress,
      'integrationId': integrationId,
    });
    for (final key in const ['fromChain', 'fromToken', 'toChain', 'toToken', 'amount']) {
      if (!result.containsKey(key)) throw PegarouteCodecException('$key is required');
    }
    return result;
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
  factory PegarouteSwapRequest({
    required String fromChain,
    required String fromToken,
    required String toChain,
    required String toToken,
    required String amount,
    required String destinationAddress,
    required String senderAddress,
    String? refundAddress,
    String? quoteId,
    String? routeProvider,
    String? integrationId,
    double? slippageTolerance,
    bool? streaming,
  }) =>
      PegarouteSwapRequest._(
        fromChain: fromChain,
        fromToken: fromToken,
        toChain: toChain,
        toToken: toToken,
        amount: amount,
        destinationAddress: destinationAddress,
        senderAddress: senderAddress,
        refundAddress: refundAddress,
        quoteId: quoteId,
        routeProvider: routeProvider,
        integrationId: integrationId,
        slippageTolerance: slippageTolerance,
        streaming: streaming,
      );

  PegarouteSwapRequest._({
    required String fromChain,
    required String fromToken,
    required String toChain,
    required String toToken,
    required String amount,
    required String destinationAddress,
    required String senderAddress,
    String? refundAddress,
    String? quoteId,
    String? routeProvider,
    String? integrationId,
    double? slippageTolerance,
    bool? streaming,
  })  : quoteId = _optionalRequestId(quoteId, 'quoteId'),
        routeProvider = _optionalRequestId(routeProvider, 'routeProvider'),
        slippageTolerance = slippageTolerance,
        streaming = streaming,
        super._(
          fromChain: fromChain,
          fromToken: fromToken,
          toChain: toChain,
          toToken: toToken,
          amount: amount,
          destinationAddress: destinationAddress,
          senderAddress: senderAddress,
          refundAddress: refundAddress,
          integrationId: integrationId,
        ) {
    if (destinationAddress.trim().isEmpty || senderAddress.trim().isEmpty) {
      throw const PegarouteCodecException('destination and sender are required for swap');
    }
    final slippage = slippageTolerance;
    if (slippage != null && (!slippage.isFinite || slippage < 0 || slippage > 1)) {
      throw const PegarouteCodecException('slippageTolerance must be between 0 and 1');
    }
  }

  final String? quoteId;
  final String? routeProvider;
  final double? slippageTolerance;
  final bool? streaming;

  factory PegarouteSwapRequest.fromIntent({
    required String fromChain,
    required String fromToken,
    required String toChain,
    required String toToken,
    required String amount,
    required PegarouteAddressIntent intent,
    String? quoteId,
    String? routeProvider,
    String? integrationId,
    double? slippageTolerance,
    bool? streaming,
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
        integrationId: integrationId,
        slippageTolerance: slippageTolerance,
        streaming: streaming,
      );

  Map<String, dynamic> toJson() => {
        ..._validatedSwapFields(),
        if (quoteId != null) 'quoteId': quoteId,
        if (routeProvider != null) 'routeProvider': routeProvider,
        if (slippageTolerance != null) ..._validatedSlippage(),
        if (streaming != null) 'streaming': streaming,
      };

  Map<String, dynamic> _validatedSwapFields() {
    final query = toQuery();
    for (final key in const ['destinationAddress', 'senderAddress']) {
      if (!query.containsKey(key)) throw PegarouteCodecException('$key is required for swap');
    }
    final result = <String, dynamic>{...query};
    return result;
  }

  Map<String, dynamic> _validatedSlippage() {
    final value = slippageTolerance!;
    return {'slippageTolerance': value};
  }
}

class PegarouteTokenAmount {
  factory PegarouteTokenAmount({required String display, required String baseUnits}) {
    final amount = PegarouteTokenAmount._(display: display, baseUnits: baseUnits);
    amount.validate();
    return amount;
  }

  const PegarouteTokenAmount._({required this.display, required this.baseUnits});

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

  void validate() {
    if (!RegExp(r'^[0-9]+$').hasMatch(baseUnits) || !_isDecimal(display)) {
      throw const PegarouteCodecException('invalid token amount');
    }
  }

  Map<String, String> toJson() {
    validate();
    return {'display': display, 'baseUnits': baseUnits};
  }
}

class PegarouteEvmApproval {
  factory PegarouteEvmApproval(
      {required String spender,
      required String tokenAddress,
      required PegarouteTokenAmount amount}) {
    if (spender.isEmpty || tokenAddress.isEmpty) {
      throw const PegarouteCodecException('approval addresses are required');
    }
    return PegarouteEvmApproval._(spender: spender, tokenAddress: tokenAddress, amount: amount);
  }

  const PegarouteEvmApproval._(
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
  factory PegarouteExecution({
    required String family,
    required String mode,
    int? chainId,
    String? chain,
    String? to,
    String? data,
    PegarouteTokenAmount? value,
    String? gasLimit,
    String? memo,
    PegarouteEvmApproval? approval,
    PegarouteTokenAmount? amount,
    PegarouteTokenAmount? transferAmount,
    String? asset,
    int? assetDecimals,
    String? serializedTransaction,
    PegarouteTokenAmount? minOut,
    String? gasRate,
  }) {
    final execution = PegarouteExecution._(
      family: family,
      mode: mode,
      chainId: chainId,
      chain: chain,
      to: to,
      data: data,
      value: value,
      gasLimit: gasLimit,
      memo: memo,
      approval: approval,
      amount: amount,
      transferAmount: transferAmount,
      asset: asset,
      assetDecimals: assetDecimals,
      serializedTransaction: serializedTransaction,
      minOut: minOut,
      gasRate: gasRate,
    );
    execution.validate();
    return execution;
  }

  PegarouteExecution._({
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
    _rejectUnknown(map, _executionKeys(family, mode));
    late final PegarouteExecution execution;
    if (family == 'evm') {
      execution = PegarouteExecution(
        family: family,
        mode: mode,
        chainId: _requiredInt(map, 'chainId'),
        to: _requiredString(map, 'to'),
        data: _requiredNullableString(map, 'data'),
        value: _requiredNullableTokenAmount(map, 'value'),
        gasLimit: _requiredNullableString(map, 'gasLimit'),
        memo: _requiredNullableString(map, 'memo'),
        approval: _requiredNullableApproval(map, 'approval'),
        transferAmount: _requiredNullableTokenAmount(map, 'transferAmount'),
      );
    } else if (family == 'utxo') {
      execution = PegarouteExecution(
        family: family,
        mode: mode,
        to: _requiredString(map, 'to'),
        amount: PegarouteTokenAmount.fromJson(map['amount']),
        memo: _requiredNullableString(map, 'memo'),
        gasRate: _requiredNullableString(map, 'gasRate'),
      );
    } else if (family == 'cosmos') {
      execution = PegarouteExecution(
        family: family,
        mode: mode,
        to: _requiredString(map, 'to'),
        amount: PegarouteTokenAmount.fromJson(map['amount']),
        memo: _requiredNullableString(map, 'memo'),
        asset: mode == 'msg-deposit' ? _requiredString(map, 'asset') : null,
        assetDecimals: mode == 'msg-deposit' ? _requiredNonnegativeInt(map, 'assetDecimals') : null,
      );
    } else if (family == 'solana' || family == 'sui') {
      if (mode == 'serialized-tx') {
        execution = PegarouteExecution(
          family: family,
          mode: mode,
          serializedTransaction: _requiredString(map, 'serializedTransaction'),
          minOut: _requiredNullableTokenAmount(map, 'minOut'),
        );
      } else {
        execution = PegarouteExecution(
          family: family,
          mode: mode,
          to: _requiredString(map, 'to'),
          amount: PegarouteTokenAmount.fromJson(map['amount']),
          memo: _requiredNullableString(map, 'memo'),
        );
      }
    } else if (const {'xrp', 'tron', 'near', 'hypercore', 'cardano'}.contains(family)) {
      execution = PegarouteExecution(
        family: family,
        mode: mode,
        to: _requiredString(map, 'to'),
        amount: PegarouteTokenAmount.fromJson(map['amount']),
        memo: _requiredNullableString(map, 'memo'),
      );
    } else if (family == 'other') {
      execution = PegarouteExecution(
        family: family,
        mode: mode,
        chain: _requiredString(map, 'chain'),
        to: _requiredString(map, 'to'),
        amount: PegarouteTokenAmount.fromJson(map['amount']),
        memo: _requiredNullableString(map, 'memo'),
      );
    } else {
      throw const PegarouteCodecException('unsupported execution family');
    }
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
    if (family == 'evm') {
      if (chain != null ||
          amount != null ||
          asset != null ||
          assetDecimals != null ||
          serializedTransaction != null ||
          minOut != null ||
          gasRate != null) {
        _invalid('EVM execution fields');
      }
      if (chainId == null || to == null || to!.isEmpty) _invalid('EVM destination');
      switch (mode) {
        case 'contract-call':
          if (!_validCalldata(data) || transferAmount != null) {
            _invalid('EVM call data');
          }
          break;
        case 'native-transfer':
          if (value == null || data != null || approval != null || transferAmount != null) {
            _invalid('EVM native transfer');
          }
          break;
        case 'erc20-transfer':
          if (transferAmount == null || value != null || approval != null || data != null) {
            _invalid('EVM token transfer');
          }
          break;
        default:
          _invalid('unknown EVM mode');
      }
      return;
    }
    if (family == 'utxo' && mode == 'payment-with-memo') {
      if (chainId != null ||
          chain != null ||
          data != null ||
          value != null ||
          gasLimit != null ||
          approval != null ||
          transferAmount != null ||
          asset != null ||
          assetDecimals != null ||
          serializedTransaction != null ||
          minOut != null) _invalid('UTXO execution fields');
      _requireTransfer();
      return;
    }
    if (family == 'cosmos' && (mode == 'bank-send' || mode == 'msg-deposit')) {
      if (chainId != null ||
          chain != null ||
          data != null ||
          value != null ||
          gasLimit != null ||
          approval != null ||
          transferAmount != null ||
          serializedTransaction != null ||
          minOut != null ||
          gasRate != null) _invalid('Cosmos execution fields');
      _requireTransfer();
      if (mode == 'msg-deposit' &&
          (asset == null || asset!.isEmpty || assetDecimals == null || assetDecimals! < 0)) {
        _invalid('Cosmos deposit asset');
      }
      return;
    }
    if ((const {'solana', 'sui', 'xrp', 'tron', 'near', 'hypercore', 'cardano'}.contains(family) ||
            family == 'other') &&
        mode == 'deposit-transfer') {
      if (chainId != null ||
          data != null ||
          value != null ||
          gasLimit != null ||
          approval != null ||
          transferAmount != null ||
          asset != null ||
          assetDecimals != null ||
          serializedTransaction != null ||
          minOut != null ||
          gasRate != null ||
          (family != 'other' && chain != null)) _invalid('deposit execution fields');
      _requireTransfer();
      if (family == 'other' && (chain == null || chain!.isEmpty)) _invalid('deposit chain');
      return;
    }
    if ((family == 'solana' || family == 'sui') && mode == 'serialized-tx') {
      if (chainId != null ||
          chain != null ||
          to != null ||
          data != null ||
          value != null ||
          gasLimit != null ||
          memo != null ||
          approval != null ||
          amount != null ||
          transferAmount != null ||
          asset != null ||
          assetDecimals != null ||
          gasRate != null) {
        _invalid('serialized execution fields');
      }
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

  Map<String, dynamic> toJson() {
    validate();
    return {
      'family': family,
      'mode': mode,
      if (family == 'evm') ...{
        'chainId': chainId,
        'to': to,
        'data': data,
        'value': value?.toJson(),
        'gasLimit': gasLimit,
        'memo': memo,
        'approval': approval?.toJson(),
        'transferAmount': transferAmount?.toJson(),
      },
      if (family == 'utxo') ...{
        'to': to,
        'amount': amount?.toJson(),
        'memo': memo,
        'gasRate': gasRate,
      },
      if (family == 'cosmos') ...{
        'to': to,
        'amount': amount?.toJson(),
        'memo': memo,
        if (mode == 'msg-deposit') 'asset': asset,
        if (mode == 'msg-deposit') 'assetDecimals': assetDecimals,
      },
      if (family == 'solana' || family == 'sui')
        if (mode == 'serialized-tx') ...{
          'serializedTransaction': serializedTransaction,
          'minOut': minOut?.toJson(),
        } else ...{
          'to': to,
          'amount': amount?.toJson(),
          'memo': memo,
        },
      if (const {'xrp', 'tron', 'near', 'hypercore', 'cardano'}.contains(family)) ...{
        'to': to,
        'amount': amount?.toJson(),
        'memo': memo,
      },
      if (family == 'other') ...{
        'chain': chain,
        'to': to,
        'amount': amount?.toJson(),
        'memo': memo,
      },
    };
  }
}

Set<String> _executionKeys(String family, String mode) {
  if (family == 'evm') {
    return const {
      'family',
      'mode',
      'chainId',
      'to',
      'data',
      'value',
      'gasLimit',
      'memo',
      'approval',
      'transferAmount'
    };
  }
  if (family == 'utxo' && mode == 'payment-with-memo') {
    return const {'family', 'mode', 'to', 'amount', 'memo', 'gasRate'};
  }
  if (family == 'cosmos' && mode == 'bank-send') {
    return const {'family', 'mode', 'to', 'amount', 'memo'};
  }
  if (family == 'cosmos' && mode == 'msg-deposit') {
    return const {'family', 'mode', 'to', 'amount', 'memo', 'asset', 'assetDecimals'};
  }
  if ((family == 'solana' || family == 'sui') && mode == 'serialized-tx') {
    return const {'family', 'mode', 'serializedTransaction', 'minOut'};
  }
  if ((const {'solana', 'sui', 'xrp', 'tron', 'near', 'hypercore', 'cardano'}).contains(family) &&
      mode == 'deposit-transfer') {
    return const {'family', 'mode', 'to', 'amount', 'memo'};
  }
  if (family == 'other' && mode == 'deposit-transfer') {
    return const {'family', 'mode', 'chain', 'to', 'amount', 'memo'};
  }
  return const {'family', 'mode'};
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
    this.expiry,
    this.gasRate,
    this.resolvedFee,
    this.openOceanRoute,
  });

  factory PegarouteRoute.fromJson(Object? value) {
    final map = _object(value);
    _rejectUnknown(map, const {
      'provider',
      'subprovider',
      'private',
      'providerType',
      'expectedOutput',
      'fees',
      'estimatedTimeSeconds',
      'expiry',
      'memo',
      'inboundAddress',
      'router',
      'gasRate',
      'minAmount',
      'resolvedFee',
      'openOceanRoute'
    });
    return PegarouteRoute(
      provider: _requiredString(map, 'provider'),
      providerType: _requiredString(map, 'providerType'),
      expectedOutput: _requiredString(map, 'expectedOutput'),
      subprovider: _optionalString(map, 'subprovider'),
      privateValue:
          map.containsKey('private') ? PegaroutePrivateValue.fromJson(map['private']) : null,
      memo: _requiredNullableString(map, 'memo'),
      inboundAddress: _requiredNullableString(map, 'inboundAddress'),
      router: _requiredNullableString(map, 'router'),
      gasRate: _requiredNullableString(map, 'gasRate'),
      minAmount: _requiredNullableString(map, 'minAmount'),
      estimatedTimeSeconds: _requiredNum(map, 'estimatedTimeSeconds'),
      expiry: _requiredNullableStringOrNum(map, 'expiry'),
      fees: PegarouteFees.fromJson(map['fees']),
      resolvedFee: _resolvedFee(map['resolvedFee']),
      openOceanRoute: map.containsKey('openOceanRoute')
          ? PegarouteOpenOceanRoute.fromJson(map['openOceanRoute'])
          : null,
    );
  }

  factory PegarouteRoute.fromRouteInfoJson(Object? value) {
    final map = _object(value);
    _rejectUnknown(map, const {
      'provider',
      'subprovider',
      'private',
      'expectedOutput',
      'fees',
      'estimatedTimeSeconds',
      'openOceanRoute'
    });
    return PegarouteRoute(
      provider: _requiredString(map, 'provider'),
      expectedOutput: _requiredString(map, 'expectedOutput'),
      subprovider: _optionalString(map, 'subprovider'),
      privateValue:
          map.containsKey('private') ? PegaroutePrivateValue.fromJson(map['private']) : null,
      estimatedTimeSeconds: _requiredNum(map, 'estimatedTimeSeconds'),
      fees: PegarouteFees.fromJson(map['fees']),
      openOceanRoute: map.containsKey('openOceanRoute')
          ? PegarouteOpenOceanRoute.fromJson(map['openOceanRoute'])
          : null,
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
  final Object? expiry;
  final String? gasRate;
  final Map<String, dynamic>? resolvedFee;
  final PegarouteOpenOceanRoute? openOceanRoute;
}

class PegarouteOpenOceanRoute {
  const PegarouteOpenOceanRoute({this.dexId, this.dexCode, this.dexes});

  factory PegarouteOpenOceanRoute.fromJson(Object? value) {
    final map = _object(value);
    final hasDexes = map.containsKey('dexes');
    final dexesValue = map['dexes'];
    if (hasDexes && (dexesValue == null || dexesValue is! List)) {
      throw const PegarouteCodecException('openOceanRoute.dexes must be an array');
    }
    return PegarouteOpenOceanRoute(
      dexId: _optionalInt(map, 'dexId'),
      dexCode: _optionalString(map, 'dexCode'),
      dexes: !hasDexes
          ? null
          : (dexesValue as List).map((item) {
              final dex = _object(item);
              return PegarouteOpenOceanDex(
                dexId: _optionalInt(dex, 'dexId'),
                dexCode: _optionalString(dex, 'dexCode'),
              );
            }).toList(growable: false),
    );
  }

  final int? dexId;
  final String? dexCode;
  final List<PegarouteOpenOceanDex>? dexes;
}

class PegarouteOpenOceanDex {
  const PegarouteOpenOceanDex({this.dexId, this.dexCode});

  final int? dexId;
  final String? dexCode;
}

class PegarouteAffiliateFeeBreakdown {
  const PegarouteAffiliateFeeBreakdown({
    required this.configuredPegasusShareBps,
    required this.configuredIntegratorFeeBps,
    required this.providerAffiliateCapBps,
    required this.effectiveAffiliateFeeBps,
    required this.realizedPegasusFeeBps,
    required this.realizedIntegratorFeeBps,
    required this.feeSource,
    this.pegasusNetBps,
    this.pegasusNetUsd,
  });

  factory PegarouteAffiliateFeeBreakdown.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteAffiliateFeeBreakdown(
      configuredPegasusShareBps: _requiredNum(map, 'configuredPegasusShareBps'),
      configuredIntegratorFeeBps: _requiredNum(map, 'configuredIntegratorFeeBps'),
      providerAffiliateCapBps: _requiredNum(map, 'providerAffiliateCapBps'),
      effectiveAffiliateFeeBps: _requiredNum(map, 'effectiveAffiliateFeeBps'),
      realizedPegasusFeeBps: _requiredNum(map, 'realizedPegasusFeeBps'),
      realizedIntegratorFeeBps: _requiredNum(map, 'realizedIntegratorFeeBps'),
      feeSource: _requiredString(map, 'feeSource'),
      pegasusNetBps: _optionalNum(map, 'pegasusNetBps'),
      pegasusNetUsd: _optionalString(map, 'pegasusNetUsd'),
    );
  }

  final num configuredPegasusShareBps;
  final num configuredIntegratorFeeBps;
  final num providerAffiliateCapBps;
  final num effectiveAffiliateFeeBps;
  final num realizedPegasusFeeBps;
  final num realizedIntegratorFeeBps;
  final String feeSource;
  final num? pegasusNetBps;
  final String? pegasusNetUsd;
}

class PegarouteFees {
  const PegarouteFees(
      {this.affiliate,
      this.liquidity,
      this.outbound,
      this.subAffiliate,
      this.total,
      this.totalBps,
      this.slippageBps});

  factory PegarouteFees.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteFees(
      affiliate: _requiredString(map, 'affiliate'),
      liquidity: _requiredString(map, 'liquidity'),
      outbound: _requiredString(map, 'outbound'),
      subAffiliate: _optionalString(map, 'subAffiliate'),
      total: _requiredString(map, 'total'),
      totalBps: _optionalNum(map, 'totalBps'),
      slippageBps: _optionalNum(map, 'slippageBps'),
    );
  }

  final String? affiliate;
  final String? liquidity;
  final String? outbound;
  final String? subAffiliate;
  final String? total;
  final num? totalBps;
  final num? slippageBps;
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
      provider: _requiredPresentString(map, 'provider'),
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
      referenceId: _requiredNullableString(map, 'referenceId'),
      details: _requiredNullableValue(map, 'details'),
    );
  }

  final String name;
  final String? referenceId;
  final Object? details;

  PegarouteInstaswapSnapshot? get instaswapSwapLite {
    final value = details is Map ? (details as Map)['instaswapSwapLite'] : null;
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
      feeBreakdown: map.containsKey('feeBreakdown')
          ? _list(map, 'feeBreakdown').map(PegarouteInstaswapFeeLine.fromJson).toList()
          : null,
      etaSeconds: _optionalNum(map, 'etaSeconds'),
      depositTokenSymbol: _optionalString(map, 'depositTokenSymbol'),
      expiresAt: _optionalNullableString(map, 'expiresAt'),
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
    final status = _requiredString(map, 'status');
    if (!const {'pending', 'broadcasting', 'completed'}.contains(status)) {
      throw const PegarouteCodecException('refund status is invalid');
    }
    return PegarouteRefund(
      status: status,
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
    final hasPartialRefund = map.containsKey('partialRefund');
    if (hasPartialRefund && map['partialRefund'] == null) {
      throw const PegarouteCodecException('partialRefund must be an object');
    }
    return PegarouteStreamingProgress(
      completedSubSwaps: _requiredNum(map, 'completedSubSwaps'),
      totalSubSwaps: _requiredNum(map, 'totalSubSwaps'),
      lastSubSwapTimestamp: _optionalString(map, 'lastSubSwapTimestamp'),
      partialOutput: _optionalString(map, 'partialOutput'),
      partialRefund: hasPartialRefund ? _partialRefund(map['partialRefund']) : null,
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
      required this.fees,
      required this.timestamps,
      required this.route,
      this.affiliateFeeBreakdown,
      this.error,
      this.refund,
      this.streamingProgress,
      this.execution,
      this.provider});

  factory PegarouteStatusResponse.fromJson(Object? value) {
    final map = _object(value);
    final status = _requiredString(map, 'status');
    final internalStatus = _requiredString(map, 'internalStatus');
    if (!const {'pending', 'executing', 'success', 'fail'}.contains(status)) {
      throw const PegarouteCodecException('status is invalid');
    }
    if (!const {
      'pending',
      'submitted',
      'executing',
      'confirming',
      'completed',
      'failed',
      'refunded'
    }.contains(internalStatus)) {
      throw const PegarouteCodecException('internalStatus is invalid');
    }
    final errorValue = _requiredNullableValue(map, 'error');
    final refundValue = _requiredNullableValue(map, 'refund');
    final progressValue = _requiredNullableValue(map, 'streamingProgress');
    final route = PegarouteRoute.fromRouteInfoJson(map['route']);
    final provider =
        map.containsKey('provider') ? PegarouteProviderInfo.fromJson(map['provider']) : null;
    if (provider != null && provider.name != route.provider) {
      throw const PegarouteCodecException('route and provider identities disagree');
    }
    return PegarouteStatusResponse(
      transactionId: _requiredString(map, 'transactionId'),
      status: status,
      internalStatus: internalStatus,
      input: PegarouteStatusInput.fromJson(map['input']),
      output: PegarouteStatusOutput.fromJson(map['output']),
      fees: PegarouteFees.fromJson(map['fees']),
      timestamps: PegarouteStatusTimestamps.fromJson(map['timestamps']),
      route: route,
      affiliateFeeBreakdown: map.containsKey('affiliateFeeBreakdown')
          ? PegarouteAffiliateFeeBreakdown.fromJson(map['affiliateFeeBreakdown'])
          : null,
      error: errorValue == null ? null : PegarouteApiTransactionError.fromJson(errorValue),
      refund: refundValue == null ? null : PegarouteRefund.fromJson(refundValue),
      streamingProgress:
          progressValue == null ? null : PegarouteStreamingProgress.fromJson(progressValue),
      execution:
          map.containsKey('execution') ? PegarouteExecution.fromJson(map['execution']) : null,
      provider: provider,
    );
  }

  final String transactionId;
  final String status;
  final String internalStatus;
  final PegarouteStatusInput input;
  final PegarouteStatusOutput output;
  final PegarouteFees fees;
  final PegarouteStatusTimestamps timestamps;
  final PegarouteRoute route;
  final PegarouteAffiliateFeeBreakdown? affiliateFeeBreakdown;
  final PegarouteApiTransactionError? error;
  final PegarouteRefund? refund;
  final PegarouteStreamingProgress? streamingProgress;
  final PegarouteExecution? execution;
  final PegarouteProviderInfo? provider;
}

class PegarouteStatusTimestamps {
  const PegarouteStatusTimestamps({
    required this.created,
    this.submitted,
    this.confirmed,
    this.completed,
  });

  factory PegarouteStatusTimestamps.fromJson(Object? value) {
    final map = _object(value);
    return PegarouteStatusTimestamps(
      created: _requiredString(map, 'created'),
      submitted: _optionalString(map, 'submitted'),
      confirmed: _optionalString(map, 'confirmed'),
      completed: _optionalString(map, 'completed'),
    );
  }

  final String created;
  final String? submitted;
  final String? confirmed;
  final String? completed;
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
      instaswapSwapLite: map.containsKey('instaswapSwapLite')
          ? PegarouteInstaswapSnapshot.fromJson(map['instaswapSwapLite'])
          : null,
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
      chainId: _requiredNullableInt(map, 'chainId'),
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

  Map<String, String> get _headers => {'X-API-Key': configuration.apiKey.trim()};

  Uri _uri(String path, [Map<String, String>? query]) {
    final origin = configuration.origin;
    if (origin == null) throw const PegarouteUnavailableException();
    return origin.replace(path: path, queryParameters: query);
  }

  Future<PegarouteQuoteResponse> quote(PegarouteQuoteRequest request) async {
    final response = await _get(_uri('/quote', request.toQuery()), _headers);
    return _decode(response, PegarouteQuoteResponse.fromJson, expectedStatus: 200);
  }

  Future<PegarouteCatalogResponse> chains() async {
    final response = await _get(_uri('/chains'), _headers);
    return _decode(response, PegarouteCatalogResponse.fromJson, expectedStatus: 200);
  }

  Future<PegarouteTokenCatalogResponse> tokens(String chain) async {
    final normalized = chain.trim();
    if (normalized.isEmpty) throw const PegarouteCodecException('chain must not be blank');
    final response = await _get(_uri('/tokens', {'chain': normalized}), _headers);
    return _decode(response, PegarouteTokenCatalogResponse.fromJson, expectedStatus: 200);
  }

  Future<PegarouteStatusResponse> status(String id) async {
    final normalized = id.trim();
    if (normalized.isEmpty) throw const PegarouteCodecException('id must not be blank');
    final response = await _get(_uri('/swap/$normalized'), _headers);
    return _decode(response, PegarouteStatusResponse.fromJson, expectedStatus: 200);
  }

  Future<PegarouteSwapResponse> swap(PegarouteValidatedSwapPreflight preflight) async {
    final response = await _post(
      _uri('/swap'),
      {..._headers, 'Content-Type': 'application/json'},
      json.encode(preflight.request.toJson()),
    );
    return _decode(response, PegarouteSwapResponse.fromJson, expectedStatus: 202);
  }

  T _decode<T>(very_insecure_http_do_not_use.Response response, T Function(Object?) decoder,
      {required int expectedStatus}) {
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
    if (response.statusCode != expectedStatus) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw PegarouteCodecException('response must use HTTP $expectedStatus');
      }
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
      required this.providerType,
      required this.route,
      required this.execution,
      required this.provider});

  factory PegarouteSwapResponse.fromJson(Object? value) {
    final map = _object(value);
    _rejectUnknown(
        map, const {'transactionId', 'status', 'providerType', 'route', 'execution', 'provider'});
    final status = _requiredString(map, 'status');
    if (status != 'pending') throw const PegarouteCodecException('swap status must be pending');
    final route = PegarouteRoute.fromRouteInfoJson(map['route']);
    final provider = PegarouteProviderInfo.fromJson(map['provider']);
    if (route.provider != provider.name) {
      throw const PegarouteCodecException('route and provider identities disagree');
    }
    return PegarouteSwapResponse(
      transactionId: _requiredString(map, 'transactionId'),
      status: status,
      providerType: _requiredString(map, 'providerType'),
      route: route,
      execution: PegarouteExecution.fromJson(map['execution']),
      provider: provider,
    );
  }

  final String transactionId;
  final String status;
  final String providerType;
  final PegarouteRoute route;
  final PegarouteExecution execution;
  final PegarouteProviderInfo provider;
}

Map<String, String> _nonEmpty(Map<String, String?> values) => Map.fromEntries(
      values.entries.where((entry) {
        if (entry.value != null && entry.value!.trim().isEmpty) {
          throw PegarouteCodecException('${entry.key} must not be blank');
        }
        return entry.value != null;
      }).map(
        (entry) => MapEntry(entry.key, entry.value!),
      ),
    );

Map<String, dynamic> _object(Object? value) {
  if (value is! Map) throw const PegarouteCodecException('expected JSON object');
  return Map<String, dynamic>.from(value);
}

void _rejectUnknown(Map<String, dynamic> map, Set<String> allowed) {
  if (map.keys.any((key) => !allowed.contains(key))) {
    throw const PegarouteCodecException('object contains unknown fields');
  }
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

String _requiredPresentString(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! String) throw PegarouteCodecException('$key must be a string');
  return value;
}

String _requiredRequestId(String value, String key) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw PegarouteCodecException('$key must not be blank');
  return normalized;
}

String? _optionalRequestId(String? value, String key) {
  if (value == null) return null;
  return _requiredRequestId(value, key);
}

String? _normalizeRequestSender(String? sender) => _optionalRequestId(sender, 'senderAddress');

String? _normalizeRequestRefund(String? sender, String? refund) {
  final normalized = _optionalRequestId(refund, 'refundAddress');
  if (normalized == null || normalized == sender) return null;
  return normalized;
}

String _positiveAmount(String value) {
  final normalized = value.trim();
  final parsed = double.tryParse(normalized);
  if (!_isDecimal(normalized) || parsed == null || !parsed.isFinite || parsed <= 0) {
    throw const PegarouteCodecException('amount must be a finite positive decimal');
  }
  return normalized;
}

String? _optionalString(Map<String, dynamic> map, String key) {
  if (!map.containsKey(key)) return null;
  final value = map[key];
  if (value is! String) throw PegarouteCodecException('$key must be a non-null string');
  return value;
}

String? _optionalNullableString(Map<String, dynamic> map, String key) {
  if (!map.containsKey(key)) return null;
  final value = map[key];
  if (value == null) return null;
  if (value is! String) throw PegarouteCodecException('$key must be a string or null');
  return value;
}

String? _requiredNullableString(Map<String, dynamic> map, String key) {
  if (!map.containsKey(key)) throw PegarouteCodecException('$key is required');
  return _optionalNullableString(map, key);
}

int? _requiredNullableInt(Map<String, dynamic> map, String key) {
  if (!map.containsKey(key)) throw PegarouteCodecException('$key is required');
  final value = map[key];
  if (value == null) return null;
  if (value is! int) throw PegarouteCodecException('$key must be an integer or null');
  return value;
}

Object? _requiredNullableValue(Map<String, dynamic> map, String key) {
  if (!map.containsKey(key)) throw PegarouteCodecException('$key is required');
  return map[key];
}

Object? _requiredNullableStringOrNum(Map<String, dynamic> map, String key) {
  if (!map.containsKey(key)) throw PegarouteCodecException('$key is required');
  final value = map[key];
  if (value == null || value is String || value is num) return value;
  throw PegarouteCodecException('$key must be a string, number, or null');
}

PegarouteTokenAmount? _requiredNullableTokenAmount(Map<String, dynamic> map, String key) {
  if (!map.containsKey(key)) throw PegarouteCodecException('$key is required');
  final value = map[key];
  return value == null ? null : PegarouteTokenAmount.fromJson(value);
}

PegarouteEvmApproval? _requiredNullableApproval(Map<String, dynamic> map, String key) {
  if (!map.containsKey(key)) throw PegarouteCodecException('$key is required');
  final value = map[key];
  return value == null ? null : PegarouteEvmApproval.fromJson(value);
}

int _requiredInt(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! int) throw PegarouteCodecException('$key must be an integer');
  return value;
}

int _requiredNonnegativeInt(Map<String, dynamic> map, String key) {
  final value = _requiredInt(map, key);
  if (value < 0) throw PegarouteCodecException('$key must be nonnegative');
  return value;
}

int? _optionalInt(Map<String, dynamic> map, String key) {
  if (!map.containsKey(key)) return null;
  final value = map[key];
  if (value is! int) throw PegarouteCodecException('$key must be a non-null integer');
  return value;
}

Map<String, dynamic> _partialRefund(Object? value) {
  final map = _object(value);
  _requiredString(map, 'amount');
  _requiredString(map, 'chain');
  _requiredString(map, 'token');
  return map;
}

Map<String, dynamic> _resolvedFee(Object? value) {
  final map = _object(value);
  if (map['feeBps'] is! num) throw const PegarouteCodecException('feeBps must be numeric');
  return map;
}

bool _requiredBool(Map<String, dynamic> map, String key) {
  if (map[key] is! bool) throw PegarouteCodecException('$key must be boolean');
  return map[key] as bool;
}

num? _optionalNum(Map<String, dynamic> map, String key) {
  if (!map.containsKey(key)) return null;
  final value = map[key];
  if (value is! num) throw PegarouteCodecException('$key must be non-null numeric');
  return value;
}

num? _optionalNullableNum(Map<String, dynamic> map, String key) {
  if (!map.containsKey(key)) return null;
  final value = map[key];
  if (value == null) return null;
  if (value is! num) throw PegarouteCodecException('$key must be numeric or null');
  return value;
}

num _requiredNum(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! num || !value.isFinite)
    throw PegarouteCodecException('$key must be finite numeric');
  return value;
}

bool _isDecimal(String value) => RegExp(r'^(0|[1-9][0-9]*)(\.[0-9]+)?$').hasMatch(value);

Never _invalid(String field) => throw PegarouteCodecException('invalid $field');

bool _validCalldata(String? value) {
  if (value == null || !value.startsWith('0x') || value.length <= 2) return false;
  final hex = value.substring(2);
  return hex.length.isEven && RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex);
}

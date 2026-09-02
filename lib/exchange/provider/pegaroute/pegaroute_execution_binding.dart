import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'dart:convert';

import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_currency_mapper.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:collection/collection.dart';

final class ValidatedTradeExecution {
  const ValidatedTradeExecution({
    required this.execution,
    required this.rawExecutionJson,
  });

  final TradeExecution execution;
  final String rawExecutionJson;
}

final class PegarouteValidatedSwapPreflight {
  const PegarouteValidatedSwapPreflight._({
    required this.request,
    required this.route,
    required this.requestJson,
    required this.routeSnapshotJson,
    required this.quoteId,
    required this.quoteExpiresAt,
    required this.tradeId,
    required this.sourceChain,
    required this.sourceToken,
    required this.nativeToken,
    required this.destinationChain,
    required this.destinationToken,
    required this.sourceDecimals,
    required this.walletId,
    required this.walletChainId,
    required this.walletAddress,
  });

  final PegarouteSwapRequest request;
  final PegarouteRoute route;
  final String requestJson;
  final String routeSnapshotJson;
  final String quoteId;
  final DateTime quoteExpiresAt;
  final String tradeId;
  final String sourceChain;
  final String sourceToken;
  final String nativeToken;
  final String destinationChain;
  final String destinationToken;
  final int sourceDecimals;
  final String walletId;
  final int? walletChainId;
  final String walletAddress;
}

final class PegarouteExecutionBindingValidator {
  const PegarouteExecutionBindingValidator({DateTime Function()? clock}) : _clock = clock;

  final DateTime Function()? _clock;

  DateTime get now => (_clock ?? DateTime.now)().toUtc();

  PegarouteValidatedSwapPreflight preflightSwap({
    required Trade trade,
    required WalletBase wallet,
    required PegarouteQuoteResponse quote,
    required PegarouteRoute route,
    required PegarouteSwapRequest request,
    DateTime? at,
  }) {
    final current = (at ?? now).toUtc();
    _validateQuotePreflight(quote: quote, route: route, request: request, at: current);
    if (quote.quoteId.trim().isEmpty || request.quoteId != quote.quoteId) {
      throw const PegarouteBindingException('request quote identity changed');
    }
    if (request.routeProvider == null || request.routeProvider != route.provider) {
      throw const PegarouteBindingException('request route provider is not bound');
    }
    if (trade.providerRaw != 17 ||
        trade.id.trim().isEmpty ||
        trade.walletId == null ||
        trade.walletId!.isEmpty ||
        trade.walletId != wallet.id ||
        trade.isSendAll == true ||
        trade.providerName == null ||
        trade.providerName!.isEmpty ||
        trade.providerName != route.provider ||
        trade.amount != request.amount ||
        trade.senderAddress == null ||
        trade.payoutAddress == null ||
        trade.fromWalletAddress == null ||
        trade.fromWalletAddress!.isEmpty ||
        trade.senderAddress!.isEmpty ||
        trade.payoutAddress!.isEmpty) {
      throw const PegarouteBindingException('local swap context is not bound');
    }
    final source = _currencyMapper.map(_requiredCurrency(trade.from, 'source currency'));
    final destination = _currencyMapper.map(_requiredCurrency(trade.to, 'destination currency'));
    final sourceDecimals = trade.from!.decimals;
    if (_canonicalChain(request.fromChain) != source.chain ||
        _canonicalToken(request.fromChain, request.fromToken) != source.token ||
        _canonicalChain(request.toChain) != destination.chain ||
        _canonicalToken(request.toChain, request.toToken) != destination.token ||
        !_sameAddress(source.chain, request.senderAddress!, trade.senderAddress!) ||
        !_sameAddress(destination.chain, request.destinationAddress!, trade.payoutAddress!) ||
        !_sameOptionalAddress(
            source.chain, request.refundAddress, _normalizedRefund(trade, source.chain))) {
      throw const PegarouteBindingException('request assets or addresses are not bound');
    }
    final walletAddress = wallet.walletAddresses.address.trim();
    if (wallet.id.trim().isEmpty ||
        walletAddress.isEmpty ||
        !_sameAddress(source.chain, walletAddress, trade.fromWalletAddress!) ||
        !_sameAddress(source.chain, walletAddress, trade.senderAddress!)) {
      throw const PegarouteBindingException('wallet context is not bound');
    }
    final expectedWalletChain = _chainIdFor(source.chain);
    if (expectedWalletChain != null &&
        (wallet.chainId != expectedWalletChain || trade.chainId != expectedWalletChain)) {
      throw const PegarouteBindingException('wallet chain is not bound');
    }
    _validateRequestAmount(request.amount, sourceDecimals);
    return PegarouteValidatedSwapPreflight._(
      request: request,
      route: route,
      requestJson: jsonEncode(request.toJson()),
      routeSnapshotJson: jsonEncode(_routeSnapshot(route)),
      quoteId: quote.quoteId,
      quoteExpiresAt: _parseDateTime(quote.expiresAt, 'quote expiry'),
      tradeId: trade.id,
      sourceChain: source.chain,
      sourceToken: source.token,
      nativeToken: source.nativeToken,
      destinationChain: destination.chain,
      destinationToken: destination.token,
      sourceDecimals: sourceDecimals,
      walletId: wallet.id,
      walletChainId: wallet.chainId,
      walletAddress: walletAddress,
    );
  }

  void validateQuotePreflight({
    required PegarouteQuoteResponse quote,
    required PegarouteRoute route,
    required PegarouteSwapRequest request,
    DateTime? at,
  }) {
    _validateQuotePreflight(quote: quote, route: route, request: request, at: at ?? now);
  }

  void _validateQuotePreflight({
    required PegarouteQuoteResponse quote,
    required PegarouteRoute route,
    required PegarouteSwapRequest request,
    required DateTime at,
  }) {
    final current = at.toUtc();
    final quoteExpiry = _parseDateTime(quote.expiresAt, 'quote expiry');
    if (!current.isBefore(quoteExpiry)) {
      throw const PegarouteBindingException('quote is expired');
    }
    if (route.provider.trim().isEmpty ||
        route.providerType == null ||
        route.providerType!.trim().isEmpty ||
        !quote.routes.any((candidate) => _sameRoute(candidate, route))) {
      throw const PegarouteBindingException('selected route is not from the quote');
    }
    if (route.expiry != null) {
      final expiry = TradeExecutionExpiry.fromProviderValue(route.expiry).instant();
      if (!current.isBefore(expiry)) {
        throw const PegarouteBindingException('selected route is expired');
      }
    }
    if (request.routeProvider != null && request.routeProvider != route.provider) {
      throw const PegarouteBindingException('selected route provider changed');
    }
  }

  TradeExecution bindSwapResponse({
    required PegarouteValidatedSwapPreflight preflight,
    required PegarouteSwapResponse response,
  }) {
    if (response.transactionId.trim() != preflight.tradeId ||
        response.transactionId.trim().isEmpty ||
        response.provider.name != preflight.route.provider ||
        response.providerType != preflight.route.providerType ||
        !_sameRouteEcho(preflight.route, response.route, response.providerType)) {
      throw const PegarouteBindingException('swap response route changed');
    }
    _validateExecutionSemantics(
      execution: response.execution,
      sourceChain: preflight.sourceChain,
      sourceToken: preflight.sourceToken,
      nativeToken: preflight.nativeToken,
      walletChainId: preflight.walletChainId,
      sourceAmount: preflight.request.amount,
      sourceDecimals: preflight.sourceDecimals,
    );
    final sourceAmountBaseUnits = _toBaseUnits(preflight.request.amount, preflight.sourceDecimals);
    final execution = TradeExecution(
      family: response.execution.family,
      mode: response.execution.mode,
      sourceChain: preflight.sourceChain,
      sourceToken: preflight.sourceToken,
      nativeToken: preflight.nativeToken,
      destinationChain: preflight.destinationChain,
      destinationToken: preflight.destinationToken,
      routeProvider: response.route.provider,
      subprovider: response.route.subprovider,
      privateIntent: response.route.privateValue?.value,
      binding: TradeExecutionBinding(
        tradeId: preflight.tradeId,
        providerRaw: 17,
        quoteId: preflight.quoteId,
        quoteExpiresAt: preflight.quoteExpiresAt,
        routeExpiry: preflight.route.expiry == null
            ? null
            : TradeExecutionExpiry.fromProviderValue(preflight.route.expiry),
        sourceAmount: preflight.request.amount,
        sourceAmountBaseUnits: sourceAmountBaseUnits,
        sourceDecimals: preflight.sourceDecimals,
        senderAddress: preflight.request.senderAddress!,
        refundAddress: preflight.request.refundAddress,
        destinationAddress: preflight.request.destinationAddress!,
        isSendAll: false,
        walletId: preflight.walletId,
        walletChainId: preflight.walletChainId,
        walletAddress: preflight.walletAddress,
        reviewedRouteJson: preflight.routeSnapshotJson,
        providerReferenceId: response.provider.referenceId,
      ),
      payload: _payload(response.execution),
    );
    _validateExecutionAmount(execution, execution.binding);
    return execution;
  }

  ValidatedTradeExecution validatePersisted({
    required Trade trade,
    WalletBase? wallet,
    String? expectedRawExecutionJson,
  }) {
    if (trade.providerRaw != 17 || trade.executionJson == null || trade.executionJson!.isEmpty) {
      throw const PegarouteBindingException('trade is not a bound Pegaroute execution');
    }
    final raw = trade.executionJson!;
    if (expectedRawExecutionJson != null && raw != expectedRawExecutionJson) {
      throw const PegarouteBindingException('execution snapshot changed');
    }
    late final TradeExecution execution;
    try {
      execution = TradeExecution.fromJsonString(raw);
    } catch (_) {
      throw const PegarouteBindingException('execution payload is invalid');
    }
    final binding = execution.binding;
    if (binding.tradeId != trade.id ||
        binding.providerRaw != trade.providerRaw ||
        binding.isSendAll != (trade.isSendAll == true) ||
        binding.isSendAll) {
      throw const PegarouteBindingException('trade identity binding changed');
    }
    final reviewedRoute = _reviewedRoute(binding.reviewedRouteJson);
    if (reviewedRoute['provider'] != execution.routeProvider || execution.routeProvider.isEmpty) {
      throw const PegarouteBindingException('route provider binding changed');
    }
    if (trade.walletId == null ||
        binding.walletId != trade.walletId ||
        (binding.walletChainId != null && trade.chainId != binding.walletChainId) ||
        !_sameAddress(execution.sourceChain, binding.walletAddress, binding.senderAddress) ||
        trade.fromWalletAddress == null ||
        !_sameAddress(execution.sourceChain, binding.walletAddress, trade.fromWalletAddress!)) {
      throw const PegarouteBindingException('wallet identity binding changed');
    }
    final source = _currencyMapper.map(_requiredCurrency(trade.from, 'source currency'));
    final destination = _currencyMapper.map(_requiredCurrency(trade.to, 'destination currency'));
    if (execution.sourceChain != source.chain ||
        execution.sourceToken != source.token ||
        execution.nativeToken != source.nativeToken ||
        execution.destinationChain != destination.chain ||
        execution.destinationToken != destination.token) {
      throw const PegarouteBindingException('execution asset binding changed');
    }
    if (binding.sourceAmount != trade.amount ||
        binding.sourceDecimals != trade.from!.decimals ||
        _toBaseUnits(binding.sourceAmount, binding.sourceDecimals) !=
            binding.sourceAmountBaseUnits) {
      throw const PegarouteBindingException('execution amount binding changed');
    }
    if (trade.senderAddress == null ||
        !_sameAddress(execution.sourceChain, binding.senderAddress, trade.senderAddress!)) {
      throw const PegarouteBindingException('sender binding changed');
    }
    if (!_sameOptionalAddress(execution.sourceChain, binding.refundAddress,
        _normalizedRefund(trade, execution.sourceChain))) {
      throw const PegarouteBindingException('refund binding changed');
    }
    if (trade.payoutAddress == null ||
        !_sameAddress(
            execution.destinationChain, binding.destinationAddress, trade.payoutAddress!)) {
      throw const PegarouteBindingException('destination binding changed');
    }
    if (trade.providerName == null ||
        trade.providerName!.isEmpty ||
        trade.providerName != execution.routeProvider) {
      throw const PegarouteBindingException('route provider binding changed');
    }
    if (binding.providerReferenceId != trade.providerId) {
      throw const PegarouteBindingException('provider reference binding changed');
    }
    _validateExecutionSemantics(
      execution: _asProviderExecution(execution),
      sourceChain: execution.sourceChain,
      sourceToken: execution.sourceToken,
      nativeToken: execution.nativeToken,
      walletChainId: binding.walletChainId,
      sourceAmount: binding.sourceAmount,
      sourceDecimals: binding.sourceDecimals,
    );
    if (wallet != null) {
      if (wallet.id != binding.walletId ||
          (binding.walletChainId != null && wallet.chainId != binding.walletChainId) ||
          !_sameAddress(
              execution.sourceChain, binding.walletAddress, wallet.walletAddresses.address)) {
        throw const PegarouteBindingException('active wallet binding changed');
      }
    }
    _validateReviewedRouteForExecution(reviewedRoute, execution);
    _validateExecutionAmount(execution, binding);
    return ValidatedTradeExecution(execution: execution, rawExecutionJson: raw);
  }

  void validateStatusResponse({
    required ValidatedTradeExecution validated,
    required PegarouteStatusResponse response,
  }) {
    final execution = validated.execution;
    final binding = execution.binding;
    if (response.transactionId != binding.tradeId ||
        _canonicalChain(response.input.chain) != execution.sourceChain ||
        _canonicalToken(response.input.chain, response.input.token) != execution.sourceToken ||
        response.input.amount != binding.sourceAmount ||
        !_sameAddress(execution.sourceChain, response.input.address ?? '', binding.senderAddress) ||
        !_sameOptionalAddress(
            execution.sourceChain,
            _normalizedRefundValues(
              execution.sourceChain,
              response.input.address,
              response.input.refundAddress,
            ),
            binding.refundAddress) ||
        _canonicalChain(response.output.chain) != execution.destinationChain ||
        _canonicalToken(response.output.chain, response.output.token) !=
            execution.destinationToken ||
        !_sameAddress(
            execution.destinationChain, response.output.address, binding.destinationAddress) ||
        !_sameRouteEchoFromSnapshot(
            _reviewedRoute(binding.reviewedRouteJson), response.route, null) ||
        !_sameProviderReference(binding, response) ||
        !_sameRefund(execution.sourceChain, binding, response)) {
      throw const PegarouteBindingException('status context does not match execution binding');
    }
    if (response.provider?.name != null && response.provider!.name != execution.routeProvider) {
      throw const PegarouteBindingException('status provider does not match execution binding');
    }
    if (response.route.expiry != null) {
      TradeExecutionExpiry.fromProviderValue(response.route.expiry).instant();
    }
    final providerExpiry = response.input.instaswapSwapLite?.expiresAt;
    if (providerExpiry != null) _parseDateTime(providerExpiry, 'provider expiry');
    if (response.execution != null) {
      if (response.execution!.family != execution.family ||
          response.execution!.mode != execution.mode ||
          !const DeepCollectionEquality()
              .equals(_payload(response.execution!), execution.payload)) {
        throw const PegarouteBindingException('status execution changed');
      }
      _validateExecutionSemantics(
        execution: response.execution!,
        sourceChain: execution.sourceChain,
        sourceToken: execution.sourceToken,
        nativeToken: execution.nativeToken,
        walletChainId: binding.walletChainId,
        sourceAmount: binding.sourceAmount,
        sourceDecimals: binding.sourceDecimals,
      );
    }
  }

  final PegarouteCurrencyMapper _currencyMapper = const PegarouteCurrencyMapper();

  static CryptoCurrency _requiredCurrency(CryptoCurrency? currency, String field) {
    if (currency == null) throw PegarouteBindingException('$field is missing');
    return currency;
  }

  static Map<String, dynamic> _payload(PegarouteExecution execution) => execution.toJson()
    ..remove('family')
    ..remove('mode');

  static void _validateExecutionAmount(TradeExecution execution, TradeExecutionBinding binding) {
    final amount = switch (execution.family) {
      'evm' when execution.mode == 'native-transfer' => execution.payload['value'],
      'evm' when execution.mode == 'erc20-transfer' => execution.payload['transferAmount'],
      'evm' => execution.payload['approval'] is Map
          ? (execution.payload['approval'] as Map)['amount']
          : null,
      _ => execution.payload['amount'],
    };
    if (amount == null) return;
    if (amount is! Map ||
        amount['baseUnits'] != binding.sourceAmountBaseUnits ||
        amount['display'] != binding.sourceAmount) {
      throw const PegarouteBindingException('execution amount differs from requested amount');
    }
  }

  static PegarouteExecution _asProviderExecution(TradeExecution execution) {
    try {
      return PegarouteExecution.fromJson({
        'family': execution.family,
        'mode': execution.mode,
        ...execution.payload,
      });
    } catch (_) {
      throw const PegarouteBindingException('execution semantics are invalid');
    }
  }

  static void _validateExecutionSemantics({
    required PegarouteExecution execution,
    required String sourceChain,
    required String sourceToken,
    required String nativeToken,
    required int? walletChainId,
    required String sourceAmount,
    required int sourceDecimals,
  }) {
    final expectedFamily = _familyForChain(sourceChain);
    if (expectedFamily != null && execution.family != expectedFamily) {
      throw const PegarouteBindingException('execution family does not match source chain');
    }
    final expectedBaseUnits = _toBaseUnits(sourceAmount, sourceDecimals);
    final chainId = _chainIdFor(sourceChain);
    if (execution.family == 'evm') {
      if (execution.chainId != chainId || walletChainId != chainId) {
        throw const PegarouteBindingException('execution EVM chain is not bound');
      }
      if (execution.mode == 'native-transfer') {
        _requireAmount(execution.value, sourceAmount, expectedBaseUnits);
      } else if (execution.mode == 'erc20-transfer') {
        _requireAmount(execution.transferAmount, sourceAmount, expectedBaseUnits);
      } else if (execution.mode == 'contract-call') {
        if (execution.value != null) {
          if (sourceToken == nativeToken) {
            _requireAmount(execution.value, sourceAmount, expectedBaseUnits);
          } else if (execution.value!.display != '0' || execution.value!.baseUnits != '0') {
            throw const PegarouteBindingException('native call value is not bound');
          }
        }
        if (execution.approval != null) {
          final identity = _tokenIdentity(sourceToken);
          if (identity == null ||
              !_sameAddress(sourceChain, identity, execution.approval!.tokenAddress)) {
            throw const PegarouteBindingException('approval token is not bound');
          }
          _requireAmount(execution.approval!.amount, sourceAmount, expectedBaseUnits);
        }
      }
      return;
    }
    if (execution.mode == 'serialized-tx') return;
    if (execution.family == 'other' && execution.chain != sourceChain) {
      throw const PegarouteBindingException('opaque execution chain changed');
    }
    if (execution.amount != null) {
      _requireAmount(execution.amount, sourceAmount, expectedBaseUnits);
    }
  }

  static void _requireAmount(PegarouteTokenAmount? amount, String display, String baseUnits) {
    if (amount == null || amount.display != display || amount.baseUnits != baseUnits) {
      throw const PegarouteBindingException('execution amount differs from requested amount');
    }
  }

  static String? _tokenIdentity(String token) {
    final separator = token.indexOf('-');
    return separator < 0 ? null : token.substring(separator + 1);
  }

  static int? _chainIdFor(String chain) {
    return const {
      'ETH': 1,
      'BSC': 56,
      'POLYGON': 137,
      'AVAX': 43114,
      'ARBITRUM': 42161,
      'BASE': 8453,
    }[_canonicalChain(chain)];
  }

  static String? _familyForChain(String chain) {
    final normalized = _canonicalChain(chain);
    if (_chainIdFor(normalized) != null) return 'evm';
    return switch (normalized) {
      'BTC' || 'BCH' || 'LTC' || 'DOGE' || 'DASH' || 'ZEC' => 'utxo',
      'SOL' => 'solana',
      'SUI' => 'sui',
      'XRP' => 'xrp',
      'TRON' => 'tron',
      'NEAR' => 'near',
      'CARDANO' => 'cardano',
      'XMR' || 'STELLAR' || 'THOR' => 'other',
      _ => null,
    };
  }

  static String _toBaseUnits(String amount, int decimals) {
    final normalized = amount.trim();
    final match = RegExp(r'^(0|[1-9][0-9]*)(\.[0-9]+)?$').firstMatch(normalized);
    if (match == null) throw const PegarouteBindingException('amount is not canonical');
    final fraction = match.group(2)?.substring(1) ?? '';
    if (fraction.length > decimals) {
      throw const PegarouteBindingException('amount has excess precision');
    }
    final whole = match.group(1)!;
    return (BigInt.parse(whole) * BigInt.from(10).pow(decimals) +
            BigInt.parse(
                fraction.padRight(decimals, '0').isEmpty ? '0' : fraction.padRight(decimals, '0')))
        .toString();
  }

  static void _validateRequestAmount(String amount, int decimals) {
    if (_toBaseUnits(amount, decimals) == '0') {
      throw const PegarouteBindingException('amount must be positive');
    }
  }

  static DateTime _parseDateTime(String value, String field) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) throw PegarouteBindingException('$field is invalid');
    return parsed.toUtc();
  }

  static String? _normalizedRefund(Trade trade, String chain) {
    final refund = trade.refundAddress?.trim();
    final sender = trade.senderAddress?.trim();
    return refund == null ||
            refund.isEmpty ||
            sender == null ||
            sender.isEmpty ||
            _sameAddress(chain, refund, sender)
        ? null
        : refund;
  }

  static String? _normalizedRefundValues(String chain, String? sender, String? refund) {
    if (refund == null || refund.isEmpty) return null;
    if (sender != null && sender.isNotEmpty && _sameAddress(chain, sender, refund)) return null;
    return refund;
  }

  static bool _sameOptionalAddress(String chain, String? first, String? second) {
    if (first == null || first.isEmpty || second == null || second.isEmpty) {
      return (first == null || first.isEmpty) && (second == null || second.isEmpty);
    }
    return _sameAddress(chain, first, second);
  }

  static bool _sameAddress(String chain, String first, String second) {
    final a = first.trim();
    final b = second.trim();
    if (a.isEmpty || b.isEmpty) return false;
    final folded = const {
      'ETH',
      'BSC',
      'POLYGON',
      'AVAX',
      'ARBITRUM',
      'BASE',
      'SUI',
      'HYPERCORE',
    };
    return folded.contains(chain.toUpperCase()) ? a.toLowerCase() == b.toLowerCase() : a == b;
  }

  static bool _samePrivate(Object? first, Object? second) {
    return (first ?? false) == (second ?? false);
  }

  static String _canonicalChain(String chain) => chain.trim().toUpperCase();

  static bool _sameRoute(PegarouteRoute first, PegarouteRoute second) {
    return const DeepCollectionEquality().equals(
      _routeSnapshot(first),
      _routeSnapshot(second),
    );
  }

  static bool _sameRouteEcho(PegarouteRoute expected, PegarouteRoute actual, String providerType) {
    return _sameRouteEchoFromSnapshot(
      _routeSnapshot(expected),
      actual,
      providerType,
    );
  }

  static bool _sameRouteEchoFromSnapshot(
      Map<String, dynamic> expected, PegarouteRoute actual, String? providerType) {
    final echoed = _routeSnapshot(actual, providerType: providerType);
    final keys = <String>[
      'provider',
      'subprovider',
      'private',
      'expectedOutput',
      'fees',
      'estimatedTimeSeconds',
      'openOceanRoute',
    ];
    if (providerType != null) keys.add('providerType');
    for (final key in keys) {
      if (!const DeepCollectionEquality().equals(expected[key], echoed[key])) return false;
    }
    return true;
  }

  static Map<String, dynamic> _reviewedRoute(String raw) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const PegarouteBindingException('reviewed route snapshot is invalid');
    }
    if (decoded is! Map) {
      throw const PegarouteBindingException('reviewed route snapshot is invalid');
    }
    final map = Map<String, dynamic>.from(decoded);
    const keys = {
      'provider',
      'providerType',
      'subprovider',
      'private',
      'expectedOutput',
      'fees',
      'estimatedTimeSeconds',
      'memo',
      'inboundAddress',
      'router',
      'minAmount',
      'expiry',
      'gasRate',
      'resolvedFee',
      'openOceanRoute',
    };
    if (map.length != keys.length ||
        map.keys.any((key) => !keys.contains(key)) ||
        map['provider'] is! String ||
        (map['provider'] as String).isEmpty ||
        map['providerType'] is! String ||
        (map['providerType'] as String).isEmpty) {
      throw const PegarouteBindingException('reviewed route snapshot is incomplete');
    }
    return map;
  }

  static void _validateReviewedRouteForExecution(
      Map<String, dynamic> route, TradeExecution execution) {
    if (route['provider'] != execution.routeProvider ||
        !_samePrivate(route['private'], execution.privateIntent) ||
        route['subprovider'] != execution.subprovider) {
      throw const PegarouteBindingException('reviewed route binding changed');
    }
  }

  static bool _sameProviderReference(
      TradeExecutionBinding binding, PegarouteStatusResponse response) {
    final inputReference = response.input.providerReferenceId;
    final providerReference = response.provider?.referenceId;
    if (inputReference != null && providerReference != null && inputReference != providerReference)
      return false;
    final observed = providerReference ?? inputReference;
    return observed == binding.providerReferenceId;
  }

  static bool _sameRefund(
      String sourceChain, TradeExecutionBinding binding, PegarouteStatusResponse response) {
    final refund = response.refund;
    if (refund == null) return true;
    final expectedAddress = binding.refundAddress ?? binding.senderAddress;
    return _canonicalChain(refund.chain) == _canonicalChain(sourceChain) &&
        refund.originalAmount == binding.sourceAmount &&
        _sameAddress(sourceChain, refund.refundAddress, expectedAddress);
  }

  static Map<String, dynamic> _routeSnapshot(PegarouteRoute route, {String? providerType}) => {
        'provider': route.provider,
        'providerType': providerType ?? route.providerType,
        'subprovider': route.subprovider,
        'private': route.privateValue?.value ?? false,
        'expectedOutput': route.expectedOutput,
        'fees': _feesSnapshot(route.fees),
        'estimatedTimeSeconds': route.estimatedTimeSeconds,
        'memo': route.memo,
        'inboundAddress': route.inboundAddress,
        'router': route.router,
        'minAmount': route.minAmount,
        'expiry': route.expiry,
        'gasRate': route.gasRate,
        'resolvedFee': route.resolvedFee,
        'openOceanRoute': route.openOceanRoute == null
            ? null
            : {
                'dexId': route.openOceanRoute!.dexId,
                'dexCode': route.openOceanRoute!.dexCode,
                'dexes': route.openOceanRoute!.dexes
                    ?.map((dex) => {'dexId': dex.dexId, 'dexCode': dex.dexCode})
                    .toList(),
              },
      };

  static Map<String, dynamic>? _feesSnapshot(PegarouteFees? fees) => fees == null
      ? null
      : {
          'affiliate': fees.affiliate,
          'liquidity': fees.liquidity,
          'outbound': fees.outbound,
          'subAffiliate': fees.subAffiliate,
          'total': fees.total,
          'totalBps': fees.totalBps,
          'slippageBps': fees.slippageBps,
        };

  static String _canonicalToken(String chain, String token) {
    final normalizedChain = _canonicalChain(chain);
    final separator = token.indexOf('-');
    if (separator < 0) return token.trim().toUpperCase();
    final symbol = token.substring(0, separator).trim().toUpperCase();
    final identity = token.substring(separator + 1).trim();
    final normalizedIdentity = const {
      'ETH',
      'BSC',
      'POLYGON',
      'AVAX',
      'ARBITRUM',
      'BASE',
      'HYPERCORE',
    }.contains(normalizedChain)
        ? identity.toLowerCase()
        : identity;
    return '$symbol-$normalizedIdentity';
  }
}

final class PegarouteBindingException implements Exception {
  const PegarouteBindingException(this.message);

  final String message;

  @override
  String toString() => 'Invalid Pegaroute execution binding: $message';
}

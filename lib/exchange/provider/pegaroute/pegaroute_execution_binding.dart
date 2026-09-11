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
  PegarouteValidatedSwapPreflight._({
    required PegarouteValidatedQuote quote,
    required this.requestJson,
    required this.routeSnapshotJson,
    required this.quoteId,
    required this.quoteExpiresAt,
    required this.routeExpiry,
    required this.tradeId,
    required this.sourceChain,
    required this.sourceToken,
    required this.nativeToken,
    required this.destinationChain,
    required this.destinationToken,
    required this.sourceAmount,
    required this.sourceDecimals,
    required this.destinationDecimals,
    required this.walletId,
    required this.walletChainId,
    required this.walletAddress,
  }) : _quote = quote;

  final PegarouteValidatedQuote _quote;
  final String requestJson;
  final String routeSnapshotJson;
  final String quoteId;
  final DateTime quoteExpiresAt;
  final TradeExecutionExpiry? routeExpiry;
  final String tradeId;
  final String sourceChain;
  final String sourceToken;
  final String nativeToken;
  final String destinationChain;
  final String destinationToken;
  final String sourceAmount;
  final int sourceDecimals;
  final int destinationDecimals;
  final String walletId;
  final int? walletChainId;
  final String walletAddress;
  bool _consumed = false;

  bool isBoundTo(Object client) => _quote.isBoundTo(client);

  void consumeFor(Object client, DateTime at) {
    if (!isBoundTo(client)) {
      throw const PegarouteBindingException('swap preflight belongs to another API client');
    }
    if (_consumed) {
      throw const PegarouteBindingException('swap preflight has already been consumed');
    }
    final current = at.toUtc();
    if (!current.isBefore(quoteExpiresAt) ||
        (routeExpiry != null && !current.isBefore(routeExpiry!.instant()))) {
      throw const PegarouteBindingException('swap preflight is expired');
    }
    _consumed = true;
  }
}

final class PegarouteExecutionBindingValidator {
  const PegarouteExecutionBindingValidator({DateTime Function()? clock}) : _clock = clock;

  final DateTime Function()? _clock;

  DateTime get now => (_clock ?? DateTime.now)().toUtc();

  PegarouteValidatedSwapPreflight preflightSwap({
    required Trade trade,
    required WalletBase wallet,
    required PegarouteValidatedQuote quote,
    required PegarouteRoute route,
    required PegarouteSwapRequest request,
    DateTime? at,
  }) {
    final current = (at ?? now).toUtc();
    final quoteResponse = quote.response;
    final requestJson = jsonEncode(request.toJson());
    _validateQuotePreflight(quote: quoteResponse, route: route, request: request, at: current);
    if (quoteResponse.quoteId.trim().isEmpty || request.quoteId != quoteResponse.quoteId) {
      throw const PegarouteBindingException('request quote identity changed');
    }
    if (!_sameRequestBase(quote.requestJson, requestJson)) {
      throw const PegarouteBindingException('quote request provenance changed');
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
        trade.toAddressExtraId?.trim().isNotEmpty == true ||
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
      quote: quote,
      requestJson: requestJson,
      routeSnapshotJson: jsonEncode(_routeSnapshot(route)),
      quoteId: quoteResponse.quoteId,
      quoteExpiresAt: _parseDateTime(quoteResponse.expiresAt, 'quote expiry'),
      routeExpiry:
          route.expiry == null ? null : TradeExecutionExpiry.fromProviderValue(route.expiry),
      tradeId: trade.id,
      sourceChain: source.chain,
      sourceToken: source.token,
      nativeToken: source.nativeToken,
      destinationChain: destination.chain,
      destinationToken: destination.token,
      sourceAmount: request.amount,
      sourceDecimals: sourceDecimals,
      destinationDecimals: trade.to!.decimals,
      walletId: wallet.id,
      walletChainId: wallet.chainId,
      walletAddress: walletAddress,
    );
  }

  void validateQuotePreflight({
    required PegarouteValidatedQuote quote,
    required PegarouteRoute route,
    required PegarouteSwapRequest request,
    DateTime? at,
  }) {
    final requestJson = jsonEncode(request.toJson());
    _validateQuotePreflight(quote: quote.response, route: route, request: request, at: at ?? now);
    if (!_sameRequestBase(quote.requestJson, requestJson)) {
      throw const PegarouteBindingException('quote request provenance changed');
    }
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
        (route.privateValue?.isEnabled ?? false) ||
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

  TradeExecution bindSwapResponse({required PegarouteValidatedSwapResult result}) {
    try {
      return _bindSwapResponse(result);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        PegarouteSwapAttemptException(
          cause: error,
          userMessage:
              'Pegaroute created an order, but its execution could not be validated safely.',
        ),
        stackTrace,
      );
    }
  }

  TradeExecution _bindSwapResponse(PegarouteValidatedSwapResult result) {
    final preflight = result.preflight;
    final response = result.response;
    final reviewedRoute = _reviewedRoute(preflight.routeSnapshotJson);
    if (response.transactionId.trim().isEmpty ||
        response.provider.name != reviewedRoute['provider'] ||
        response.providerType != reviewedRoute['providerType'] ||
        !_sameRouteEchoFromSnapshot(reviewedRoute, response.route, null, true)) {
      throw const PegarouteBindingException('swap response route changed');
    }
    _validateProviderDetails(
      provider: response.provider,
      route: reviewedRoute,
      execution: response.execution,
      sourceChain: preflight.sourceChain,
      sourceAmount: preflight.sourceAmount,
    );
    _validateExecutionSemantics(
      execution: response.execution,
      sourceChain: preflight.sourceChain,
      sourceToken: preflight.sourceToken,
      nativeToken: preflight.nativeToken,
      walletChainId: preflight.walletChainId,
      sourceAmount: preflight.sourceAmount,
      sourceDecimals: preflight.sourceDecimals,
    );
    final sourceAmountBaseUnits = _toBaseUnits(preflight.sourceAmount, preflight.sourceDecimals);
    final execution = TradeExecution(
      family: response.execution.family,
      mode: response.execution.mode,
      sourceChain: preflight.sourceChain,
      sourceToken: preflight.sourceToken,
      nativeToken: preflight.nativeToken,
      destinationChain: preflight.destinationChain,
      destinationToken: preflight.destinationToken,
      routeProvider: reviewedRoute['provider'] as String,
      subprovider: reviewedRoute['subprovider'] as String?,
      privateIntent: reviewedRoute['private'],
      binding: TradeExecutionBinding(
        tradeId: preflight.tradeId,
        providerRaw: 17,
        quoteId: preflight.quoteId,
        quoteExpiresAt: preflight.quoteExpiresAt,
        routeExpiry: preflight.routeExpiry,
        providerTransactionId: response.transactionId.trim(),
        sourceAmount: preflight.sourceAmount,
        sourceAmountBaseUnits: sourceAmountBaseUnits,
        sourceDecimals: preflight.sourceDecimals,
        destinationDecimals: preflight.destinationDecimals,
        senderAddress: _requiredRequestField(preflight.requestJson, 'senderAddress'),
        refundAddress: _optionalRequestField(preflight.requestJson, 'refundAddress'),
        destinationAddress: _requiredRequestField(preflight.requestJson, 'destinationAddress'),
        isSendAll: false,
        walletId: preflight.walletId,
        walletChainId: preflight.walletChainId,
        walletAddress: preflight.walletAddress,
        reviewedRouteJson: preflight.routeSnapshotJson,
        providerReferenceId: response.provider.referenceId,
        providerDepositAddress: response.provider.instaswapSwapLite?.depositAddress,
        providerDepositAmountExact: response.provider.instaswapSwapLite?.depositAmountExact,
        providerDepositExpiry: _parseOptionalDateTime(
          response.provider.instaswapSwapLite?.expiresAt,
          'provider deposit expiry',
        ),
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
    if (trade.providerRaw != 17 ||
        trade.executionJson == null ||
        trade.executionJson!.isEmpty ||
        trade.toAddressExtraId?.trim().isNotEmpty == true) {
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
    if (execution.privateIntent != false) {
      throw const PegarouteBindingException('private Pegaroute execution is unavailable');
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
    if (!const DeepCollectionEquality().equals(
      reviewedRoute['expiry'],
      binding.routeExpiry?.toJson(),
    )) {
      throw const PegarouteBindingException('route expiry binding changed');
    }
    if (trade.walletId == null ||
        binding.walletId != trade.walletId ||
        (binding.walletChainId != null && trade.chainId != binding.walletChainId) ||
        !_sameAddress(execution.sourceChain, binding.walletAddress, binding.senderAddress) ||
        trade.fromWalletAddress == null ||
        !_sameAddress(execution.sourceChain, binding.walletAddress, trade.fromWalletAddress!)) {
      throw const PegarouteBindingException('wallet identity binding changed');
    }
    final source = _persistedAsset(
      _requiredCurrency(trade.from, 'source currency'),
      expectedChain: execution.sourceChain,
      expectedToken: execution.sourceToken,
      expectedNativeToken: execution.nativeToken,
      expectedDecimals: binding.sourceDecimals,
    );
    final destination = _persistedAsset(
      _requiredCurrency(trade.to, 'destination currency'),
      expectedChain: execution.destinationChain,
      expectedToken: execution.destinationToken,
      expectedDecimals: binding.destinationDecimals,
    );
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
    final providerExecution = _asProviderExecution(execution);
    _validatePersistedExecutableTerms(
      route: reviewedRoute,
      execution: providerExecution,
      sourceChain: execution.sourceChain,
      sourceAmount: binding.sourceAmount,
      providerDepositAddress: binding.providerDepositAddress,
      providerDepositAmountExact: binding.providerDepositAmountExact,
      providerDepositExpiry: binding.providerDepositExpiry,
    );
    _validateExecutionSemantics(
      execution: providerExecution,
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
    if (response.transactionId != (binding.providerTransactionId ?? binding.tradeId) ||
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
        !_validRefundEvidence(execution.sourceChain, binding, response)) {
      throw const PegarouteBindingException('status context does not match execution binding');
    }
    _validateStatusLifecycle(response);
    _validateStatusProviderDetails(
      binding: binding,
      response: response,
      sourceChain: execution.sourceChain,
    );
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

  PegarouteAssetId _persistedAsset(
    CryptoCurrency currency, {
    required String expectedChain,
    required String expectedToken,
    String? expectedNativeToken,
    int? expectedDecimals,
  }) {
    if (expectedToken.contains('-') && currency.runtimeType == CryptoCurrency) {
      throw const PegarouteBindingException('persisted qualified asset identity is unavailable');
    }
    final expected = _currencyMapper.validateCanonicalTuple(
      chain: expectedChain,
      token: expectedToken,
      nativeToken:
          expectedNativeToken ?? PegarouteCurrencyMapper.nativeTokenForChain(expectedChain),
    );
    try {
      final mapped = _currencyMapper.map(currency);
      if (mapped.chain != expected.chain ||
          mapped.token != expected.token ||
          mapped.nativeToken != expected.nativeToken ||
          expectedDecimals != null && currency.decimals != expectedDecimals) {
        throw const PegarouteBindingException('persisted asset binding changed');
      }
      return mapped;
    } on PegarouteCurrencyException {
      // SQLite restores qualified assets as generic currencies and drops the
      // contract or mint. Without that identity, accepting the row is unsafe.
      if (currency.runtimeType != CryptoCurrency) {
        throw const PegarouteBindingException('persisted typed asset identity is unavailable');
      }
      final symbol = expectedToken.split('-').first;
      if (currency.title.toUpperCase() != symbol.toUpperCase() ||
          expectedDecimals != null && currency.decimals != expectedDecimals ||
          _retainedChain(currency) != expectedChain ||
          expectedNativeToken != null &&
              PegarouteCurrencyMapper.nativeTokenForChain(expectedChain) != expectedNativeToken) {
        throw const PegarouteBindingException('persisted asset metadata changed');
      }
      return expected;
    }
  }

  static String? _retainedChain(CryptoCurrency currency) {
    final tag = currency.tag?.toUpperCase();
    return switch (tag) {
      'ETH' => 'ETH',
      'BSC' => 'BSC',
      'POL' => 'POLYGON',
      'AVAXC' => 'AVAX',
      'ARB' => 'ARBITRUM',
      'BASE' => 'BASE',
      'TRON' || 'TRX' => 'TRON',
      'SOL' => 'SOL',
      'XRP' => 'XRP',
      'CARDANO' || 'ADA' => 'CARDANO',
      'STELLAR' => 'STELLAR',
      'THOR' => 'THOR',
      _ => currency.title.toUpperCase(),
    };
  }

  static Map<String, dynamic> _payload(PegarouteExecution execution) => execution.toJson()
    ..remove('family')
    ..remove('mode');

  static bool _sameRequestBase(String quoteJson, String swapJson) {
    try {
      final quote = jsonDecode(quoteJson);
      final swap = jsonDecode(swapJson);
      if (quote is! Map || swap is! Map) return false;
      const fields = {
        'fromChain',
        'fromToken',
        'toChain',
        'toToken',
        'amount',
        'destinationAddress',
        'senderAddress',
        'refundAddress',
      };
      Map<String, dynamic> base(Object value) {
        final map = Map<String, dynamic>.from(value as Map);
        return {
          for (final field in fields)
            if (map.containsKey(field)) field: map[field],
        };
      }

      // Swap requests are public-only. An enabled quote intent must not
      // acquire a preflight even if a response incorrectly echoes public.
      return _samePrivate(quote['private'], swap['private']) &&
          const DeepCollectionEquality().equals(base(quote), base(swap)) &&
          base(quote).length == base(swap).length;
    } catch (_) {
      return false;
    }
  }

  static String _requiredRequestField(String requestJson, String field) {
    final value = _requestMap(requestJson)[field];
    if (value is! String || value.isEmpty) {
      throw const PegarouteBindingException('swap request is incomplete');
    }
    return value;
  }

  static String? _optionalRequestField(String requestJson, String field) {
    final value = _requestMap(requestJson)[field];
    if (value != null && value is! String) {
      throw const PegarouteBindingException('swap request is invalid');
    }
    return value as String?;
  }

  static Map<String, dynamic> _requestMap(String requestJson) {
    final value = jsonDecode(requestJson);
    if (value is! Map) throw const PegarouteBindingException('swap request is invalid');
    return Map<String, dynamic>.from(value);
  }

  static void _validateProviderDetails({
    required PegarouteProviderInfo provider,
    required Map<String, dynamic> route,
    required PegarouteExecution execution,
    required String sourceChain,
    required String sourceAmount,
  }) {
    final details = provider.instaswapSwapLite;
    if (details != null) {
      if (provider.referenceId == null || details.txid != provider.referenceId) {
        throw const PegarouteBindingException('provider reference details changed');
      }
      if (details.depositAmountExact != null && details.depositAmountExact != sourceAmount) {
        throw const PegarouteBindingException('provider deposit amount changed');
      }
      if (execution.to == null ||
          !_sameAddress(sourceChain, execution.to!, details.depositAddress)) {
        throw const PegarouteBindingException('provider deposit target changed');
      }
      if (details.presentFields.contains('expiresAt')) {
        _parseOptionalDateTime(details.expiresAt, 'provider deposit expiry');
      }
      final inbound = route['inboundAddress'];
      if (inbound is String &&
          inbound.isNotEmpty &&
          !_sameAddress(sourceChain, inbound, details.depositAddress)) {
        throw const PegarouteBindingException('provider deposit address changed');
      }
    }
    final expectedTarget = _expectedTarget(
      route,
      execution,
      providerDepositAddress: details?.depositAddress,
    );
    if (expectedTarget == null ||
        execution.to == null ||
        !_sameAddress(sourceChain, execution.to!, expectedTarget)) {
      throw const PegarouteBindingException('execution destination is not reviewed');
    }
    final routeMemo = route['memo'];
    if ((routeMemo != null && routeMemo is! String) || execution.memo != routeMemo) {
      throw const PegarouteBindingException('execution memo is not reviewed');
    }
    if (execution.approval != null) {
      final router = route['router'];
      if (router is! String || !_sameAddress(sourceChain, execution.approval!.spender, router)) {
        throw const PegarouteBindingException('approval spender is not reviewed');
      }
    }
  }

  static void _validatePersistedExecutableTerms({
    required Map<String, dynamic> route,
    required PegarouteExecution execution,
    required String sourceChain,
    required String sourceAmount,
    required String? providerDepositAddress,
    required String? providerDepositAmountExact,
    required DateTime? providerDepositExpiry,
  }) {
    if (providerDepositAddress == null &&
        (providerDepositAmountExact != null || providerDepositExpiry != null)) {
      throw const PegarouteBindingException('provider deposit details are incomplete');
    }
    if (providerDepositAddress != null) {
      if (execution.to == null ||
          !_sameAddress(sourceChain, execution.to!, providerDepositAddress)) {
        throw const PegarouteBindingException('persisted provider deposit target changed');
      }
      final inbound = route['inboundAddress'];
      if (inbound is String &&
          inbound.isNotEmpty &&
          !_sameAddress(sourceChain, providerDepositAddress, inbound)) {
        throw const PegarouteBindingException('persisted provider deposit address changed');
      }
    }
    final expectedTarget = _expectedTarget(
      route,
      execution,
      providerDepositAddress: providerDepositAddress,
    );
    if (expectedTarget == null ||
        execution.to == null ||
        !_sameAddress(sourceChain, execution.to!, expectedTarget)) {
      throw const PegarouteBindingException('persisted execution destination is not reviewed');
    }
    final routeMemo = route['memo'];
    if ((routeMemo != null && routeMemo is! String) || execution.memo != routeMemo) {
      throw const PegarouteBindingException('persisted execution memo is not reviewed');
    }
    if (providerDepositAmountExact != null && providerDepositAmountExact != sourceAmount) {
      throw const PegarouteBindingException('persisted provider deposit amount changed');
    }
    if (execution.approval != null) {
      final router = route['router'];
      if (router is! String || !_sameAddress(sourceChain, execution.approval!.spender, router)) {
        throw const PegarouteBindingException('persisted approval spender is not reviewed');
      }
    }
  }

  static String? _expectedTarget(Map<String, dynamic> route, PegarouteExecution execution,
      {String? providerDepositAddress}) {
    final router = route['router'];
    final inbound = route['inboundAddress'];
    final providerDeposit = providerDepositAddress;
    if (execution.family == 'evm' &&
        execution.mode == 'contract-call' &&
        router is String &&
        router.isNotEmpty) return router;
    if (inbound is String && inbound.isNotEmpty) return inbound;
    if (providerDeposit != null && providerDeposit.isNotEmpty) return providerDeposit;
    if (router is String && router.isNotEmpty) return router;
    // OpenOcean supplies its concrete target at creation. Under the approved
    // trusted-provider model, bind that authenticated target with its calldata.
    if (route['provider'] == 'openocean' && execution.family == 'evm') return execution.to;
    return null;
  }

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
        if (sourceToken == nativeToken) {
          _requireAmount(execution.value, sourceAmount, expectedBaseUnits);
        } else {
          if (execution.value != null &&
              (execution.value!.display != '0' || execution.value!.baseUnits != '0')) {
            throw const PegarouteBindingException('native call value is not bound');
          }
          throw const PegarouteBindingException('token call debit is not proven');
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
    if (execution.mode == 'serialized-tx') {
      throw const PegarouteBindingException('opaque serialized execution is unavailable');
    }
    if (execution.family == 'other' && execution.chain != sourceChain) {
      throw const PegarouteBindingException('opaque execution chain changed');
    }
    _requireAmount(execution.amount, sourceAmount, expectedBaseUnits);
    if (execution.family == 'cosmos' &&
        sourceChain == 'THOR' &&
        execution.mode == 'msg-deposit' &&
        execution.asset != 'THOR.RUNE') {
      throw const PegarouteBindingException('Cosmos asset is not bound');
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
      'THOR' => 'cosmos',
      'XMR' || 'STELLAR' => 'other',
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

  static DateTime? _parseOptionalDateTime(Object? value, String field) {
    if (value == null) return null;
    if (value is! String) throw PegarouteBindingException('$field is invalid');
    return _parseDateTime(value, field);
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

  static bool _sameRouteEchoFromSnapshot(
      Map<String, dynamic> expected, PegarouteRoute actual, String? providerType,
      [bool requireIdentityFields = false]) {
    final echoed = _routeSnapshot(actual, providerType: providerType);
    const requiredIdentityFields = {
      'provider',
      'subprovider',
      'private',
      'expectedOutput',
      'fees',
      'estimatedTimeSeconds',
    };
    if (requireIdentityFields && !actual.presentFields.containsAll(requiredIdentityFields)) {
      return false;
    }
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
      if (key != 'providerType' && !actual.presentFields.contains(key)) continue;
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
        (map['providerType'] as String).isEmpty ||
        (map['subprovider'] != null && map['subprovider'] is! String) ||
        !_validSnapshotPrivate(map['private']) ||
        map['expectedOutput'] is! String ||
        (map['memo'] != null && map['memo'] is! String) ||
        (map['inboundAddress'] != null && map['inboundAddress'] is! String) ||
        (map['router'] != null && map['router'] is! String) ||
        (map['minAmount'] != null && map['minAmount'] is! String) ||
        (map['gasRate'] != null && map['gasRate'] is! String) ||
        !_validSnapshotEstimatedTime(map['estimatedTimeSeconds']) ||
        !_validSnapshotFees(map['fees']) ||
        !_validSnapshotExpiry(map['expiry']) ||
        !_validSnapshotResolvedFee(map['resolvedFee']) ||
        !_validSnapshotOpenOcean(map['openOceanRoute'])) {
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

  static bool _validSnapshotEstimatedTime(Object? value) =>
      value is num && value.isFinite && value >= 0;

  static bool _validSnapshotPrivate(Object? value) {
    if (value == null) return false;
    try {
      PegaroutePrivateValue(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool _validSnapshotFees(Object? value) {
    if (value == null) return true;
    if (value is! Map) return false;
    final map = Map<String, dynamic>.from(value);
    const keys = {
      'affiliate',
      'liquidity',
      'outbound',
      'subAffiliate',
      'total',
      'totalBps',
      'slippageBps',
    };
    return map.length == keys.length &&
        map.keys.every(keys.contains) &&
        _nullableSnapshotString(map['affiliate']) &&
        _nullableSnapshotString(map['liquidity']) &&
        _nullableSnapshotString(map['outbound']) &&
        _nullableSnapshotString(map['subAffiliate']) &&
        _nullableSnapshotString(map['total']) &&
        _nullableSnapshotNum(map['totalBps']) &&
        _nullableSnapshotNum(map['slippageBps']);
  }

  static bool _validSnapshotExpiry(Object? value) {
    if (value == null) return true;
    try {
      final expiry = TradeExecutionExpiry.fromJson(value);
      return const DeepCollectionEquality().equals(expiry.toJson(), value);
    } catch (_) {
      return false;
    }
  }

  static bool _validSnapshotResolvedFee(Object? value) => value == null || _validJsonValue(value);

  static bool _validSnapshotOpenOcean(Object? value) {
    if (value == null) return true;
    if (value is! Map) return false;
    final map = Map<String, dynamic>.from(value);
    const keys = {'dexId', 'dexCode', 'dexes'};
    if (map.length != keys.length || map.keys.any((key) => !keys.contains(key))) return false;
    if (map['dexId'] != null && map['dexId'] is! int) return false;
    if (!_nullableSnapshotString(map['dexCode'])) return false;
    final dexes = map['dexes'];
    if (dexes == null) return true;
    if (dexes is! List) return false;
    return dexes.every((item) {
      if (item is! Map) return false;
      final dex = Map<String, dynamic>.from(item);
      return dex.length == 2 &&
          dex.keys.every({'dexId', 'dexCode'}.contains) &&
          (dex['dexId'] == null || dex['dexId'] is int) &&
          _nullableSnapshotString(dex['dexCode']);
    });
  }

  static bool _validJsonValue(Object? value) {
    if (value == null || value is String || value is num || value is bool) return true;
    if (value is List) return value.every(_validJsonValue);
    if (value is Map) {
      return value.keys.every((key) => key is String) && value.values.every(_validJsonValue);
    }
    return false;
  }

  static bool _nullableSnapshotString(Object? value) => value == null || value is String;

  static bool _nullableSnapshotNum(Object? value) =>
      value == null || value is num && value.isFinite;

  static bool _sameProviderReference(
      TradeExecutionBinding binding, PegarouteStatusResponse response) {
    final inputReference = response.input.providerReferenceId;
    final providerReference = response.provider?.referenceId;
    if (inputReference != null && providerReference != null && inputReference != providerReference)
      return false;
    final observed = providerReference ?? inputReference;
    return observed == null ||
        binding.providerReferenceId != null && observed == binding.providerReferenceId;
  }

  static bool _validRefundEvidence(
      String sourceChain, TradeExecutionBinding binding, PegarouteStatusResponse response) {
    final refund = response.refund;
    if (refund == null) return true;
    // Configured intent is bound through input.refundAddress above. The
    // provider's observed recipient can differ (for example a VIN0 refund)
    // and must be retained as separate evidence, never as new funding intent.
    return refund.refundAddress.trim().isNotEmpty &&
        (_chainIdFor(sourceChain) == null ||
            RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(refund.refundAddress)) &&
        _canonicalChain(refund.chain) == _canonicalChain(sourceChain) &&
        refund.originalAmount == binding.sourceAmount &&
        _validRefundStatus(response);
  }

  static bool _validRefundStatus(PegarouteStatusResponse response) {
    final refund = response.refund;
    if (refund == null) return true;
    if (refund.status == 'completed') return response.internalStatus == 'refunded';
    return response.internalStatus != 'refunded' && response.internalStatus != 'completed';
  }

  static void _validateStatusLifecycle(PegarouteStatusResponse response) {
    final valid = switch (response.status) {
      'pending' => response.internalStatus == 'pending',
      'executing' => const {'submitted', 'executing', 'confirming'}.contains(response.internalStatus),
      'success' => response.internalStatus == 'completed',
      'fail' => const {'failed', 'refunded'}.contains(response.internalStatus),
      _ => false,
    };
    if (!valid) {
      throw const PegarouteBindingException('status lifecycle is contradictory');
    }
  }

  static void _validateStatusProviderDetails({
    required TradeExecutionBinding binding,
    required PegarouteStatusResponse response,
    required String sourceChain,
  }) {
    final locations = [
      response.input.instaswapSwapLite,
      response.provider?.instaswapSwapLite,
    ].whereType<PegarouteInstaswapSnapshot>().toList(growable: false);
    if (locations.length == 2 && !_sameProviderDetails(sourceChain, locations[0], locations[1])) {
      throw const PegarouteBindingException('status provider details conflict');
    }
    for (final details in locations) {
      if (binding.providerReferenceId == null ||
          binding.providerDepositAddress == null ||
          details.txid != binding.providerReferenceId ||
          !_sameAddress(sourceChain, details.depositAddress, binding.providerDepositAddress!)) {
        throw const PegarouteBindingException('status provider details are not bound');
      }
      if (details.presentFields.contains('depositAmountExact') &&
          (binding.providerDepositAmountExact == null ||
              details.depositAmountExact != binding.providerDepositAmountExact)) {
        throw const PegarouteBindingException('status provider details changed');
      }
      if (details.presentFields.contains('expiresAt') &&
          _parseOptionalDateTime(details.expiresAt, 'provider deposit expiry') !=
              binding.providerDepositExpiry) {
        throw const PegarouteBindingException('status provider details changed');
      }
    }
  }

  static bool _sameProviderDetails(
    String sourceChain,
    PegarouteInstaswapSnapshot first,
    PegarouteInstaswapSnapshot second,
  ) {
    if (first.txid != second.txid ||
        !_sameAddress(sourceChain, first.depositAddress, second.depositAddress)) return false;
    if (first.presentFields.contains('depositAmountExact') &&
        second.presentFields.contains('depositAmountExact') &&
        first.depositAmountExact != second.depositAmountExact) return false;
    if (first.presentFields.contains('expiresAt') && second.presentFields.contains('expiresAt')) {
      if (_parseOptionalDateTime(first.expiresAt, 'provider deposit expiry') !=
          _parseOptionalDateTime(second.expiresAt, 'provider deposit expiry')) return false;
    }
    return true;
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
        'expiry': route.expiry == null
            ? null
            : TradeExecutionExpiry.fromProviderValue(route.expiry).toJson(),
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

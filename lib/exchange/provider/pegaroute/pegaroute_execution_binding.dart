import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
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

final class PegarouteExecutionBindingValidator {
  const PegarouteExecutionBindingValidator({DateTime Function()? clock}) : _clock = clock;

  final DateTime Function()? _clock;

  DateTime get now => (_clock ?? DateTime.now)().toUtc();

  void validateQuotePreflight({
    required PegarouteQuoteResponse quote,
    required PegarouteRoute route,
    required PegarouteSwapRequest request,
    DateTime? at,
  }) {
    final current = (at ?? now).toUtc();
    final quoteExpiry = _parseDateTime(quote.expiresAt, 'quote expiry');
    if (!current.isBefore(quoteExpiry)) {
      throw const PegarouteBindingException('quote is expired');
    }
    if (!quote.routes.any((candidate) => _sameRoute(candidate, route))) {
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
    required Trade trade,
    required WalletBase wallet,
    required PegarouteQuoteResponse quote,
    required PegarouteRoute quotedRoute,
    required PegarouteSwapRequest request,
    required PegarouteSwapResponse response,
  }) {
    validateQuotePreflight(quote: quote, route: quotedRoute, request: request);
    final sourceCurrency = _requiredCurrency(trade.from, 'source currency');
    final source = _currencyMapper.map(sourceCurrency);
    if (trade.providerRaw != 17 ||
        trade.walletId != wallet.id ||
        trade.isSendAll == true ||
        trade.amount != request.amount ||
        trade.senderAddress != request.senderAddress ||
        trade.payoutAddress != request.destinationAddress ||
        !_sameOptionalAddress(
            source.chain, _normalizedRefund(trade, source.chain), request.refundAddress)) {
      throw const PegarouteBindingException('local swap context changed');
    }
    if (response.transactionId.trim() != trade.id || response.transactionId.trim().isEmpty) {
      throw const PegarouteBindingException('swap transaction identity changed');
    }
    if (response.route.provider != quotedRoute.provider ||
        response.route.subprovider != quotedRoute.subprovider ||
        !_samePrivate(response.route.privateValue?.value, quotedRoute.privateValue?.value)) {
      throw const PegarouteBindingException('swap route identity changed');
    }
    final destinationCurrency = _requiredCurrency(trade.to, 'destination currency');
    final destination = _currencyMapper.map(destinationCurrency);
    final sourceAmountBaseUnits = _toBaseUnits(request.amount, sourceCurrency.decimals);
    final execution = TradeExecution(
      family: response.execution.family,
      mode: response.execution.mode,
      sourceChain: source.chain,
      sourceToken: source.token,
      nativeToken: source.nativeToken,
      destinationChain: destination.chain,
      destinationToken: destination.token,
      routeProvider: response.route.provider,
      subprovider: response.route.subprovider,
      privateIntent: response.route.privateValue?.value,
      binding: TradeExecutionBinding(
        tradeId: trade.id,
        providerRaw: trade.providerRaw,
        quoteId: quote.quoteId,
        quoteExpiresAt: _parseDateTime(quote.expiresAt, 'quote expiry'),
        routeExpiry: quotedRoute.expiry == null
            ? null
            : TradeExecutionExpiry.fromProviderValue(quotedRoute.expiry),
        sourceAmount: request.amount,
        sourceAmountBaseUnits: sourceAmountBaseUnits,
        sourceDecimals: sourceCurrency.decimals,
        senderAddress: request.senderAddress!,
        refundAddress: request.refundAddress,
        destinationAddress: request.destinationAddress!,
        isSendAll: trade.isSendAll == true,
        walletId: wallet.id,
        walletChainId: wallet.chainId,
        walletAddress: wallet.walletAddresses.address,
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
    if (trade.walletId == null ||
        binding.walletId != trade.walletId ||
        (binding.walletChainId != null && trade.chainId != binding.walletChainId) ||
        (binding.walletAddress != null &&
            (trade.fromWalletAddress == null ||
                !_sameAddress(
                    execution.sourceChain, binding.walletAddress!, trade.fromWalletAddress!)))) {
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
    if (trade.providerName != null && trade.providerName != execution.routeProvider) {
      throw const PegarouteBindingException('route provider binding changed');
    }
    if (binding.providerReferenceId != null && binding.providerReferenceId != trade.providerId) {
      throw const PegarouteBindingException('provider reference binding changed');
    }
    if (wallet != null) {
      if (wallet.id != binding.walletId ||
          (binding.walletChainId != null && wallet.chainId != binding.walletChainId) ||
          (binding.walletAddress != null &&
              !_sameAddress(
                  execution.sourceChain, binding.walletAddress!, wallet.walletAddresses.address))) {
        throw const PegarouteBindingException('active wallet binding changed');
      }
    }
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
        response.route.provider != execution.routeProvider ||
        response.route.subprovider != execution.subprovider ||
        !_samePrivate(response.route.privateValue?.value, execution.privateIntent)) {
      throw const PegarouteBindingException('status context does not match execution binding');
    }
    if (response.provider?.name != null && response.provider!.name != execution.routeProvider) {
      throw const PegarouteBindingException('status provider does not match execution binding');
    }
    if (binding.providerReferenceId != null &&
        response.input.providerReferenceId != null &&
        response.input.providerReferenceId != binding.providerReferenceId) {
      throw const PegarouteBindingException('status provider reference changed');
    }
    if (response.route.expiry != null) {
      TradeExecutionExpiry.fromProviderValue(response.route.expiry).instant();
    }
    final providerExpiry = response.input.instaswapSwapLite?.expiresAt;
    if (providerExpiry != null) _parseDateTime(providerExpiry, 'provider expiry');
    if (response.execution != null &&
        !const DeepCollectionEquality().equals(_payload(response.execution!), execution.payload)) {
      throw const PegarouteBindingException('status execution changed');
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
    final folded = const {'ETH', 'BSC', 'POLYGON', 'AVAX', 'ARBITRUM', 'BASE', 'SUI'};
    return folded.contains(chain.toUpperCase()) ? a.toLowerCase() == b.toLowerCase() : a == b;
  }

  static bool _samePrivate(Object? first, Object? second) {
    return (first ?? false) == (second ?? false);
  }

  static String _canonicalChain(String chain) => chain.trim().toUpperCase();

  static bool _sameRoute(PegarouteRoute first, PegarouteRoute second) {
    return first.provider == second.provider &&
        first.subprovider == second.subprovider &&
        first.privateValue?.value == second.privateValue?.value &&
        first.providerType == second.providerType &&
        first.expectedOutput == second.expectedOutput &&
        first.memo == second.memo &&
        first.inboundAddress == second.inboundAddress &&
        first.router == second.router &&
        first.minAmount == second.minAmount &&
        first.gasRate == second.gasRate &&
        first.expiry.toString() == second.expiry.toString();
  }

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

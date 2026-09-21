import 'dart:convert';

import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_currency_mapper.dart';
import 'package:collection/collection.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/format_fixed.dart';

enum PegarouteReceiveEstimateFailure {
  invalidAmount,
  invalidMetadata,
  privateIntent,
  noRoute,
  routeChanged,
  invalidQuote,
  staleQuote,
  nonMonotonic,
  noSolution,
  budgetExceeded,
}

final class PegarouteReceiveEstimateException implements Exception {
  const PegarouteReceiveEstimateException(this.reason);

  final PegarouteReceiveEstimateFailure reason;

  @override
  String toString() => 'Pegaroute receive estimate unavailable: ${reason.name}';
}

/// Numerical search limits, not provider order, slippage or funding guarantees.
final class PegarouteReceiveEstimatePolicy {
  const PegarouteReceiveEstimatePolicy({
    this.maxRequests = 4,
    this.timeBudget = const Duration(seconds: 6),
    this.maxOvershootBps = 10,
  });

  final int maxRequests;
  final Duration timeBudget;

  /// Accept only an observed output at least the target and at most this much
  /// above it (with a minimum tolerance of one destination base unit).
  final int maxOvershootBps;

  void _validate() {
    // Keep the entire solve below the exchange VM's seven-second timeout, even
    // when a caller tightens the defaults for interactive use or testing.
    if (maxRequests < 1 ||
        maxRequests > 4 ||
        timeBudget <= Duration.zero ||
        timeBudget > const Duration(seconds: 6) ||
        maxOvershootBps < 0 ||
        maxOvershootBps > 100) {
      throw ArgumentError('invalid Pegaroute receive estimate budget');
    }
  }
}

/// An observed forward quote used to estimate the input for a receive target.
///
/// This is neither an exact-output order nor a fixed-rate guarantee. It does not
/// authorize creation or funding. The final [quote] retains API provenance and
/// the exact forward request; future UI must review fresh terms before creation.
final class PegarouteReceiveAmountEstimate {
  const PegarouteReceiveAmountEstimate._({
    required this.quote,
    required this.request,
    required this.route,
    required this.sourceAsset,
    required this.destinationAsset,
    required this.sourceDecimals,
    required this.destinationDecimals,
    required this.requestedReceiveAmount,
    required this.sourceAmount,
    required this.expectedOutput,
    required this.observedAt,
    required this.quoteExpiresAt,
    required this.requestCount,
  });

  final PegarouteValidatedQuote quote;
  final PegarouteQuoteRequest request;
  final PegarouteRoute route;
  final PegarouteAssetId sourceAsset;
  final PegarouteAssetId destinationAsset;
  final int sourceDecimals;
  final int destinationDecimals;
  final PegarouteTokenAmount requestedReceiveAmount;
  final PegarouteTokenAmount sourceAmount;
  final PegarouteTokenAmount expectedOutput;
  final DateTime observedAt;

  /// Earliest supplied quote/route expiry. This is not a deposit deadline.
  final DateTime quoteExpiresAt;
  final int requestCount;

  bool get isEstimate => true;
  bool get isGuaranteedFixedRate => false;
  String get provider => route.provider;

  /// Same convention as ChangeNow/Trocador reverse fetchRate: target / input,
  /// so target / rate yields the estimated input. The actual observed output
  /// can be slightly higher; it is preserved separately in [expectedOutput].
  /// Doubles are only used at this legacy presentation boundary.
  double get rate {
    final value = double.parse(requestedReceiveAmount.display) / double.parse(sourceAmount.display);
    return value.isFinite && value > 0 ? value : 0;
  }
}

/// A bounded secant search over fresh forward quotes from one selected route.
/// No quote, error or candidate is cached across solves.
///
/// The first probe is one native coin or 100 token units unless a trusted caller
/// supplies [estimate]'s initialSourceAmount. These are search seeds, not limits.
/// A returned provider minimum is rounded up to a source base unit. The public
/// quote contract exposes no maximum: provider errors stop the search, and an
/// optional caller maximum bounds candidates without inventing provider limits.
/// Convergence, global monotonicity and the cheapest possible input are not
/// guaranteed; success always requires an actual in-band forward observation.
final class PegarouteReceiveAmountEstimator {
  PegarouteReceiveAmountEstimator({
    required this.apiClient,
    this.policy = const PegarouteReceiveEstimatePolicy(),
    this.isRouteAllowed,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PegarouteApiClient apiClient;
  final PegarouteReceiveEstimatePolicy policy;
  final bool Function(PegarouteRoute)? isRouteAllowed;
  final DateTime Function() _clock;
  static const _mapper = PegarouteCurrencyMapper();

  Future<PegarouteReceiveAmountEstimate> estimate({
    required CryptoCurrency from,
    required CryptoCurrency to,
    required String receiveAmount,
    String? initialSourceAmount,
    String? maxSourceAmount,
    PegarouteAddressIntent? intent,
    PegaroutePrivateValue? privateValue,
  }) async {
    policy._validate();
    final elapsed = Stopwatch()..start();
    final source = _mapper.map(from);
    final destination = _mapper.map(to);
    if (!PegarouteCurrencyMapper.quoteSourceChains.contains(source.chain)) {
      throw const PegarouteUnavailableException();
    }
    if (privateValue?.isEnabled ?? false) _fail(PegarouteReceiveEstimateFailure.privateIntent);
    final sourceDecimals = _decimals(from, source);
    final destinationDecimals = _decimals(to, destination);
    final target = _units(receiveAmount, destinationDecimals);
    var candidate = _units(
      initialSourceAmount ?? (source.token == source.nativeToken ? '1' : '100'),
      sourceDecimals,
    );
    final maximum = maxSourceAmount == null ? null : _units(maxSourceAmount, sourceDecimals);
    final tolerance = _clamp(
      target * BigInt.from(policy.maxOvershootBps) ~/ BigInt.from(10000),
      BigInt.one,
      target,
    );
    final samples = <_Observation>[];
    final quoteIds = <String>{};
    PegarouteRoute? selected;
    DateTime? earliestExpiry;

    Duration remaining() {
      final value = policy.timeBudget - elapsed.elapsed;
      if (value <= Duration.zero) _fail(PegarouteReceiveEstimateFailure.budgetExceeded);
      if (earliestExpiry != null && !_clock().toUtc().isBefore(earliestExpiry)) {
        _fail(PegarouteReceiveEstimateFailure.staleQuote);
      }
      return value;
    }

    for (var count = 1; count <= policy.maxRequests; count++) {
      remaining();
      if (candidate <= BigInt.zero ||
          candidate.toString().length > 100 ||
          maximum != null && candidate > maximum ||
          samples.any((sample) => sample.input == candidate)) {
        _fail(PegarouteReceiveEstimateFailure.noSolution);
      }
      final request = PegarouteQuoteRequest(
        fromChain: source.chain,
        fromToken: source.token,
        toChain: destination.chain,
        toToken: destination.token,
        amount: formatFixed(candidate, sourceDecimals),
        destinationAddress: intent?.destinationAddress,
        senderAddress: intent?.senderAddress,
        refundAddress: intent?.refundAddress,
        privateValue: privateValue,
      );
      // Timeout the awaited request, not the whole loop. A late transport may
      // finish, but it cannot resume this search or start another GET.
      final requestBudget = remaining();
      final quote = await apiClient.quote(request).timeout(
            requestBudget,
            onTimeout: () => _fail(PegarouteReceiveEstimateFailure.budgetExceeded),
          );
      remaining();
      if (!quote.isBoundTo(apiClient) ||
          !quoteIds.add(quote.response.quoteId) ||
          !const DeepCollectionEquality().equals(jsonDecode(quote.requestJson), {
            ...request.toQuery(),
            'private': privateValue?.value ?? false,
          })) {
        _fail(PegarouteReceiveEstimateFailure.invalidQuote);
      }
      final now = _clock().toUtc();
      final quoteExpiry = _expiry(quote.response.expiresAt);
      if (!now.isBefore(quoteExpiry)) _fail(PegarouteReceiveEstimateFailure.staleQuote);
      final routes = quote.response.routes.where((route) =>
          !(route.privateValue?.isEnabled ?? false) &&
          (isRouteAllowed?.call(route) ?? true) &&
          (source.chain != 'XMR' || route.memo == null));
      PegarouteRoute? route;
      if (selected != null) {
        final matches = routes.where((route) => route.provider == selected!.provider).toList();
        if (matches.length != 1 || !_sameRouteIdentity(selected, matches.single)) {
          _fail(PegarouteReceiveEstimateFailure.routeChanged);
        }
        route = matches.single;
      } else {
        BigInt? best;
        var bestIsWithinMinimum = false;
        for (final option in routes) {
          final output = _units(option.expectedOutput, destinationDecimals, allowZero: true);
          final minimum = _minimum(option, sourceDecimals);
          final withinMinimum = candidate >= minimum;
          if (output == BigInt.zero && withinMinimum) continue;
          if (option.expiry != null && !now.isBefore(_expiry(option.expiry!))) continue;
          if (route == null ||
              withinMinimum && !bestIsWithinMinimum ||
              withinMinimum == bestIsWithinMinimum && output > best!) {
            route = option;
            best = output;
            bestIsWithinMinimum = withinMinimum;
          }
        }
        if (route == null) _fail(PegarouteReceiveEstimateFailure.noRoute);
        if (routes.where((option) => option.provider == route!.provider).length != 1) {
          _fail(PegarouteReceiveEstimateFailure.invalidQuote);
        }
        selected = route;
      }
      final routeExpiry = route.expiry == null ? quoteExpiry : _expiry(route.expiry!);
      final expiresAt = routeExpiry.isBefore(quoteExpiry) ? routeExpiry : quoteExpiry;
      if (!now.isBefore(expiresAt)) _fail(PegarouteReceiveEstimateFailure.staleQuote);
      if (earliestExpiry == null || expiresAt.isBefore(earliestExpiry)) earliestExpiry = expiresAt;
      final minimum = _minimum(route, sourceDecimals);
      if (candidate < minimum) {
        // Do not interpolate using an input that the provider says is too low.
        candidate = minimum;
        continue;
      }
      final output = _units(route.expectedOutput, destinationDecimals);
      for (final sample in samples) {
        if ((candidate - sample.input).sign != (output - sample.output).sign) {
          _fail(PegarouteReceiveEstimateFailure.nonMonotonic);
        }
      }
      samples.add(_Observation(candidate, output));
      if (output >= target && output - target <= tolerance) {
        remaining();
        return PegarouteReceiveAmountEstimate._(
          quote: quote,
          request: request,
          route: route,
          sourceAsset: source,
          destinationAsset: destination,
          sourceDecimals: sourceDecimals,
          destinationDecimals: destinationDecimals,
          requestedReceiveAmount: _amount(target, destinationDecimals),
          sourceAmount: _amount(candidate, sourceDecimals),
          expectedOutput: _amount(output, destinationDecimals),
          observedAt: now,
          quoteExpiresAt: expiresAt,
          requestCount: count,
        );
      }
      // Aim inside the permitted observation band, rather than repeatedly
      // approaching its lower edge from below on a nonlinear/slippage curve.
      candidate = _nextCandidate(samples, target + tolerance ~/ BigInt.two);
      if (candidate < minimum) candidate = minimum;
    }
    _fail(PegarouteReceiveEstimateFailure.noSolution);
  }

  static int _decimals(CryptoCurrency currency, PegarouteAssetId asset) {
    final decimals = currency.decimals;
    if (decimals < 0 || decimals > 36) _fail(PegarouteReceiveEstimateFailure.invalidMetadata);
    // Never substitute provider API precision for native precision. Cross-check
    // Cake's canonical currencies where available; other qualified token objects
    // must come from the caller's trusted wallet token metadata, not /quote.
    for (final known in CryptoCurrency.all) {
      PegarouteAssetId mapped;
      try {
        mapped = _mapper.map(known);
      } on PegarouteCurrencyException {
        continue;
      }
      if (mapped.chain == asset.chain &&
          mapped.token == asset.token &&
          known.decimals != decimals) {
        _fail(PegarouteReceiveEstimateFailure.invalidMetadata);
      }
    }
    return decimals;
  }
}

final class _Observation {
  const _Observation(this.input, this.output);
  final BigInt input;
  final BigInt output;
}

BigInt _nextCandidate(List<_Observation> samples, BigInt target) {
  final latest = samples.last;
  if (samples.length == 1) return _ceilDivide(latest.input * target, latest.output);
  final sorted = samples.toList()..sort((a, b) => a.input.compareTo(b.input));
  final below = sorted.where((sample) => sample.output < target).lastOrNull;
  final above = sorted.where((sample) => sample.output > target).firstOrNull;
  final _Observation low;
  final _Observation high;
  if (below != null && above != null) {
    low = below;
    high = above;
  } else if (below != null) {
    low = sorted[sorted.length - 2];
    high = sorted.last;
  } else {
    low = sorted.first;
    high = sorted[1];
  }
  var next = low.input +
      _ceilDivide((target - low.output) * (high.input - low.input), high.output - low.output);
  if (below != null && above != null) {
    if (high.input - low.input <= BigInt.one) _fail(PegarouteReceiveEstimateFailure.noSolution);
    next = _clamp(next, low.input + BigInt.one, high.input - BigInt.one);
  }
  return next;
}

BigInt _ceilDivide(BigInt numerator, BigInt denominator) => numerator.isNegative
    ? numerator ~/ denominator
    : (numerator + denominator - BigInt.one) ~/ denominator;

BigInt _clamp(BigInt value, BigInt lower, BigInt upper) =>
    value < lower ? lower : (value > upper ? upper : value);

BigInt _units(String value, int decimals, {bool allowZero = false, bool roundUp = false}) {
  if (value.length > 100 || !RegExp(r'^(0|[1-9][0-9]*)(\.[0-9]+)?$').hasMatch(value)) {
    _fail(PegarouteReceiveEstimateFailure.invalidAmount);
  }
  final parts = value.split('.');
  final fraction = parts.length == 2 ? parts[1] : '';
  final discarded = fraction.length > decimals ? fraction.substring(decimals) : '';
  final remainder = discarded.contains(RegExp('[1-9]'));
  if (remainder && !roundUp) _fail(PegarouteReceiveEstimateFailure.invalidAmount);
  final retained = fraction.padRight(decimals, '0').substring(0, decimals);
  final units = BigInt.parse('${parts[0]}$retained') + (remainder ? BigInt.one : BigInt.zero);
  if (!allowZero && units == BigInt.zero) _fail(PegarouteReceiveEstimateFailure.invalidAmount);
  return units;
}

BigInt _minimum(PegarouteRoute route, int decimals) => route.minAmount == null
    ? BigInt.one
    : _units(route.minAmount!, decimals, allowZero: true, roundUp: true);

PegarouteTokenAmount _amount(BigInt units, int decimals) =>
    PegarouteTokenAmount(display: formatFixed(units, decimals), baseUnits: units.toString());

DateTime _expiry(Object value) {
  // Route expiry can be Unix seconds (including an integer string). The quote's
  // expiresAt is ISO-8601. Never interpret a numeric string as a calendar year.
  if (value is num && value.isFinite && value >= 0 && value <= 8640000000000) {
    return DateTime.fromMillisecondsSinceEpoch((value * 1000).floor(), isUtc: true);
  }
  if (value is String && RegExp(r'^[0-9]+$').hasMatch(value)) {
    final seconds = BigInt.tryParse(value.toString());
    if (seconds != null && seconds >= BigInt.zero && seconds <= BigInt.from(8640000000000)) {
      return DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000, isUtc: true);
    }
  } else if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null && parsed.isUtc) return parsed;
  }
  _fail(PegarouteReceiveEstimateFailure.invalidQuote);
}

bool _sameRouteIdentity(PegarouteRoute first, PegarouteRoute next) {
  // Output, minimum, fee amounts, memo (which can contain min-output) and
  // expiry can legitimately vary with input. Preserve them in the final quote;
  // this identity check is not semantic execution/order authorization.
  // Informational subprovider/DEX labels may appear or change between quotes.
  return first.provider == next.provider &&
      first.providerType == next.providerType &&
      first.inboundAddress == next.inboundAddress &&
      first.router == next.router &&
      const DeepCollectionEquality().equals(first.resolvedFee, next.resolvedFee);
}

Never _fail(PegarouteReceiveEstimateFailure reason) =>
    throw PegarouteReceiveEstimateException(reason);

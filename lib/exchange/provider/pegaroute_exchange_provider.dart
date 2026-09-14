import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/limits.dart';
import 'package:cake_wallet/exchange/provider/exchange_provider.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_capability_gate.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_currency_mapper.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_handler_support.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_lifecycle_store.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_native_eth.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_trusted_execution.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_provider_preferences.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cake_wallet/exchange/trade_execution_lifecycle.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_receive_amount_estimator.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_not_found_exception.dart';
import 'package:cake_wallet/exchange/trade_refund.dart';
import 'package:cake_wallet/exchange/trade_request.dart';
import 'package:cake_wallet/exchange/trade_state.dart';
import 'package:cake_wallet/utils/token_utilities.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/db/sqlite.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/exceptions.dart';
import 'package:cw_core/spl_token.dart';
import 'package:cw_core/tron_token.dart';
import 'package:cw_core/utils/print_verbose.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:uuid/uuid.dart';

enum _PegarouteTransition { stale, same, advance }

final class _PegarouteStatusSource {
  const _PegarouteStatusSource({
    required this.internalId,
    required this.id,
    required this.providerRaw,
    required this.rawExecutionJson,
  });

  final int internalId;
  final String id;
  final int providerRaw;
  final String rawExecutionJson;
}

final class _PegarouteStatusObservation {
  const _PegarouteStatusObservation({
    required this.source,
    required this.response,
    required this.trade,
  });

  final _PegarouteStatusSource source;
  final PegarouteStatusResponse response;
  final Trade trade;
}

/// Read-only status data for callers that need to inspect a provider result
/// without receiving a writable Trade that could replace the bound row.
final class PegarouteTradeStatusSnapshot {
  const PegarouteTradeStatusSnapshot({
    required this.id,
    required this.providerId,
    required this.refundJson,
  });

  final String id;
  final String? providerId;
  final String? refundJson;
}

class PegarouteExchangeProvider extends ExchangeProvider {
  PegarouteExchangeProvider({
    PegarouteApiClient? apiClient,
    PegarouteConfiguration? configuration,
    PegarouteCapabilityGate? capabilityGate,
    PegarouteReceiveEstimatePolicy receiveEstimatePolicy = const PegarouteReceiveEstimatePolicy(),
    DateTime Function()? quoteClock,
    this.currentWallet,
    this.providerPreferences,
    this.decentralizedOnly,
    this.executableQuotesOnly = false,
    Future<CryptoCurrency?> Function(String? chain, String? token)? currencyLookup,
  })  : _apiClient = apiClient ?? PegarouteApiClient(configuration: configuration),
        _receiveEstimatePolicy = receiveEstimatePolicy,
        _quoteClock = quoteClock,
        _currencyLookup = currencyLookup;

  final PegarouteApiClient _apiClient;
  final WalletBase? Function()? currentWallet;
  final PegarouteProviderPreferences? providerPreferences;
  final bool Function()? decentralizedOnly;

  /// Cake's exchange comparison uses fundable routes. Read-only discovery can
  /// still query the broader catalog independently of wallet execution support.
  final bool executableQuotesOnly;
  final PegarouteReceiveEstimatePolicy _receiveEstimatePolicy;
  final DateTime Function()? _quoteClock;
  final Future<CryptoCurrency?> Function(String? chain, String? token)? _currencyLookup;
  final PegarouteCurrencyMapper _currencyMapper = const PegarouteCurrencyMapper();
  final PegarouteExecutionBindingValidator _bindingValidator =
      const PegarouteExecutionBindingValidator();

  @override
  String get title => 'Pegaroute';

  // Quote discovery covers catalog assets; funding uses supported Cake wallet operations.
  @override
  bool get isAvailable => _apiClient.configuration.isValid;

  bool get isExecutionAvailable =>
      isAvailable &&
      PegarouteProviderPreferences.providers.keys.any(_providerAllowed) &&
      pegarouteTrustedWallet(currentWallet?.call());

  @override
  bool get isEnabled => isAvailable;

  @override
  bool get supportsFixedRate => false;

  @override
  bool get supportsReceiveAmountEstimate => true;

  @override
  bool get supportsMemoOrDestinationTag => false;

  @override
  bool get createsOrderBeforeReturning => true;

  @override
  ExchangeProviderDescription get description => ExchangeProviderDescription.pegaroute;

  @override
  Future<bool> checkIsAvailable() async => isAvailable;

  @override
  Future<Limits?> fetchLimits({
    required CryptoCurrency from,
    required CryptoCurrency to,
    required bool isFixedRateMode,
  }) async {
    if (isFixedRateMode) return null;
    final assets = _quoteAssets(from, to);
    if (assets == null) return null;
    try {
      final quote = await _apiClient.quote(
        PegarouteQuoteRequest(
          fromChain: assets.first.chain,
          fromToken: assets.first.token,
          toChain: assets.last.chain,
          toToken: assets.last.token,
          amount: '1',
        ),
      );
      final routes = quote.response.routes
          .where((route) => _isQuoteRouteEligible(route, assets.first))
          .toList();
      if (routes.isEmpty || _quoteAssets(from, to) == null) return null;
      final minimums = routes
          .map((route) => double.tryParse(route.minAmount ?? ''))
          .whereType<double>()
          .where((amount) => amount.isFinite && amount >= 0)
          .toList(growable: false);
      return Limits(
        min: minimums.isEmpty ? 0 : minimums.reduce((a, b) => a < b ? a : b),
        max: null,
      );
    } catch (error) {
      _logQuoteFailure(error);
      return null;
    }
  }

  @override
  Future<double> fetchRate({
    required CryptoCurrency from,
    required CryptoCurrency to,
    required double amount,
    required bool isFixedRateMode,
    required bool isReceiveAmount,
  }) async {
    if (amount <= 0 || !amount.isFinite || isFixedRateMode) return 0;
    final assets = _quoteAssets(from, to);
    if (assets == null) return 0;
    try {
      if (isReceiveAmount) {
        return (await estimateReceiveAmount(
          from: from,
          to: to,
          receiveAmount: _receiveDecimalAmount(amount),
        ))
            .rate;
      }
      final quote = await _apiClient.quote(
        PegarouteQuoteRequest(
          fromChain: assets.first.chain,
          fromToken: assets.first.token,
          toChain: assets.last.chain,
          toToken: assets.last.token,
          amount: _decimalAmount(amount),
        ),
      );
      var bestOutput = 0.0;
      if (_quoteAssets(from, to) == null) return 0;
      for (final route in quote.response.routes) {
        if (!_isQuoteRouteEligible(route, assets.first)) continue;
        final output = double.tryParse(route.expectedOutput);
        if (output != null && output.isFinite && output > bestOutput) bestOutput = output;
      }
      return bestOutput == 0 ? 0 : bestOutput / amount;
    } catch (error) {
      _logQuoteFailure(error);
      return 0;
    }
  }

  /// Read-only estimate retaining the final forward quote and exact candidate.
  /// Callers supply trusted wallet token metadata and decimal strings here;
  /// [fetchRate] is only a lossy, legacy presentation adapter.
  Future<PegarouteReceiveAmountEstimate> estimateReceiveAmount({
    required CryptoCurrency from,
    required CryptoCurrency to,
    required String receiveAmount,
    String? initialSourceAmount,
    String? maxSourceAmount,
    PegarouteAddressIntent? intent,
    PegaroutePrivateValue? privateValue,
  }) async {
    // Preserve the estimator API's typed metadata failures before eligibility.
    _currencyMapper.map(from);
    _currencyMapper.map(to);
    final assets = _quoteAssets(from, to);
    if (assets == null) throw const PegarouteUnavailableException();
    return PegarouteReceiveAmountEstimator(
      apiClient: _apiClient,
      policy: _receiveEstimatePolicy,
      clock: _quoteClock,
      isRouteAllowed: (route) =>
          _quoteAssets(from, to) != null && _isQuoteRouteEligible(route, assets.first),
    ).estimate(
      from: from,
      to: to,
      receiveAmount: receiveAmount,
      initialSourceAmount: initialSourceAmount,
      maxSourceAmount: maxSourceAmount,
      intent: intent,
      privateValue: privateValue,
    );
  }

  // This proves principal affordability only. Transaction-specific gas and
  // approval checks still run against the returned execution before funding.
  void _requireSourceBalance({
    required WalletBase wallet,
    required CryptoCurrency currency,
    required PegarouteAssetId source,
    required String amount,
  }) {
    final required = Money.parse(amount, currency);
    final balances = wallet.balance.entries
        .where((entry) => _currencyMapper.matchesCanonicalTuple(entry.key, source))
        .toList();
    if (balances.length != 1) throw const PegarouteUnavailableException();
    final Money available = balances.single.value.available;
    final balanceCurrency = available.currency;
    if (balanceCurrency is! CryptoCurrency ||
        !_currencyMapper.matchesCanonicalTuple(balanceCurrency, source) ||
        balances.single.key.decimals != currency.decimals ||
        available.decimals != currency.decimals) {
      throw const PegarouteBindingException('Funding balance does not match the source asset');
    }
    final sourceAvailable = available.copyWith(currency: currency);
    if (required > sourceAvailable) {
      throw TransactionWrongBalanceException(currency,
          requiredBalance: required, availableBalance: sourceAvailable);
    }
  }

  @override
  Future<Trade> createTrade({
    required TradeRequest request,
    required bool isFixedRateMode,
    required bool isSendAll,
  }) async {
    final source = _currencyMapper.map(request.fromCurrency);
    final destination = _currencyMapper.map(request.toCurrency);
    final wallet = currentWallet?.call();
    if (!isExecutionAvailable ||
        wallet == null ||
        !pegarouteTrustedSource(wallet, source) ||
        isFixedRateMode ||
        request.isFixedRate ||
        isSendAll ||
        request.toAddressExtraId.isNotEmpty) {
      throw const PegarouteUnavailableException();
    }
    // Resolve catalog aliases before POST so token identities survive the
    // initial Trade save. Restored rows still require their original identity.
    final fromCurrency = _persistableCurrency(request.fromCurrency, source);
    final toCurrency = _persistableCurrency(request.toCurrency, destination);
    void checkSourceBalance() => _requireSourceBalance(
        wallet: wallet, currency: fromCurrency, source: source, amount: request.fromAmount);
    checkSourceBalance();
    final context =
        PegarouteActiveWalletContext(currentWallet!, supportsWallet: pegarouteTrustedWallet);
    final before = context.snapshot(wallet);
    void checkWallet() {
      if (!before.matches(context.snapshot(wallet))) {
        throw const PegarouteBindingException('The funding wallet changed during order creation');
      }
    }

    try {
      final intent = PegarouteAddressIntent(
        destinationAddress: request.toAddress,
        senderAddress: request.senderAddress,
        refundAddress: request.refundAddress,
      );
      final quote = await _apiClient.quote(PegarouteQuoteRequest.fromIntent(
        fromChain: source.chain,
        fromToken: source.token,
        toChain: destination.chain,
        toToken: destination.token,
        amount: request.fromAmount,
        intent: intent,
      ));
      checkWallet();
      final routes = quote.response.routes
          .where(
              (route) => _providerAllowed(route.provider) && pegarouteTrustedQuote(source, route))
          .toList()
        ..sort((a, b) => _compareOutput(b.expectedOutput, a.expectedOutput));
      if (routes.isEmpty) throw const PegarouteUnavailableException();
      final route = routes.first;
      final trade = Trade(
        id: 'pegaroute-${const Uuid().v4()}',
        provider: description,
        providerName: route.provider,
        from: fromCurrency,
        to: toCurrency,
        amount: request.fromAmount,
        receiveAmount: route.expectedOutput,
        senderAddress: intent.senderAddress,
        refundAddress: intent.refundAddress,
        payoutAddress: intent.destinationAddress,
        walletId: wallet.id,
        chainId: wallet.chainId,
        fromWalletAddress: before.address,
        isSendAll: false,
        state: TradeState.created,
        createdAt: DateTime.now().toUtc(),
      );
      final preflight = _bindingValidator.preflightSwap(
        trade: trade,
        wallet: wallet,
        quote: quote,
        route: route,
        request: PegarouteSwapRequest.fromIntent(
          fromChain: source.chain,
          fromToken: source.token,
          toChain: destination.chain,
          toToken: destination.token,
          amount: request.fromAmount,
          intent: intent,
          quoteId: quote.response.quoteId,
          routeProvider: route.provider,
        ),
      );
      checkWallet();
      if (!_providerAllowed(route.provider)) throw const PegarouteUnavailableException();
      checkSourceBalance();
      final result = await _apiClient.swap(preflight);
      try {
        checkWallet();
        final execution = _bindingValidator.bindSwapResponse(result: result);
        if (!pegarouteTrustedExecution(execution)) {
          throw const PegarouteBindingException('Unsupported Pegaroute funding instructions');
        }
        trade.executionJson = execution.encode();
        trade.providerId = execution.binding.providerReferenceId;
        trade.inputAddress = execution.payload['to'] as String? ?? before.address;
        trade.expiredAt = execution.binding.providerDepositExpiry;
        final validated = _bindingValidator.validatePersisted(trade: trade, wallet: wallet);
        pegarouteRequireUnexpiredFunding(validated, DateTime.now().toUtc());
        return trade;
      } catch (error) {
        final failure = PegarouteSwapAttemptException(
            cause: error,
            providerTransactionId: result.response.transactionId,
            userMessage: 'Pegaroute order ${result.response.transactionId} was created, '
                'but Cake could not prepare its funding instructions.');
        printV('Pegaroute order ${failure.providerTransactionId}: ${failure.diagnosticMessage}');
        throw failure;
      }
    } finally {
      context.dispose();
    }
  }

  /// Broadcast has already succeeded. Notification failure must never request a
  /// second payment. A subsequent status poll confirms the stored source hash.
  Future<void> notifyCommitted(
    ValidatedTradeExecution execution,
    CommittedTradeExecution receipt,
  ) async {
    final trade = await Trade.getByTradeId(execution.execution.binding.tradeId);
    if (trade == null) throw const PegarouteBindingException('Bound trade is missing');
    _bindingValidator.validatePersisted(
        trade: trade, expectedRawExecutionJson: execution.rawExecutionJson);
    final lifecycle = TradeExecutionLifecycle.fromJsonString(trade.executionLifecycleJson!);
    final hash = receipt.evmTxHash ?? receipt.transactionId;
    final fundingIdentity = pegarouteFundingIdentity(execution.execution, hash);
    if (hash.isEmpty ||
        lifecycle.executionHash != fundingIdentity ||
        trade.txId != hash ||
        lifecycle.state != TradeExecutionLifecycleState.broadcasted) {
      throw const PegarouteBindingException('Broadcast hash is not bound');
    }
    if (lifecycle.callbackState == TradeExecutionCallbackState.accepted) return;
    await PegarouteExecutionLifecycleStore().markCallbackAttempted(
        execution: execution, executionHash: fundingIdentity, tradeInternalId: trade.internalId);
    await _apiClient.notifySourceHash(execution.execution.binding.providerTransactionId!, hash,
        chain: execution.execution.sourceChain);
    await refreshTradeStatus(trade: trade);
  }

  @override
  Future<Trade> findTradeById({required String id}) async {
    throw const PegarouteBindingException('Pegaroute status requires a bound trade context');
  }

  Future<PegarouteTradeStatusSnapshot> findTradeForContext({required Trade trade}) async {
    final source = _captureSource(trade);
    final observation = await _fetchStatus(trade: trade, source: source);
    return PegarouteTradeStatusSnapshot(
      id: observation.trade.id,
      providerId: observation.trade.providerId,
      refundJson: observation.trade.refundJson,
    );
  }

  /// Fetches and atomically persists one provider-owned Pegaroute status.
  ///
  /// The status response never crosses this boundary as a writable Trade
  /// update. Its response, raw execution identity, and source row identity
  /// stay together until the transaction has revalidated the latest row.
  Future<Trade> refreshTradeStatus({required Trade trade}) async {
    final source = _captureSource(trade, requirePersisted: true);
    final observation = await _fetchStatus(trade: trade, source: source);
    final committedSource = observation.source;

    late Trade committed;
    await db!.transaction((txn) async {
      final rows = await txn.query(
        Trade.tableName,
        where: '${Trade.selfIdColumn} = ? AND id = ? AND providerRaw = ?',
        whereArgs: [
          committedSource.internalId,
          committedSource.id,
          committedSource.providerRaw,
        ],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Pegaroute trade no longer exists');

      final latest = Trade.fromSqliteRow(rows.first);
      final validated = _bindingValidator.validatePersisted(
        trade: latest,
        expectedRawExecutionJson: committedSource.rawExecutionJson,
      );
      _bindingValidator.validateStatusResponse(
        validated: validated,
        response: observation.response,
        broadcastTransactionHash: _broadcastHash(latest, validated),
      );
      final expected = Map<String, Object?>.from(rows.first)..remove(Trade.selfIdColumn);
      final before = latest.toSqliteMap();
      final observedHash = observation.response.input.txHash;
      final lifecycleJson = latest.executionLifecycleJson;
      if (pegarouteTrustedExecution(validated.execution) &&
          lifecycleJson != null &&
          observedHash != null) {
        var lifecycle = TradeExecutionLifecycle.fromJsonString(lifecycleJson);
        final expectedHash =
            validated.execution.sourceChain == 'ZEC' ? latest.txId : lifecycle.executionHash;
        final matchesHash = validated.execution.sourceChain == 'SOL'
            ? observedHash == expectedHash
            : observedHash.toLowerCase() == expectedHash?.toLowerCase();
        if (!matchesHash) {
          throw const PegarouteBindingException('Status source hash differs from the deposit');
        }
        if (lifecycle.state == TradeExecutionLifecycleState.broadcasted &&
            lifecycle.callbackState != TradeExecutionCallbackState.accepted) {
          final at = DateTime.now().toUtc().toIso8601String();
          lifecycle = lifecycle.markCallbackAttempted(at).markCallbackAccepted(at);
          latest.executionLifecycleJson = lifecycle.encode();
        }
      }
      _mergeStatusEvidence(latest, observation.trade);

      // Write changed provider evidence and any confirmed callback transition.
      // Preserve the exact stored asset and execution envelopes.
      final values = <String, Object?>{
        'stateRaw': latest.stateRaw,
        for (final entry in latest.toSqliteMap().entries)
          if (entry.key != Trade.selfIdColumn && entry.value != before[entry.key])
            entry.key: entry.value,
      };
      final predicates = <String>[
        '${Trade.selfIdColumn} = ?',
      ];
      final predicateArgs = <Object?>[committedSource.internalId];
      for (final entry in expected.entries) {
        if (entry.value == null) {
          predicates.add('${entry.key} IS NULL');
        } else {
          predicates.add('${entry.key} = ?');
          predicateArgs.add(entry.value);
        }
      }
      final changed = await txn.update(
        Trade.tableName,
        values,
        where: predicates.join(' AND '),
        whereArgs: predicateArgs,
      );
      if (changed != 1) throw StateError('Pegaroute trade changed during status refresh');
      committed = latest;
    });

    trade.synchronizeFromPegarouteRefresh(committed);
    Trade.onChanged.add(null);
    return trade;
  }

  _PegarouteStatusSource _captureSource(Trade trade, {bool requirePersisted = false}) {
    if (requirePersisted && trade.internalId <= 0) {
      throw const PegarouteBindingException('Pegaroute status caller is not persisted');
    }
    final validated = _bindingValidator.validatePersisted(trade: trade);
    return _PegarouteStatusSource(
      internalId: trade.internalId,
      id: trade.id,
      providerRaw: trade.providerRaw,
      rawExecutionJson: validated.rawExecutionJson,
    );
  }

  String? _broadcastHash(Trade trade, ValidatedTradeExecution validated) {
    final raw = trade.executionLifecycleJson;
    final hash = trade.txId;
    if (raw == null || hash == null || hash.isEmpty) return null;
    final lifecycle = TradeExecutionLifecycle.fromJsonString(raw);
    return lifecycle.state == TradeExecutionLifecycleState.broadcasted &&
            lifecycle.executionHash == pegarouteFundingIdentity(validated.execution, hash)
        ? hash
        : null;
  }

  ValidatedTradeExecution _validateCaller(
    Trade trade,
    _PegarouteStatusSource source,
  ) {
    if (trade.internalId != source.internalId ||
        trade.id != source.id ||
        trade.providerRaw != source.providerRaw) {
      throw const PegarouteBindingException('Pegaroute status caller identity changed');
    }
    return _bindingValidator.validatePersisted(
      trade: trade,
      expectedRawExecutionJson: source.rawExecutionJson,
    );
  }

  Future<_PegarouteStatusObservation> _fetchStatus({
    required Trade trade,
    required _PegarouteStatusSource source,
  }) async {
    final validated = _validateCaller(trade, source);
    try {
      final response = await _apiClient.status(
        validated.execution.binding.providerTransactionId ?? trade.id,
      );
      var current = _validateCaller(trade, source);
      _bindingValidator.validateStatusResponse(
          validated: current,
          response: response,
          broadcastTransactionHash: _broadcastHash(trade, current));
      final input = response.input;
      final output = response.output;
      final parsedFrom = await _parseCurrency(input.chain, input.token);
      final parsedTo = await _parseCurrency(output.chain, output.token);
      current = _validateCaller(trade, source);
      _bindingValidator.validateStatusResponse(
          validated: current,
          response: response,
          broadcastTransactionHash: _broadcastHash(trade, current));
      final configuredRefund = input.refundAddress;
      final refund = response.refund;
      final refundRecord =
          refund == null && configuredRefund == null && response.internalStatus != 'refunded'
              ? null
              : TradeRefund(
                  configuredAddress: configuredRefund,
                  status: refund?.status,
                  txHash: refund?.txHash,
                  chain: refund?.chain,
                  amount: refund?.amount,
                  originalAmount: refund?.originalAmount,
                  feeDeducted: refund?.feeDeducted,
                  feeDescription: refund?.feeDescription,
                  observedAddress: refund?.refundAddress,
                  completedAt: refund?.completedAt,
                  terminalWithoutEvidence: response.internalStatus == 'refunded' && refund == null,
                );
      final statusTrade = Trade(
        id: trade.id,
        from: parsedFrom,
        to: parsedTo,
        provider: description,
        senderAddress: input.address,
        refundAddress: configuredRefund,
        amount: input.amount,
        state: _tradeState(response.internalStatus, refund?.status),
        outputTransaction: output.txHash,
        txId: input.txHash,
        receiveAmount: output.amount,
        payoutAddress: output.address,
        providerName: current.execution.routeProvider,
        providerId: current.execution.binding.providerReferenceId,
        refundJson: refundRecord?.encode(),
      );
      return _PegarouteStatusObservation(
        source: source,
        response: response,
        trade: statusTrade,
      );
    } on PegarouteApiError catch (error) {
      if (error.httpStatus == 404) throw TradeNotFoundException(trade.id, provider: description);
      rethrow;
    }
  }

  static const _normalStateRank = {
    'created': 0,
    'confirming': 1,
    'exchanging': 2,
    'sending': 3,
  };

  static _PegarouteTransition _transition(String current, String next) {
    if (next.isEmpty) return _PegarouteTransition.stale;
    if (current == next) return _PegarouteTransition.same;
    if (current.isEmpty) return _PegarouteTransition.advance;
    if (current == 'success' || current == 'refunded') return _PegarouteTransition.stale;
    if (next == 'refunded') return _PegarouteTransition.advance;
    if (current == 'failed' || current == 'refund' && next != 'refunded') {
      return _PegarouteTransition.stale;
    }

    final currentRank = _normalStateRank[current];
    if (currentRank == null) return _PegarouteTransition.stale;
    if (next == 'refund' || next == 'failed' || next == 'success') {
      return _PegarouteTransition.advance;
    }
    final nextRank = _normalStateRank[next];
    return nextRank != null && nextRank > currentRank
        ? _PegarouteTransition.advance
        : _PegarouteTransition.stale;
  }

  static void _mergeStatusEvidence(Trade current, Trade updated) {
    final transition = _transition(current.stateRaw, updated.stateRaw);
    if (transition == _PegarouteTransition.stale) return;

    final advancing = transition == _PegarouteTransition.advance;
    String? merge(String? existing, String? incoming) {
      if (incoming == null || incoming.isEmpty) return existing;
      return advancing || existing == null ? incoming : existing;
    }

    if (current.createdAt == null && updated.createdAt != null) {
      current.createdAt = updated.createdAt;
    }
    current.stateRaw = updated.stateRaw;
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

  List<PegarouteAssetId>? _quoteAssets(CryptoCurrency from, CryptoCurrency to) {
    try {
      final source = _currencyMapper.map(from);
      final destination = _currencyMapper.map(to);
      if (!PegarouteCurrencyMapper.quoteSourceChains.contains(source.chain)) {
        return null;
      }
      if (!PegarouteProviderPreferences.providers.keys.any(_providerAllowed)) return null;
      if (executableQuotesOnly &&
          (!isExecutionAvailable || !pegarouteTrustedSource(currentWallet?.call(), source))) {
        return null;
      }
      return [source, destination];
    } on PegarouteCurrencyException {
      return null;
    }
  }

  bool _providerAllowed(String provider) =>
      PegarouteProviderPreferences.providers.containsKey(provider) &&
      (providerPreferences?.isEnabled(provider) ?? true);

  CryptoCurrency _persistableCurrency(CryptoCurrency currency, PegarouteAssetId asset) {
    if (currency.runtimeType != CryptoCurrency || !asset.token.contains('-')) return currency;
    final parts = asset.token.split('-');
    final chainId = const {...pegarouteEvmChains, 'AVAX': 43114}[asset.chain];
    if (chainId != null) {
      return Erc20Token(
        name: currency.fullName ?? currency.title,
        symbol: parts.first,
        contractAddress: parts.last,
        decimal: currency.decimals,
        tag: _reverseChainAlias(asset.chain),
        chainId: chainId,
        iconPath: currency.iconPath,
      );
    }
    if (asset.chain == 'SOL') {
      return SPLToken(
        name: currency.fullName ?? currency.title,
        symbol: parts.first,
        mintAddress: parts.last,
        mint: parts.last,
        decimal: currency.decimals,
        iconPath: currency.iconPath,
      );
    }
    throw const PegarouteUnavailableException();
  }

  static int _compareOutput(String a, String b) {
    final first = a.split('.');
    final second = b.split('.');
    final aPlaces = first.length == 1 ? 0 : first.last.length;
    final bPlaces = second.length == 1 ? 0 : second.last.length;
    return (BigInt.parse(first.join()) * BigInt.from(10).pow(bPlaces))
        .compareTo(BigInt.parse(second.join()) * BigInt.from(10).pow(aPlaces));
  }

  bool _isQuoteRouteEligible(PegarouteRoute route, PegarouteAssetId source) {
    if (!_providerAllowed(route.provider) || (route.privateValue?.isEnabled ?? false)) return false;
    if (executableQuotesOnly && !pegarouteTrustedQuote(source, route)) return false;
    return source.chain != 'XMR' || route.memo == null;
  }

  void _logQuoteFailure(Object error) {
    // Never log response bodies, request headers or credential configuration.
    final reason = error is PegarouteApiError
        ? 'HTTP ${error.httpStatus}'
        : error is PegarouteUnavailableException
            ? 'configure PEGAROUTE_API_BASE_URL with the Cake proxy origin'
            : error.runtimeType.toString();
    printV('Pegaroute quote unavailable: $reason');
  }

  String _decimalAmount(double amount) {
    final fixed = amount.toStringAsFixed(18);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String _receiveDecimalAmount(double amount) {
    // Expand only the shortest decimal representation of the legacy double;
    // toStringAsFixed would introduce binary floating-point fractional noise.
    final text = amount.toString().toLowerCase();
    if (!text.contains('e')) return text;
    final parts = text.split('e');
    final mantissa = parts.first.split('.');
    final digits = mantissa.join();
    final point = mantissa.first.length + int.parse(parts.last);
    if (point <= 0) return '0.${'0' * -point}$digits';
    if (point >= digits.length) return digits.padRight(point, '0');
    return '${digits.substring(0, point)}.${digits.substring(point)}';
  }

  Future<CryptoCurrency?> _parseCurrency(String? chain, String? token) async {
    if (_currencyLookup != null) return _currencyLookup(chain, token);
    if (token == null || token.isEmpty) return null;
    final separator = token.indexOf('-');
    if (separator < 0) {
      final symbol = token;
      final tag = chain == null || chain.toUpperCase() == symbol.toUpperCase()
          ? null
          : _reverseChainAlias(chain);
      return CryptoCurrency.safeParseCurrencyFromString(symbol, tag: tag);
    }

    final symbol = token.substring(0, separator);
    final contract = token.substring(separator + 1);
    if (symbol.isEmpty || contract.isEmpty || chain == null || chain.isEmpty) return null;

    switch (chain.toUpperCase()) {
      case 'SOL':
        final tokens = TokenUtilities.loadDefaultSolTokensForSwap();
        return _firstSolanaToken(tokens, contract) ??
            _firstSolanaToken(await TokenUtilities.loadSolTokensForSwap(), contract);
      case 'TRON':
        final tokens = TokenUtilities.loadDefaultTronTokensForSwap();
        return _firstTronToken(tokens, contract) ??
            _firstTronToken(await TokenUtilities.loadTronTokensForSwap(), contract);
      default:
        final normalizedContract = contract.toLowerCase();
        final tokens = TokenUtilities.loadDefaultEvmTokensForSwap();
        return _firstEvmToken(tokens, chain, normalizedContract) ??
            _firstEvmToken(await TokenUtilities.loadEvmTokensForSwap(), chain, normalizedContract);
    }
  }

  Erc20Token? _firstEvmToken(
    List<Erc20Token> tokens,
    String chain,
    String contract,
  ) {
    for (final token in tokens) {
      if (token.contractAddress.toLowerCase() == contract && _sameEvmChain(token, chain)) {
        return token;
      }
    }
    return null;
  }

  SPLToken? _firstSolanaToken(List<SPLToken> tokens, String mint) {
    for (final token in tokens) {
      if (token.mintAddress == mint) return token;
    }
    return null;
  }

  TronToken? _firstTronToken(List<TronToken> tokens, String contract) {
    for (final token in tokens) {
      if (token.contractAddress == contract) return token;
    }
    return null;
  }

  bool _sameEvmChain(Erc20Token token, String chain) {
    final normalizedChain = chain.toUpperCase();
    final chainId = switch (normalizedChain) {
      'ETH' => 1,
      'BSC' => 56,
      'POLYGON' => 137,
      'AVAX' => 43114,
      'ARBITRUM' => 42161,
      'BASE' => 8453,
      _ => null,
    };
    if (chainId != null && token.chainId == chainId) return true;
    return _chainAlias(token.tag) == normalizedChain;
  }

  String? _chainAlias(String? tag) {
    switch (tag?.toUpperCase()) {
      case 'ETH':
        return 'ETH';
      case 'BSC':
        return 'BSC';
      case 'POL':
        return 'POLYGON';
      case 'AVAXC':
        return 'AVAX';
      case 'ARB':
        return 'ARBITRUM';
      case 'BASE':
        return 'BASE';
      default:
        return null;
    }
  }

  String _reverseChainAlias(String chain) {
    switch (chain.toUpperCase()) {
      case 'ARBITRUM':
        return 'ARB';
      case 'AVAX':
        return 'AVAXC';
      case 'POLYGON':
        return 'POL';
      case 'TRON':
        return 'TRX';
      default:
        return chain;
    }
  }

  TradeState _tradeState(String value, String? refundStatus) {
    if (refundStatus == 'pending' || refundStatus == 'broadcasting') {
      return TradeState.refund;
    }

    switch (value) {
      case 'pending':
        return TradeState.created;
      case 'submitted':
        return TradeState.confirming;
      case 'executing':
        return TradeState.exchanging;
      case 'confirming':
        return TradeState.sending;
      case 'completed':
        return TradeState.success;
      case 'failed':
        return TradeState.failed;
      case 'refunded':
        return TradeState.refunded;
      default:
        return TradeState.pending;
    }
  }
}

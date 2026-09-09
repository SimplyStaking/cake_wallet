import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/limits.dart';
import 'package:cake_wallet/exchange/provider/exchange_provider.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_capability_gate.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_currency_mapper.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_not_found_exception.dart';
import 'package:cake_wallet/exchange/trade_refund.dart';
import 'package:cake_wallet/exchange/trade_request.dart';
import 'package:cake_wallet/exchange/trade_state.dart';
import 'package:cake_wallet/utils/token_utilities.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/db/sqlite.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/spl_token.dart';
import 'package:cw_core/tron_token.dart';

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
    Future<CryptoCurrency?> Function(String? chain, String? token)? currencyLookup,
  })  : _apiClient = apiClient ?? PegarouteApiClient(configuration: configuration),
        _capabilityGate = capabilityGate ?? const PegarouteCapabilityGate(),
        _currencyLookup = currencyLookup;

  final PegarouteApiClient _apiClient;
  final PegarouteCapabilityGate _capabilityGate;
  final Future<CryptoCurrency?> Function(String? chain, String? token)? _currencyLookup;
  final PegarouteCurrencyMapper _currencyMapper = const PegarouteCurrencyMapper();
  final PegarouteExecutionBindingValidator _bindingValidator =
      const PegarouteExecutionBindingValidator();

  @override
  String get title => 'Pegaroute';

  // Quote discovery is available for eligible native sources. Swap
  // creation and execution remain closed until concrete handlers are ready.
  @override
  bool get isAvailable => _apiClient.configuration.isValid;

  bool get isExecutionAvailable => isAvailable && _capabilityGate.hasExecutionHandlers;

  @override
  bool get isEnabled => isAvailable;

  @override
  bool get supportsFixedRate => false;

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
      final minimums = quote.response.routes
          .where((route) => _isQuoteRouteEligible(route, assets.first.chain))
          .map((route) => double.tryParse(route.minAmount ?? ''))
          .whereType<double>()
          .where((amount) => amount.isFinite && amount >= 0)
          .toList(growable: false);
      return Limits(
        min: minimums.isEmpty ? 0 : minimums.reduce((a, b) => a < b ? a : b),
        max: null,
      );
    } catch (_) {
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
    if (amount <= 0 || !amount.isFinite || isFixedRateMode || isReceiveAmount) return 0;
    final assets = _quoteAssets(from, to);
    if (assets == null) return 0;
    try {
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
      for (final route in quote.response.routes) {
        if (!_isQuoteRouteEligible(route, assets.first.chain)) continue;
        final output = double.tryParse(route.expectedOutput);
        if (output != null && output.isFinite && output > bestOutput) bestOutput = output;
      }
      return bestOutput == 0 ? 0 : bestOutput / amount;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<Trade> createTrade({
    required TradeRequest request,
    required bool isFixedRateMode,
    required bool isSendAll,
  }) async {
    _ensureUnavailable(request.fromCurrency, request.toCurrency);
    throw const PegarouteUnavailableException();
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
      );
      final expected = latest.toSqliteMap()..remove(Trade.selfIdColumn);
      _mergeStatusEvidence(latest, observation.trade);

      final values = latest.toSqliteMap()..remove(Trade.selfIdColumn);
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
      _bindingValidator.validateStatusResponse(validated: current, response: response);
      final input = response.input;
      final output = response.output;
      final parsedFrom = await _parseCurrency(input.chain, input.token);
      final parsedTo = await _parseCurrency(output.chain, output.token);
      current = _validateCaller(trade, source);
      _bindingValidator.validateStatusResponse(validated: current, response: response);
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

  void _ensureUnavailable(CryptoCurrency from, CryptoCurrency to) {
    // Mapping is intentionally performed before the gate so unsupported assets never reach I/O.
    _currencyMapper.map(from);
    _currencyMapper.map(to);
    throw const PegarouteUnavailableException();
  }

  List<PegarouteAssetId>? _quoteAssets(CryptoCurrency from, CryptoCurrency to) {
    try {
      final source = _currencyMapper.map(from);
      final destination = _currencyMapper.map(to);
      if (!_quoteSourceChains.contains(source.chain) || source.token != source.nativeToken) {
        return null;
      }
      return [source, destination];
    } on PegarouteCurrencyException {
      return null;
    }
  }

  bool _isQuoteRouteEligible(PegarouteRoute route, String sourceChain) {
    final private = route.privateValue?.value;
    if (private != null && private != false) return false;
    return sourceChain != 'XMR' || route.memo == null;
  }

  String _decimalAmount(double amount) {
    final fixed = amount.toStringAsFixed(18);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
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

const _quoteSourceChains = {
  'BTC',
  'ETH',
  'XMR',
  'BCH',
  'LTC',
  'DOGE',
  'ZEC',
  'BSC',
  'BASE',
  'ARBITRUM',
  'POLYGON',
  'SOL',
  'TRON',
};

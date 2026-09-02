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
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/spl_token.dart';
import 'package:cw_core/tron_token.dart';

class PegarouteExchangeProvider extends ExchangeProvider {
  PegarouteExchangeProvider({
    PegarouteApiClient? apiClient,
    PegarouteConfiguration? configuration,
    PegarouteCapabilityGate? capabilityGate,
  })  : _apiClient = apiClient ?? PegarouteApiClient(configuration: configuration),
        _capabilityGate = capabilityGate ?? const PegarouteCapabilityGate();

  final PegarouteApiClient _apiClient;
  final PegarouteCapabilityGate _capabilityGate;
  final PegarouteCurrencyMapper _currencyMapper = const PegarouteCurrencyMapper();
  final PegarouteExecutionBindingValidator _bindingValidator =
      const PegarouteExecutionBindingValidator();

  @override
  String get title => 'Pegaroute';

  // No executor is registered until a later phase.
  @override
  bool get isAvailable => _apiClient.configuration.isValid && _capabilityGate.hasExecutionHandlers;

  @override
  bool get isEnabled => false;

  @override
  bool get supportsFixedRate => false;

  @override
  bool get supportsMemoOrDestinationTag => false;

  @override
  ExchangeProviderDescription get description => ExchangeProviderDescription.pegaroute;

  @override
  Future<bool> checkIsAvailable() async => false;

  @override
  Future<Limits?> fetchLimits({
    required CryptoCurrency from,
    required CryptoCurrency to,
    required bool isFixedRateMode,
  }) async {
    _ensureUnavailable(from, to);
    return null;
  }

  @override
  Future<double> fetchRate({
    required CryptoCurrency from,
    required CryptoCurrency to,
    required double amount,
    required bool isFixedRateMode,
    required bool isReceiveAmount,
  }) async {
    _ensureUnavailable(from, to);
    return 0;
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

  Future<Trade> findTradeForContext({required Trade trade}) async {
    final validated = _bindingValidator.validatePersisted(trade: trade);
    final rawExecutionJson = validated.rawExecutionJson;
    try {
      final response = await _apiClient.status(trade.id);
      final current = _bindingValidator.validatePersisted(
        trade: trade,
        expectedRawExecutionJson: rawExecutionJson,
      );
      _bindingValidator.validateStatusResponse(validated: current, response: response);
      final input = response.input;
      final output = response.output;
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
      final finalValidation = _bindingValidator.validatePersisted(
        trade: trade,
        expectedRawExecutionJson: rawExecutionJson,
      );
      _bindingValidator.validateStatusResponse(validated: finalValidation, response: response);
      return Trade(
        id: trade.id,
        from: await _parseCurrency(input.chain, input.token),
        to: await _parseCurrency(output.chain, output.token),
        provider: description,
        senderAddress: input.address,
        refundAddress: configuredRefund,
        amount: input.amount,
        state: _tradeState(response.internalStatus, refund?.status),
        outputTransaction: output.txHash,
        receiveAmount: output.amount,
        payoutAddress: output.address,
        providerName: finalValidation.execution.routeProvider,
        providerId: finalValidation.execution.binding.providerReferenceId,
        refundJson: refundRecord?.encode(),
      );
    } on PegarouteApiError catch (error) {
      if (error.httpStatus == 404) throw TradeNotFoundException(trade.id, provider: description);
      rethrow;
    }
  }

  void _ensureUnavailable(CryptoCurrency from, CryptoCurrency to) {
    // Mapping is intentionally performed before the gate so unsupported assets never reach I/O.
    _currencyMapper.map(from);
    _currencyMapper.map(to);
    throw const PegarouteUnavailableException();
  }

  Future<CryptoCurrency?> _parseCurrency(String? chain, String? token) async {
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

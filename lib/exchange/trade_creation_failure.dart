enum TradeCreationFailureBoundary { beforeRequest, requestMayHaveReached }

/// Typed boundary used by automatic provider selection. Only failures proven
/// to precede provider-side creation may fall through to another provider.
abstract interface class TradeCreationFailure {
  TradeCreationFailureBoundary get boundary;
  String get userMessage;
}

bool blocksTradeCreationFallback(Object error) =>
    error is TradeCreationFailure &&
    error.boundary == TradeCreationFailureBoundary.requestMayHaveReached;

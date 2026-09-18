import 'package:cake_wallet/exchange/trade_creation_failure.dart';
import 'package:flutter_test/flutter_test.dart';

final class _CreationFailure implements Exception, TradeCreationFailure {
  const _CreationFailure(this.boundary);

  @override
  final TradeCreationFailureBoundary boundary;

  @override
  String get userMessage => 'fixture';
}

void main() {
  test('only a request that may have reached the provider blocks fallback', () {
    expect(
      blocksTradeCreationFallback(
        const _CreationFailure(TradeCreationFailureBoundary.requestMayHaveReached),
      ),
      isTrue,
    );
    expect(
      blocksTradeCreationFallback(
        const _CreationFailure(TradeCreationFailureBoundary.beforeRequest),
      ),
      isFalse,
    );
    expect(blocksTradeCreationFallback(StateError('ordinary provider failure')), isFalse);
  });
}

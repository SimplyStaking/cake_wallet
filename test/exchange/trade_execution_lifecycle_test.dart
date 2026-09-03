import 'package:cake_wallet/exchange/trade_execution_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('round trips a non-secret lifecycle and enforces one-shot broadcast', () {
    final prepared = TradeExecutionLifecycle(
      executionHash: '0xhash',
      state: TradeExecutionLifecycleState.prepared,
      callbackState: TradeExecutionCallbackState.pending,
      createdAt: '2026-09-03T00:00:00Z',
    );
    final broadcasting = prepared.beginBroadcast('2026-09-03T00:01:00Z');
    expect(() => broadcasting.beginBroadcast('later'), throwsStateError);
    final broadcasted = broadcasting.markBroadcasted('2026-09-03T00:02:00Z');
    expect(
      TradeExecutionLifecycle.fromJsonString(broadcasted.encode()).state,
      TradeExecutionLifecycleState.broadcasted,
    );
    expect(() => broadcasted.markBroadcasted('later'), throwsStateError);
    expect(broadcasted.toJson().keys, isNot(contains('rawTransaction')));
    expect(broadcasted.toJson().keys, isNot(contains('privateKey')));
  });

  test('records ambiguous submission and does not permit blind recommit', () {
    final lifecycle = TradeExecutionLifecycle(
      executionHash: 'btc-hash',
      state: TradeExecutionLifecycleState.prepared,
      callbackState: TradeExecutionCallbackState.notRequired,
      createdAt: '2026-09-03T00:00:00Z',
    ).beginBroadcast('2026-09-03T00:01:00Z');

    final unknown = lifecycle.markBroadcastUnknown('2026-09-03T00:01:30Z');
    expect(unknown.state, TradeExecutionLifecycleState.broadcastUnknown);
    expect(() => unknown.beginBroadcast('later'), throwsStateError);
  });

  test('rejects unknown fields and invalid callback timestamps', () {
    final value = <String, dynamic>{
      'version': 1,
      'executionHash': 'hash',
      'state': 'prepared',
      'callbackState': 'accepted',
      'createdAt': 'created',
      'broadcastingAt': null,
      'broadcastedAt': null,
      'callbackAttemptedAt': null,
      'callbackAcceptedAt': null,
    };
    expect(() => TradeExecutionLifecycle.fromJson(value), throwsFormatException);
    value['unexpected'] = true;
    expect(() => TradeExecutionLifecycle.fromJson(value), throwsFormatException);
  });
}

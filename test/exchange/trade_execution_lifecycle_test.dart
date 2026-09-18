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
    expect(unknown.broadcastUnknownAt, '2026-09-03T00:01:30Z');
    expect(() => unknown.beginBroadcast('later'), throwsStateError);
  });

  test('records a known pre-send abort separately from ambiguous submission', () {
    final lifecycle = TradeExecutionLifecycle(
      executionHash: 'btc-hash',
      state: TradeExecutionLifecycleState.prepared,
      callbackState: TradeExecutionCallbackState.pending,
      createdAt: '2026-09-03T00:00:00Z',
    ).beginBroadcast('2026-09-03T00:01:00Z');

    final aborted = lifecycle.markBroadcastAborted('2026-09-03T00:01:30Z');
    expect(aborted.state, TradeExecutionLifecycleState.broadcastAborted);
    expect(aborted.broadcastAbortedAt, '2026-09-03T00:01:30Z');
    expect(aborted.broadcastUnknownAt, isNull);
    expect(aborted.callbackState, TradeExecutionCallbackState.notRequired);
    expect(() => aborted.beginBroadcast('later'), throwsStateError);
  });

  test('rejects unknown fields and invalid callback timestamps', () {
    final value = <String, dynamic>{
      'version': 2,
      'executionHash': 'hash',
      'state': 'prepared',
      'callbackState': 'accepted',
      'createdAt': 'created',
      'broadcastingAt': null,
      'broadcastedAt': null,
      'broadcastUnknownAt': null,
      'broadcastAbortedAt': null,
      'callbackAttemptedAt': null,
      'callbackAcceptedAt': null,
    };
    expect(() => TradeExecutionLifecycle.fromJson(value), throwsFormatException);
    value['unexpected'] = true;
    expect(() => TradeExecutionLifecycle.fromJson(value), throwsFormatException);
  });

  test('requires UTC monotonic lifecycle timestamps', () {
    expect(
      () => TradeExecutionLifecycle(
        executionHash: 'hash',
        state: TradeExecutionLifecycleState.prepared,
        callbackState: TradeExecutionCallbackState.pending,
        createdAt: '2026-09-03T00:00:00+01:00',
      ),
      throwsFormatException,
    );
    final prepared = TradeExecutionLifecycle(
      executionHash: 'hash',
      state: TradeExecutionLifecycleState.prepared,
      callbackState: TradeExecutionCallbackState.pending,
      createdAt: '2026-09-03T00:02:00Z',
    );
    expect(() => prepared.beginBroadcast('2026-09-03T00:01:00Z'), throwsFormatException);
    final broadcasting = prepared.beginBroadcast('2026-09-03T00:03:00Z');
    expect(
      () => broadcasting.markBroadcasted('2026-09-03T00:02:30Z'),
      throwsFormatException,
    );
    expect(
      () => broadcasting.markBroadcastUnknown('2026-09-03T00:02:30Z'),
      throwsFormatException,
    );
    expect(
      () => broadcasting.markBroadcastAborted('2026-09-03T00:02:30Z'),
      throwsFormatException,
    );
  });

  test('accepted callback state is terminal', () {
    final accepted = TradeExecutionLifecycle(
      executionHash: 'hash',
      state: TradeExecutionLifecycleState.prepared,
      callbackState: TradeExecutionCallbackState.pending,
      createdAt: '2026-09-03T00:00:00Z',
    )
        .beginBroadcast('2026-09-03T00:01:00Z')
        .markBroadcasted('2026-09-03T00:02:00Z')
        .markCallbackAccepted('2026-09-03T00:03:00Z');

    expect(() => accepted.markCallbackAttempted('2026-09-03T00:04:00Z'), throwsStateError);
    expect(() => accepted.markCallbackAccepted('2026-09-03T00:04:00Z'), throwsStateError);
  });
}

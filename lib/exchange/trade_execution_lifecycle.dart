import 'dart:convert';

/// Durable, non-secret state for a Pegaroute broadcast attempt.
///
/// This envelope intentionally contains neither a private key nor signed raw
/// transaction bytes. A transition to [broadcasting] is the commit boundary:
/// callers must persist it before attempting network submission.
enum TradeExecutionLifecycleState { prepared, broadcasting, broadcasted, broadcastUnknown }

enum TradeExecutionCallbackState { notRequired, pending, accepted, failed }

final class TradeExecutionLifecycle {
  TradeExecutionLifecycle({
    required this.executionHash,
    required this.state,
    required this.callbackState,
    required this.createdAt,
    this.broadcastingAt,
    this.broadcastedAt,
    this.callbackAttemptedAt,
    this.callbackAcceptedAt,
  }) {
    _validate();
  }

  factory TradeExecutionLifecycle.fromJsonString(String value) {
    final decoded = json.decode(value);
    if (decoded is! Map) throw const FormatException('lifecycle must be an object');
    return TradeExecutionLifecycle.fromJson(Map<String, dynamic>.from(decoded));
  }

  factory TradeExecutionLifecycle.fromJson(Map<String, dynamic> value) {
    const keys = {
      'version',
      'executionHash',
      'state',
      'callbackState',
      'createdAt',
      'broadcastingAt',
      'broadcastedAt',
      'callbackAttemptedAt',
      'callbackAcceptedAt',
    };
    if (value.length != keys.length || value.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('invalid lifecycle fields');
    }
    if (value['version'] != 1 ||
        value['executionHash'] is! String ||
        value['state'] is! String ||
        value['callbackState'] is! String ||
        value['createdAt'] is! String) {
      throw const FormatException('invalid lifecycle values');
    }
    TradeExecutionLifecycleState parseState(String raw) =>
        TradeExecutionLifecycleState.values.firstWhere(
          (value) => value.name == raw,
          orElse: () => throw const FormatException('invalid lifecycle state'),
        );
    TradeExecutionCallbackState parseCallback(String raw) =>
        TradeExecutionCallbackState.values.firstWhere(
          (value) => value.name == raw,
          orElse: () => throw const FormatException('invalid lifecycle callback state'),
        );
    String? optionalString(Object? raw) {
      if (raw == null) return null;
      if (raw is! String || raw.isEmpty) throw const FormatException('invalid lifecycle timestamp');
      return raw;
    }

    return TradeExecutionLifecycle(
      executionHash: value['executionHash'] as String,
      state: parseState(value['state'] as String),
      callbackState: parseCallback(value['callbackState'] as String),
      createdAt: value['createdAt'] as String,
      broadcastingAt: optionalString(value['broadcastingAt']),
      broadcastedAt: optionalString(value['broadcastedAt']),
      callbackAttemptedAt: optionalString(value['callbackAttemptedAt']),
      callbackAcceptedAt: optionalString(value['callbackAcceptedAt']),
    );
  }

  final String executionHash;
  final TradeExecutionLifecycleState state;
  final TradeExecutionCallbackState callbackState;
  final String createdAt;
  final String? broadcastingAt;
  final String? broadcastedAt;
  final String? callbackAttemptedAt;
  final String? callbackAcceptedAt;

  TradeExecutionLifecycle beginBroadcast(String at) {
    if (state != TradeExecutionLifecycleState.prepared) {
      throw StateError('broadcast already started');
    }
    return TradeExecutionLifecycle(
      executionHash: executionHash,
      state: TradeExecutionLifecycleState.broadcasting,
      callbackState: callbackState,
      createdAt: createdAt,
      broadcastingAt: at,
      broadcastedAt: broadcastedAt,
      callbackAttemptedAt: callbackAttemptedAt,
      callbackAcceptedAt: callbackAcceptedAt,
    );
  }

  TradeExecutionLifecycle markBroadcasted(String at, {bool callbackRequired = true}) {
    if (state != TradeExecutionLifecycleState.broadcasting) {
      throw StateError('broadcast is not in progress');
    }
    return TradeExecutionLifecycle(
      executionHash: executionHash,
      state: TradeExecutionLifecycleState.broadcasted,
      callbackState: callbackRequired
          ? TradeExecutionCallbackState.pending
          : TradeExecutionCallbackState.notRequired,
      createdAt: createdAt,
      broadcastingAt: broadcastingAt,
      broadcastedAt: at,
      callbackAttemptedAt: callbackAttemptedAt,
      callbackAcceptedAt: callbackAcceptedAt,
    );
  }

  TradeExecutionLifecycle markBroadcastUnknown(String at) {
    if (state != TradeExecutionLifecycleState.broadcasting) {
      throw StateError('broadcast is not in progress');
    }
    return TradeExecutionLifecycle(
      executionHash: executionHash,
      state: TradeExecutionLifecycleState.broadcastUnknown,
      callbackState: callbackState,
      createdAt: createdAt,
      broadcastingAt: broadcastingAt,
      broadcastedAt: broadcastedAt,
      callbackAttemptedAt: callbackAttemptedAt,
      callbackAcceptedAt: callbackAcceptedAt,
    );
  }

  TradeExecutionLifecycle markCallbackAttempted(String at) {
    if (state != TradeExecutionLifecycleState.broadcasted ||
        callbackState == TradeExecutionCallbackState.notRequired) {
      throw StateError('callback is unavailable');
    }
    return TradeExecutionLifecycle(
      executionHash: executionHash,
      state: state,
      callbackState: TradeExecutionCallbackState.failed,
      createdAt: createdAt,
      broadcastingAt: broadcastingAt,
      broadcastedAt: broadcastedAt,
      callbackAttemptedAt: at,
      callbackAcceptedAt: callbackAcceptedAt,
    );
  }

  TradeExecutionLifecycle markCallbackAccepted(String at) {
    if (state != TradeExecutionLifecycleState.broadcasted ||
        callbackState == TradeExecutionCallbackState.notRequired) {
      throw StateError('callback is unavailable');
    }
    return TradeExecutionLifecycle(
      executionHash: executionHash,
      state: state,
      callbackState: TradeExecutionCallbackState.accepted,
      createdAt: createdAt,
      broadcastingAt: broadcastingAt,
      broadcastedAt: broadcastedAt,
      callbackAttemptedAt: callbackAttemptedAt ?? at,
      callbackAcceptedAt: at,
    );
  }

  String encode() => json.encode(toJson());

  Map<String, dynamic> toJson() => {
    'version': 1,
    'executionHash': executionHash,
    'state': state.name,
    'callbackState': callbackState.name,
    'createdAt': createdAt,
    'broadcastingAt': broadcastingAt,
    'broadcastedAt': broadcastedAt,
    'callbackAttemptedAt': callbackAttemptedAt,
    'callbackAcceptedAt': callbackAcceptedAt,
  };

  void _validate() {
    if (executionHash.isEmpty || !_validTimestamp(createdAt)) {
      throw const FormatException('lifecycle identity is required');
    }
    for (final timestamp in [
      broadcastingAt,
      broadcastedAt,
      callbackAttemptedAt,
      callbackAcceptedAt,
    ]) {
      if (timestamp != null && !_validTimestamp(timestamp)) {
        throw const FormatException('invalid lifecycle timestamp');
      }
    }
    if (state == TradeExecutionLifecycleState.prepared &&
        (broadcastingAt != null || broadcastedAt != null)) {
      throw const FormatException('prepared lifecycle has broadcast timestamps');
    }
    if (state == TradeExecutionLifecycleState.broadcasting &&
        (broadcastingAt == null || broadcastedAt != null)) {
      throw const FormatException('broadcasting lifecycle timestamps are invalid');
    }
    if (state == TradeExecutionLifecycleState.broadcastUnknown &&
        (broadcastingAt == null || broadcastedAt != null)) {
      throw const FormatException('unknown broadcast lifecycle timestamps are invalid');
    }
    if (state == TradeExecutionLifecycleState.broadcasted &&
        (broadcastingAt == null || broadcastedAt == null)) {
      throw const FormatException('broadcasted lifecycle timestamps are invalid');
    }
    if (state != TradeExecutionLifecycleState.broadcasted &&
        (callbackState == TradeExecutionCallbackState.failed ||
            callbackState == TradeExecutionCallbackState.accepted)) {
      throw const FormatException('callback cannot complete before broadcast');
    }
    if (callbackState == TradeExecutionCallbackState.notRequired &&
        (callbackAttemptedAt != null || callbackAcceptedAt != null)) {
      throw const FormatException('unrequired callback has timestamps');
    }
    if (callbackState == TradeExecutionCallbackState.pending &&
        (callbackAttemptedAt != null || callbackAcceptedAt != null)) {
      throw const FormatException('pending callback has timestamps');
    }
    if (callbackState == TradeExecutionCallbackState.failed &&
        (callbackAttemptedAt == null || callbackAcceptedAt != null)) {
      throw const FormatException('failed callback timestamps are invalid');
    }
    if (callbackState == TradeExecutionCallbackState.accepted &&
        (callbackAttemptedAt == null || callbackAcceptedAt == null)) {
      throw const FormatException('accepted callback timestamps are invalid');
    }
  }

  static bool _validTimestamp(String value) => DateTime.tryParse(value) != null;
}

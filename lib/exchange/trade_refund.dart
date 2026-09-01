import 'dart:convert';

class TradeRefund {
  factory TradeRefund({
    String? configuredAddress,
    String? status,
    String? txHash,
    String? chain,
    String? amount,
    String? originalAmount,
    String? feeDeducted,
    String? feeDescription,
    String? observedAddress,
    String? completedAt,
    bool terminalWithoutEvidence = false,
    int version = 1,
  }) {
    final refund = TradeRefund._(
      configuredAddress: configuredAddress,
      status: status,
      txHash: txHash,
      chain: chain,
      amount: amount,
      originalAmount: originalAmount,
      feeDeducted: feeDeducted,
      feeDescription: feeDescription,
      observedAddress: observedAddress,
      completedAt: completedAt,
      terminalWithoutEvidence: terminalWithoutEvidence,
      version: version,
    );
    refund.validate();
    return refund;
  }

  TradeRefund._({
    this.configuredAddress,
    this.status,
    this.txHash,
    this.chain,
    this.amount,
    this.originalAmount,
    this.feeDeducted,
    this.feeDescription,
    this.observedAddress,
    this.completedAt,
    required this.terminalWithoutEvidence,
    required this.version,
  });

  factory TradeRefund.fromJsonString(String value) => TradeRefund.fromJson(json.decode(value));

  factory TradeRefund.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('refund must be an object');
    final map = Map<String, dynamic>.from(value);
    const keys = {
      'version',
      'configuredAddress',
      'status',
      'txHash',
      'chain',
      'amount',
      'originalAmount',
      'feeDeducted',
      'feeDescription',
      'observedAddress',
      'completedAt',
      'terminalWithoutEvidence',
    };
    if (map.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('refund contains unknown fields');
    }
    if (map['version'] is! int || map['version'] != 1) {
      throw const FormatException('unsupported refund version');
    }
    if (map['terminalWithoutEvidence'] != null && map['terminalWithoutEvidence'] is! bool) {
      throw const FormatException('terminal refund flag must be boolean');
    }
    return TradeRefund(
      configuredAddress: _string(map['configuredAddress']),
      status: _string(map['status']),
      txHash: _string(map['txHash']),
      chain: _string(map['chain']),
      amount: _string(map['amount']),
      originalAmount: _string(map['originalAmount']),
      feeDeducted: _string(map['feeDeducted']),
      feeDescription: _string(map['feeDescription']),
      observedAddress: _string(map['observedAddress']),
      completedAt: _string(map['completedAt']),
      terminalWithoutEvidence: map['terminalWithoutEvidence'] == true,
    );
  }

  final int version;
  final String? configuredAddress;
  final String? status;
  final String? txHash;
  final String? chain;
  final String? amount;
  final String? originalAmount;
  final String? feeDeducted;
  final String? feeDescription;
  final String? observedAddress;
  final String? completedAt;
  final bool terminalWithoutEvidence;

  void validate() {
    if (version != 1) throw const FormatException('unsupported refund version');
    for (final value in [
      configuredAddress,
      status,
      txHash,
      chain,
      amount,
      originalAmount,
      feeDeducted,
      feeDescription,
      observedAddress,
      completedAt,
    ]) {
      if (value != null && value.isEmpty) {
        throw const FormatException('refund values must not be blank');
      }
    }
    final evidence = [
      chain,
      amount,
      originalAmount,
      feeDeducted,
      feeDescription,
      observedAddress,
    ];
    final hasEvidence = evidence.any((value) => value != null);
    final completeEvidence = evidence.every((value) => value != null && value.isNotEmpty);

    if (terminalWithoutEvidence) {
      if (status != null || hasEvidence || txHash != null || completedAt != null) {
        throw const FormatException('terminal refund cannot contain evidence');
      }
      return;
    }

    if (status == null) {
      if (hasEvidence || txHash != null || completedAt != null) {
        throw const FormatException('refund evidence requires a lifecycle status');
      }
      return;
    }

    if (!const {'pending', 'broadcasting', 'completed'}.contains(status) || !completeEvidence) {
      throw const FormatException('refund evidence is incomplete');
    }
    if (status != 'completed' && completedAt != null) {
      throw const FormatException('only completed refunds may have completedAt');
    }
  }

  String encode() => json.encode(toJson());

  Map<String, dynamic> toJson() {
    validate();
    return {
      'version': version,
      if (configuredAddress != null) 'configuredAddress': configuredAddress,
      if (status != null) 'status': status,
      if (txHash != null) 'txHash': txHash,
      if (chain != null) 'chain': chain,
      if (amount != null) 'amount': amount,
      if (originalAmount != null) 'originalAmount': originalAmount,
      if (feeDeducted != null) 'feeDeducted': feeDeducted,
      if (feeDescription != null) 'feeDescription': feeDescription,
      if (observedAddress != null) 'observedAddress': observedAddress,
      if (completedAt != null) 'completedAt': completedAt,
      'terminalWithoutEvidence': terminalWithoutEvidence,
    };
  }

  /// Merge status snapshots without allowing lifecycle or evidence regression.
  TradeRefund merge(TradeRefund update) {
    final currentRank = _rank(this);
    final updateRank = _rank(update);
    final preferred = updateRank > currentRank ? update : this;
    if (preferred.terminalWithoutEvidence) {
      return TradeRefund(
        configuredAddress: configuredAddress ?? update.configuredAddress,
        terminalWithoutEvidence: true,
      );
    }
    final keepCurrent = updateRank < currentRank;
    return TradeRefund(
      configuredAddress: configuredAddress ?? update.configuredAddress,
      status: preferred.status,
      txHash: keepCurrent ? txHash : update.txHash ?? txHash,
      chain: keepCurrent ? chain : update.chain ?? chain,
      amount: keepCurrent ? amount : update.amount ?? amount,
      originalAmount: keepCurrent ? originalAmount : update.originalAmount ?? originalAmount,
      feeDeducted: keepCurrent ? feeDeducted : update.feeDeducted ?? feeDeducted,
      feeDescription: keepCurrent ? feeDescription : update.feeDescription ?? feeDescription,
      observedAddress: keepCurrent ? observedAddress : update.observedAddress ?? observedAddress,
      completedAt: keepCurrent ? completedAt : update.completedAt ?? completedAt,
      terminalWithoutEvidence: preferred.terminalWithoutEvidence,
    );
  }

  static String mergeJson(String? current, String update) {
    if (current == null || current.isEmpty) return update;
    try {
      final currentRefund = TradeRefund.fromJsonString(current);
      final updateRefund = TradeRefund.fromJsonString(update);
      return currentRefund.merge(updateRefund).encode();
    } on FormatException {
      // Unknown or malformed historical JSON is raw audit data, not a reason
      // to replace it with a typed status snapshot.
      return current;
    }
  }
}

int _rank(TradeRefund refund) {
  if (refund.status == 'completed') return 4;
  if (refund.terminalWithoutEvidence) return 3;
  if (refund.status == 'broadcasting') return 2;
  if (refund.status == 'pending') return 1;
  return 0;
}

String? _string(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const FormatException('refund values must be strings');
  return value;
}

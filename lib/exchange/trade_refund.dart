import 'dart:convert';

class TradeRefund {
  const TradeRefund({
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
    this.terminalWithoutEvidence = false,
    this.version = 1,
  });

  factory TradeRefund.fromJsonString(String value) => TradeRefund.fromJson(json.decode(value));

  factory TradeRefund.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('refund must be an object');
    final map = Map<String, dynamic>.from(value);
    if (map['version'] is! int || map['version'] != 1) {
      throw const FormatException('unsupported refund version');
    }
    final status = map['status'];
    if (status != null && status is! String) throw const FormatException('invalid refund status');
    if (status != null && !const {'pending', 'broadcasting', 'completed'}.contains(status)) {
      throw const FormatException('invalid refund status');
    }
    if (map['terminalWithoutEvidence'] != null && map['terminalWithoutEvidence'] is! bool) {
      throw const FormatException('invalid refund terminal flag');
    }
    return TradeRefund(
      configuredAddress: _string(map['configuredAddress']),
      status: status as String?,
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

  String encode() => json.encode(toJson());

  Map<String, dynamic> toJson() => {
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

String? _string(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const FormatException('refund values must be strings');
  return value;
}

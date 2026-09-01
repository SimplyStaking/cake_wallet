import 'dart:convert';

class TradeExecution {
  const TradeExecution({
    required this.family,
    required this.mode,
    required this.sourceChain,
    required this.sourceToken,
    required this.nativeToken,
    required this.destinationChain,
    required this.destinationToken,
    required this.payload,
    this.routeProvider,
    this.subprovider,
    this.privateIntent,
    this.version = 1,
  });

  factory TradeExecution.fromJsonString(String value) =>
      TradeExecution.fromJson(json.decode(value));

  factory TradeExecution.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('execution must be an object');
    final map = Map<String, dynamic>.from(value);
    final version = map['version'];
    if (version is! int || version != 1) {
      throw const FormatException('unsupported execution version');
    }
    final payload = map['payload'];
    if (payload is! Map) throw const FormatException('execution payload must be an object');
    final execution = TradeExecution(
      version: version,
      family: _required(map, 'family'),
      mode: _required(map, 'mode'),
      sourceChain: _required(map, 'sourceChain'),
      sourceToken: _required(map, 'sourceToken'),
      nativeToken: _required(map, 'nativeToken'),
      destinationChain: _required(map, 'destinationChain'),
      destinationToken: _required(map, 'destinationToken'),
      routeProvider: _optional(map, 'routeProvider'),
      subprovider: _optional(map, 'subprovider'),
      privateIntent: map['privateIntent'],
      payload: Map<String, dynamic>.from(payload),
    );
    final privateIntent = execution.privateIntent;
    if (privateIntent != null && privateIntent is! bool && privateIntent is! String) {
      throw const FormatException('invalid private intent');
    }
    if (privateIntent is String && privateIntent.isEmpty) {
      throw const FormatException('invalid private intent');
    }
    execution.validateFamilyMode();
    return execution;
  }

  final int version;
  final String family;
  final String mode;
  final String sourceChain;
  final String sourceToken;
  final String nativeToken;
  final String destinationChain;
  final String destinationToken;
  final String? routeProvider;
  final String? subprovider;
  final Object? privateIntent;
  final Map<String, dynamic> payload;

  void validateFamilyMode() {
    const known = {
      'evm/contract-call',
      'evm/native-transfer',
      'evm/erc20-transfer',
      'utxo/payment-with-memo',
      'cosmos/bank-send',
      'cosmos/msg-deposit',
      'solana/serialized-tx',
      'sui/serialized-tx',
      'solana/deposit-transfer',
      'sui/deposit-transfer',
      'xrp/deposit-transfer',
      'tron/deposit-transfer',
      'near/deposit-transfer',
      'hypercore/deposit-transfer',
      'cardano/deposit-transfer',
      'other/deposit-transfer',
    };
    if (!known.contains('$family/$mode')) {
      throw const FormatException('unsupported execution family/mode');
    }
  }

  String encode() => json.encode(toJson());

  Map<String, dynamic> toJson() => {
        'version': version,
        'family': family,
        'mode': mode,
        'sourceChain': sourceChain,
        'sourceToken': sourceToken,
        'nativeToken': nativeToken,
        'destinationChain': destinationChain,
        'destinationToken': destinationToken,
        if (routeProvider != null) 'routeProvider': routeProvider,
        if (subprovider != null) 'subprovider': subprovider,
        if (privateIntent != null) 'privateIntent': privateIntent,
        'payload': payload,
      };
}

String _required(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! String || value.isEmpty) throw FormatException('$key is required');
  return value;
}

String? _optional(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty) throw FormatException('$key must be a string');
  return value;
}

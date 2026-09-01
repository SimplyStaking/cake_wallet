import 'dart:convert';

class TradeExecution {
  factory TradeExecution({
    required String family,
    required String mode,
    required String sourceChain,
    required String sourceToken,
    required String nativeToken,
    required String destinationChain,
    required String destinationToken,
    required Map<String, dynamic> payload,
    String? routeProvider,
    String? subprovider,
    Object? privateIntent,
    int version = 1,
  }) {
    final execution = TradeExecution._(
      family: family,
      mode: mode,
      sourceChain: sourceChain,
      sourceToken: sourceToken,
      nativeToken: nativeToken,
      destinationChain: destinationChain,
      destinationToken: destinationToken,
      payload: _freezeMap(payload),
      routeProvider: routeProvider,
      subprovider: subprovider,
      privateIntent: privateIntent,
      version: version,
    );
    execution.validate();
    return execution;
  }

  TradeExecution._({
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
    const keys = {
      'version',
      'family',
      'mode',
      'sourceChain',
      'sourceToken',
      'nativeToken',
      'destinationChain',
      'destinationToken',
      'routeProvider',
      'subprovider',
      'privateIntent',
      'payload',
    };
    if (map.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('execution contains unknown fields');
    }
    final version = map['version'];
    if (version is! int || version != 1) {
      throw const FormatException('unsupported execution version');
    }
    final payload = map['payload'];
    if (payload is! Map) throw const FormatException('execution payload must be an object');
    return TradeExecution(
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

  void validateFamilyMode() => validate();

  void validate() {
    if (version != 1 || family.isEmpty || mode.isEmpty) {
      throw const FormatException('invalid execution envelope');
    }
    if (sourceChain.isEmpty ||
        sourceToken.isEmpty ||
        nativeToken.isEmpty ||
        destinationChain.isEmpty ||
        destinationToken.isEmpty) {
      throw const FormatException('execution asset metadata is required');
    }
    if (routeProvider != null && routeProvider!.isEmpty ||
        subprovider != null && subprovider!.isEmpty) {
      throw const FormatException('execution route metadata must not be blank');
    }
    if (privateIntent != null && privateIntent is! bool && privateIntent is! String) {
      throw const FormatException('invalid private intent');
    }
    if (privateIntent is String && (privateIntent as String).isEmpty) {
      throw const FormatException('invalid private intent');
    }
    final key = '$family/$mode';
    final allowed = switch (key) {
      'evm/contract-call' => _validateEvmContractCall(payload),
      'evm/native-transfer' => _validateEvmNativeTransfer(payload),
      'evm/erc20-transfer' => _validateEvmErc20Transfer(payload),
      'utxo/payment-with-memo' =>
        _validatePayment(payload, const {'to', 'amount', 'memo', 'gasRate'}),
      'cosmos/bank-send' => _validatePayment(payload, const {'to', 'amount', 'memo'}),
      'cosmos/msg-deposit' => _validateCosmosDeposit(payload),
      'solana/serialized-tx' || 'sui/serialized-tx' => _validateSerialized(payload),
      'solana/deposit-transfer' ||
      'sui/deposit-transfer' ||
      'xrp/deposit-transfer' ||
      'tron/deposit-transfer' ||
      'near/deposit-transfer' ||
      'hypercore/deposit-transfer' ||
      'cardano/deposit-transfer' =>
        _validatePayment(payload, const {'to', 'amount', 'memo'}),
      'other/deposit-transfer' =>
        _validatePayment(payload, const {'chain', 'to', 'amount', 'memo'}),
      _ => false,
    };
    if (!allowed) throw const FormatException('invalid execution payload');
  }

  String encode() => json.encode(toJson());

  Map<String, dynamic> toJson() {
    validate();
    return {
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
}

bool _validateEvmContractCall(Map<String, dynamic> payload) {
  if (!_hasExactKeys(payload, const {
    'chainId',
    'to',
    'data',
    'value',
    'gasLimit',
    'memo',
    'approval',
    'transferAmount'
  })) return false;
  return _validChainId(payload['chainId']) &&
      _nonEmpty(payload['to']) &&
      _validCalldata(payload['data']) &&
      _validTokenAmountOrNull(payload['value']) &&
      _stringOrNull(payload['gasLimit']) &&
      _stringOrNull(payload['memo']) &&
      _validApprovalOrNull(payload['approval']) &&
      payload['transferAmount'] == null;
}

bool _validateEvmNativeTransfer(Map<String, dynamic> payload) {
  if (!_hasExactKeys(payload, const {
    'chainId',
    'to',
    'data',
    'value',
    'gasLimit',
    'memo',
    'approval',
    'transferAmount'
  })) return false;
  return _validChainId(payload['chainId']) &&
      _nonEmpty(payload['to']) &&
      payload['data'] == null &&
      _validTokenAmount(payload['value']) &&
      _stringOrNull(payload['gasLimit']) &&
      _stringOrNull(payload['memo']) &&
      payload['approval'] == null &&
      payload['transferAmount'] == null;
}

bool _validateEvmErc20Transfer(Map<String, dynamic> payload) {
  if (!_hasExactKeys(payload, const {
    'chainId',
    'to',
    'data',
    'value',
    'gasLimit',
    'memo',
    'approval',
    'transferAmount'
  })) return false;
  return _validChainId(payload['chainId']) &&
      _nonEmpty(payload['to']) &&
      payload['data'] == null &&
      payload['value'] == null &&
      _stringOrNull(payload['gasLimit']) &&
      _stringOrNull(payload['memo']) &&
      payload['approval'] == null &&
      _validTokenAmount(payload['transferAmount']);
}

bool _validatePayment(Map<String, dynamic> payload, Set<String> keys) =>
    _hasExactKeys(payload, keys) &&
    _nonEmpty(payload['to']) &&
    _validTokenAmount(payload['amount']) &&
    _stringOrNull(payload['memo']) &&
    (keys.contains('gasRate') ? _stringOrNull(payload['gasRate']) : true) &&
    (keys.contains('chain') ? _nonEmpty(payload['chain']) : true);

bool _validateCosmosDeposit(Map<String, dynamic> payload) =>
    _validatePayment(payload, const {'to', 'amount', 'memo', 'asset', 'assetDecimals'}) &&
    _nonEmpty(payload['asset']) &&
    payload['assetDecimals'] is int &&
    (payload['assetDecimals'] as int) >= 0;

bool _validateSerialized(Map<String, dynamic> payload) =>
    _hasExactKeys(payload, const {'serializedTransaction', 'minOut'}) &&
    _nonEmpty(payload['serializedTransaction']) &&
    _validTokenAmountOrNull(payload['minOut']);

bool _hasExactKeys(Map<String, dynamic> map, Set<String> keys) =>
    map.length == keys.length && map.keys.toSet().containsAll(keys);

bool _validChainId(Object? value) => value is int && value > 0;
bool _nonEmpty(Object? value) => value is String && value.isNotEmpty;
bool _stringOrNull(Object? value) => value == null || value is String;

bool _validCalldata(Object? value) =>
    value is String &&
    value.startsWith('0x') &&
    value.length > 2 &&
    value.substring(2).length.isEven &&
    RegExp(r'^[0-9a-fA-F]+$').hasMatch(value.substring(2));

bool _validTokenAmountOrNull(Object? value) => value == null || _validTokenAmount(value);

bool _validTokenAmount(Object? value) {
  if (value is! Map) return false;
  final map = Map<String, dynamic>.from(value);
  return _hasExactKeys(map, const {'display', 'baseUnits'}) &&
      _nonEmpty(map['display']) &&
      _nonEmpty(map['baseUnits']) &&
      RegExp(r'^[0-9]+$').hasMatch(map['baseUnits'] as String) &&
      RegExp(r'^[0-9]+(?:\.[0-9]+)?$').hasMatch(map['display'] as String);
}

bool _validApprovalOrNull(Object? value) {
  if (value == null) return true;
  if (value is! Map) return false;
  final map = Map<String, dynamic>.from(value);
  if (!_hasExactKeys(map, const {'spender', 'tokenAddress', 'amount'})) return false;
  return _nonEmpty(map['spender']) &&
      _nonEmpty(map['tokenAddress']) &&
      _validTokenAmount(map['amount']);
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

Map<String, dynamic> _freezeMap(Map<dynamic, dynamic> value) {
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw const FormatException('execution payload keys must be strings');
    }
    result[entry.key as String] = _freezeValue(entry.value);
  }
  return Map<String, dynamic>.unmodifiable(result);
}

Object? _freezeValue(Object? value) {
  if (value is Map) return _freezeMap(value);
  if (value is List) return List<Object?>.unmodifiable(value.map(_freezeValue));
  return value;
}

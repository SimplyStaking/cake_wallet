import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';

Map<String, dynamic> _evmPayload({String mode = 'contract-call'}) => {
      'chainId': 1,
      'to': '0x0000000000000000000000000000000000000005',
      'data': mode == 'contract-call' ? '0xabcdef' : null,
      'value': mode == 'native-transfer' ? {'display': '1', 'baseUnits': '1'} : null,
      'gasLimit': '250000',
      'memo': null,
      'approval': null,
      'transferAmount': mode == 'erc20-transfer' ? {'display': '1', 'baseUnits': '1'} : null,
    };

TradeExecution _execution(
        {String family = 'evm', String mode = 'contract-call', Map<String, dynamic>? payload}) =>
    TradeExecution(
      family: family,
      mode: mode,
      sourceChain: 'ETH',
      sourceToken: 'ETH',
      nativeToken: 'ETH',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      payload: payload ?? _evmPayload(mode: mode),
    );

void main() {
  test('round trips a valid immutable execution envelope', () {
    final execution = _execution(mode: 'native-transfer');
    final reloaded = TradeExecution.fromJsonString(execution.encode());
    expect(reloaded.toJson(), execution.toJson());
    expect(
      () => reloaded.payload['value'] = 'changed',
      throwsUnsupportedError,
    );
  });

  test('accepts every execution variant with its authoritative payload shape', () {
    expect(
      () => _execution(mode: 'native-transfer'),
      returnsNormally,
    );
    expect(
      () => _execution(mode: 'erc20-transfer'),
      returnsNormally,
    );
    expect(
      () => _execution(
        family: 'cosmos',
        mode: 'msg-deposit',
        payload: {
          'to': 'cosmos-destination',
          'amount': {'display': '1', 'baseUnits': '1'},
          'memo': null,
          'asset': 'THOR.RUNE',
          'assetDecimals': 8,
        },
      ),
      returnsNormally,
    );
    expect(
      () => _execution(
        family: 'solana',
        mode: 'serialized-tx',
        payload: {'serializedTransaction': 'base58-tx', 'minOut': null},
      ),
      returnsNormally,
    );
  });

  test('rejects incomplete, contradictory, and unknown payload fields', () {
    final payload = _evmPayload();
    payload['data'] = null;
    expect(() => _execution(payload: payload), throwsFormatException);

    final native = _evmPayload(mode: 'native-transfer');
    native['data'] = '0xdeadbeef';
    expect(() => _execution(mode: 'native-transfer', payload: native), throwsFormatException);

    final unknown = _evmPayload()..['unexpected'] = true;
    expect(() => _execution(payload: unknown), throwsFormatException);
  });

  test('rejects unknown execution family and version', () {
    final value = {
      'version': 1,
      'family': 'future',
      'mode': 'future',
      'sourceChain': 'ETH',
      'sourceToken': 'ETH',
      'nativeToken': 'ETH',
      'destinationChain': 'BTC',
      'destinationToken': 'BTC',
      'payload': <String, dynamic>{},
    };
    expect(() => TradeExecution.fromJson(value), throwsFormatException);
    expect(
      () => TradeExecution.fromJson({...value, 'version': 2}),
      throwsFormatException,
    );
  });

  test('keeps malformed persisted data outside the dispatch model', () {
    expect(() => TradeExecution.fromJsonString('{"version":1}'), throwsA(isA<Object>()));
    expect(json.decode(_execution().encode()), isA<Map<String, dynamic>>());
  });
}

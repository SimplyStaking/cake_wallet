import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';

void main() {
  test('round trips exact execution envelope and route metadata', () {
    final execution = TradeExecution(
      family: 'evm',
      mode: 'contract-call',
      sourceChain: 'ETH',
      sourceToken: 'USDC-0x0000000000000000000000000000000000000004',
      nativeToken: 'ETH',
      destinationChain: 'BTC',
      destinationToken: 'BTC',
      routeProvider: 'openocean',
      subprovider: 'fixture-dex',
      privateIntent: false,
      payload: {
        'to': '0x0000000000000000000000000000000000000005',
        'data': '0xabcdef',
        'value': {'display': '0', 'baseUnits': '000'},
      },
    );

    final reloaded = TradeExecution.fromJsonString(execution.encode());
    expect(reloaded.toJson(), execution.toJson());
    expect(reloaded.payload['value']['baseUnits'], '000');
    expect(
      () => reloaded.payload['value']['baseUnits'] = 'changed',
      throwsUnsupportedError,
    );
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
      () => TradeExecution.fromJson(
          {...value, 'version': 2, 'family': 'evm', 'mode': 'native-transfer'}),
      throwsFormatException,
    );
  });

  test('keeps malformed persisted data outside the dispatch model', () {
    expect(() => TradeExecution.fromJsonString('{"version": 1}'), throwsA(isA<Object>()));
    expect(
        json.decode(TradeExecution(
          family: 'other',
          mode: 'deposit-transfer',
          sourceChain: 'XMR',
          sourceToken: 'XMR',
          nativeToken: 'XMR',
          destinationChain: 'BTC',
          destinationToken: 'BTC',
          payload: const {},
        ).encode()),
        isA<Map<String, dynamic>>());
  });
}

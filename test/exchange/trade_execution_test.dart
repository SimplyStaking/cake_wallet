import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/trade_execution.dart';

TradeExecutionBinding _binding() => TradeExecutionBinding(
      tradeId: 'trade-fixture',
      providerRaw: 17,
      quoteId: 'quote-fixture',
      quoteExpiresAt: DateTime.utc(2099),
      routeExpiry: null,
      sourceAmount: '1',
      sourceAmountBaseUnits: '1',
      sourceDecimals: 0,
      destinationDecimals: 8,
      senderAddress: 'sender',
      refundAddress: null,
      destinationAddress: 'destination',
      isSendAll: false,
      walletId: 'wallet-fixture',
      walletChainId: 1,
      walletAddress: 'sender',
      reviewedRouteJson:
          '{"provider":"instaswap","providerType":"fixture","subprovider":null,"private":false,"expectedOutput":"0.99","fees":null,"estimatedTimeSeconds":0,"memo":null,"inboundAddress":null,"router":null,"minAmount":null,"expiry":null,"gasRate":null,"resolvedFee":null,"openOceanRoute":null}',
      providerReferenceId: null,
    );

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
      binding: _binding(),
      routeProvider: 'instaswap',
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
        payload: {'serializedTransaction': '3MN', 'minOut': null},
      ),
      returnsNormally,
    );
    final payment = {
      'to': 'destination',
      'amount': {'display': '1', 'baseUnits': '1'},
      'memo': null,
    };
    for (final family in const ['solana', 'sui', 'xrp', 'tron', 'near', 'hypercore', 'cardano']) {
      expect(
        () => _execution(family: family, mode: 'deposit-transfer', payload: {...payment}),
        returnsNormally,
      );
    }
    expect(
      () => _execution(
        family: 'utxo',
        mode: 'payment-with-memo',
        payload: {...payment, 'gasRate': null},
      ),
      returnsNormally,
    );
    expect(
      () => _execution(
        family: 'cosmos',
        mode: 'bank-send',
        payload: {...payment},
      ),
      returnsNormally,
    );
    expect(
      () => _execution(
        family: 'cosmos',
        mode: 'msg-deposit',
        payload: {...payment, 'asset': 'THOR.RUNE', 'assetDecimals': 8},
      ),
      returnsNormally,
    );
    expect(
      () => _execution(
        family: 'sui',
        mode: 'serialized-tx',
        payload: {'serializedTransaction': 'dHh4', 'minOut': null},
      ),
      returnsNormally,
    );
    expect(
      () => _execution(
        family: 'other',
        mode: 'deposit-transfer',
        payload: {...payment, 'chain': 'XMR'},
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

  test('rejects missing and unknown binding fields', () {
    final missing = _execution().toJson()..remove('binding');
    expect(() => TradeExecution.fromJson(missing), throwsFormatException);
    final providerMissing = _execution().toJson()..remove('routeProvider');
    expect(() => TradeExecution.fromJson(providerMissing), throwsFormatException);
    final routeMissing = _execution().toJson();
    (routeMissing['binding'] as Map<String, dynamic>).remove('reviewedRouteJson');
    expect(() => TradeExecution.fromJson(routeMissing), throwsFormatException);
    final value = _execution().toJson()..['futureField'] = true;
    expect(() => TradeExecution.fromJson(value), throwsFormatException);

    final encoded = _execution().toJson();
    final binding = encoded['binding'] as Map<String, dynamic>;
    binding['futureField'] = true;
    expect(() => TradeExecution.fromJson(encoded), throwsFormatException);
  });

  test('keeps malformed persisted data outside the dispatch model', () {
    expect(() => TradeExecution.fromJsonString('{"version":1}'), throwsA(isA<Object>()));
    expect(json.decode(_execution().encode()), isA<Map<String, dynamic>>());
  });
}

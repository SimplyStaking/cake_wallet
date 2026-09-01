import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/trade_refund.dart';

void main() {
  test('separates configured refund intent from observed evidence', () {
    final refund = TradeRefund(
      configuredAddress: 'configured-address',
      observedAddress: 'observed-address',
      status: 'broadcasting',
      chain: 'ETH',
      amount: '1',
      originalAmount: '1.1',
      feeDeducted: '0.1',
      feeDescription: 'network fee',
      txHash: 'refund-hash',
    );
    final reloaded = TradeRefund.fromJsonString(refund.encode());
    expect(reloaded.configuredAddress, 'configured-address');
    expect(reloaded.observedAddress, 'observed-address');
    expect(reloaded.status, 'broadcasting');
  });

  test('permits terminal refund without observed evidence', () {
    final refund = TradeRefund(terminalWithoutEvidence: true);
    expect(TradeRefund.fromJsonString(refund.encode()).terminalWithoutEvidence, isTrue);
  });

  test('rejects unknown refund version', () {
    expect(() => TradeRefund.fromJson({'version': 2}), throwsFormatException);
  });
}

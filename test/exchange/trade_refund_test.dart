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
    expect(
      () => TradeRefund.fromJson({'version': 1, 'terminalWithoutEvidence': 'true'}),
      throwsFormatException,
    );
  });

  test('rejects unknown current-version envelope fields', () {
    final value = TradeRefund(terminalWithoutEvidence: true).toJson()..['futureField'] = true;
    expect(() => TradeRefund.fromJson(value), throwsFormatException);
  });

  test('rejects partial and contradictory refund states', () {
    expect(
      () => TradeRefund(status: 'pending', chain: 'ETH'),
      throwsFormatException,
    );
    expect(
      () => TradeRefund(
        terminalWithoutEvidence: true,
        status: 'completed',
      ),
      throwsFormatException,
    );
    expect(
      () => TradeRefund(
        status: 'pending',
        chain: 'ETH',
        amount: '1',
        originalAmount: '1',
        feeDeducted: '0',
        feeDescription: 'none',
        observedAddress: 'address',
        completedAt: 'now',
      ),
      throwsFormatException,
    );
  });

  test('terminal refund without evidence discards stale evidence', () {
    final pending = TradeRefund(
      status: 'pending',
      chain: 'ETH',
      amount: '1',
      originalAmount: '1',
      feeDeducted: '0',
      feeDescription: 'none',
      observedAddress: 'configured',
    );
    final terminal = TradeRefund(terminalWithoutEvidence: true);
    final merged = pending.merge(terminal);
    expect(merged.terminalWithoutEvidence, isTrue);
    expect(merged.status, isNull);
    expect(merged.observedAddress, isNull);
  });

  test('preserves configured refund intent when polling reports a different address', () {
    final current = TradeRefund(configuredAddress: 'configured-address');
    final update = TradeRefund(
      configuredAddress: 'polling-address',
      terminalWithoutEvidence: true,
    );
    expect(current.merge(update).configuredAddress, 'configured-address');

    final filled = TradeRefund().merge(TradeRefund(configuredAddress: 'polling-address'));
    expect(filled.configuredAddress, 'polling-address');
  });
}

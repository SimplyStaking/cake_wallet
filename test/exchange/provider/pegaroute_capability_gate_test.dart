import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_capability_gate.dart';

void main() {
  test('Phase 1 has no execution capability', () {
    const gate = PegarouteCapabilityGate();
    final route =
        PegarouteRoute(provider: 'instaswap', expectedOutput: '1', providerType: 'aggregator');
    expect(gate.hasExecutionHandlers, isFalse);
    expect(gate.supportsRoute(route), isFalse);
    expect(
        gate.supportsExecution(PegarouteExecution(
          family: 'other',
          mode: 'deposit-transfer',
          chain: 'XMR',
          to: 'destination',
          amount: PegarouteTokenAmount(display: '1', baseUnits: '1'),
        )),
        isFalse);
  });
}

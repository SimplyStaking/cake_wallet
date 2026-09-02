import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_api.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_capability_gate.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_configuration.dart';
import 'package:cake_wallet/exchange/provider/pegaroute_exchange_provider.dart';

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

  test('never reports availability without registered handlers', () {
    final provider = PegarouteExchangeProvider(
      configuration: const PegarouteConfiguration(
        baseUrl: 'https://example.test',
        apiKey: 'test',
      ),
      capabilityGate: const PegarouteCapabilityGate(
        supportedExecutionKeys: {'evm/native-transfer'},
      ),
    );
    expect(provider.isAvailable, isFalse);
  });
}

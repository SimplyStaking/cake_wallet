import 'pegaroute_api.dart';

class PegarouteCapabilityGate {
  const PegarouteCapabilityGate({this.supportedExecutionKeys = const {}});

  final Set<String> supportedExecutionKeys;

  bool supportsExecution(PegarouteExecution execution) =>
      supportedExecutionKeys.contains('${execution.family}/${execution.mode}');

  bool supportsRoute(PegarouteRoute route) => false;

  // Phase 1 has no registered handlers, regardless of declarative capability
  // metadata supplied by a future integration.
  bool get hasExecutionHandlers => false;
}

import 'pegaroute_api.dart';

class PegarouteCapabilityGate {
  const PegarouteCapabilityGate({this.supportedExecutionKeys = const {}});

  final Set<String> supportedExecutionKeys;

  bool supportsExecution(PegarouteExecution execution) =>
      supportedExecutionKeys.contains('${execution.family}/${execution.mode}');

  bool supportsRoute(PegarouteRoute route) => false;

  bool get hasExecutionHandlers => supportedExecutionKeys.isNotEmpty;
}

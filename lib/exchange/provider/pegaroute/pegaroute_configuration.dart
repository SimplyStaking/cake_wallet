import 'dart:io';

class PegarouteConfiguration {
  const PegarouteConfiguration({
    required this.baseUrl,
    @Deprecated('Proxy authentication is server-side') String? apiKey,
  });

  // The Cake-operated proxy supplies authentication server-side.
  factory PegarouteConfiguration.generated() => const PegarouteConfiguration(baseUrl: '');

  final String baseUrl;

  Uri? get origin {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      return null;
    }
    if (uri.userInfo.isNotEmpty || uri.query.isNotEmpty || uri.fragment.isNotEmpty) return null;
    if (uri.path.isNotEmpty && uri.path != '/') return null;
    if (uri.scheme == 'http' && !_isLoopback(uri.host)) return null;

    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null);
  }

  bool get isValid => origin != null;

  static bool _isLoopback(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost' || normalized == '::1' || normalized == '[::1]') return true;
    final address = InternetAddress.tryParse(normalized);
    if (address == null || address.type != InternetAddressType.IPv4) return false;
    return address.rawAddress.first == 127;
  }
}

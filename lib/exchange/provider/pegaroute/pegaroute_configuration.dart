import 'package:cake_wallet/.secrets.g.dart' as secrets;

class PegarouteConfiguration {
  const PegarouteConfiguration({required this.baseUrl, required this.apiKey});

  factory PegarouteConfiguration.generated() => const PegarouteConfiguration(
        baseUrl: secrets.pegarouteApiBaseUrl,
        apiKey: secrets.pegarouteApiKey,
      );

  final String baseUrl;
  final String apiKey;

  Uri? get origin {
    final key = apiKey.trim();
    if (key.isEmpty || key.contains(RegExp(r'[\x00-\x1f\x7f]'))) return null;

    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      return null;
    }
    if (uri.userInfo.isNotEmpty || uri.query.isNotEmpty || uri.fragment.isNotEmpty) return null;
    if (uri.path.isNotEmpty && uri.path != '/') return null;
    if (uri.scheme == 'http' && !_isLoopback(uri.host)) return null;

    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  bool get isValid => origin != null;

  static bool _isLoopback(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1' ||
        normalized == '[::1]';
  }
}

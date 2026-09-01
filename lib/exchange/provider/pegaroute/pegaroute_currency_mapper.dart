import 'package:cake_wallet/utils/token_utilities.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/spl_token.dart';
import 'package:cw_core/tron_token.dart';

class PegarouteCurrencyException implements Exception {
  const PegarouteCurrencyException(this.message);

  final String message;

  @override
  String toString() => 'Unsupported Pegaroute currency: $message';
}

class PegarouteAssetId {
  const PegarouteAssetId({required this.chain, required this.token, required this.nativeToken});

  final String chain;
  final String token;
  final String nativeToken;
}

class PegarouteCurrencyMapper {
  const PegarouteCurrencyMapper();

  static const nativeTokenByChain = <String, String>{
    'ETH': 'ETH',
    'BSC': 'BNB',
    'POLYGON': 'POL',
    'AVAX': 'AVAX',
    'ARBITRUM': 'ETH',
    'BASE': 'ETH',
    'BTC': 'BTC',
    'BCH': 'BCH',
    'LTC': 'LTC',
    'DOGE': 'DOGE',
    'DASH': 'DASH',
    'ZEC': 'ZEC',
    'XMR': 'XMR',
    'XRP': 'XRP',
    'TRON': 'TRX',
    'SOL': 'SOL',
    'NEAR': 'NEAR',
    'HYPERCORE': 'HYPE',
    'CARDANO': 'ADA',
  };

  static String nativeTokenForChain(String chain) {
    final native = nativeTokenByChain[chain.trim().toUpperCase()];
    if (native == null) throw PegarouteCurrencyException('unknown chain $chain');
    return native;
  }

  PegarouteAssetId map(CryptoCurrency currency) {
    // Explicit token instances must win over title/tag aliases. A token can
    // legitimately share a native ticker (for example a wrapped asset).
    if (currency is Erc20Token) {
      return _evmToken(currency.title, currency.contractAddress, currency.tag, currency.chainId);
    }
    if (currency is SPLToken) return _solanaToken(currency.title, currency.mintAddress);
    if (currency is TronToken) return _tronToken(currency.title, currency.contractAddress);

    final tag = currency.tag?.toUpperCase();
    final title = currency.title.toUpperCase();
    final native = _native(tag, title);
    if (native != null) return native;

    final erc20 = TokenUtilities.findErc20TokenForSwap(currency);
    if (erc20 != null)
      return _evmToken(erc20.title, erc20.contractAddress, erc20.tag, erc20.chainId);
    final mint = TokenUtilities.findSolanaTokenMint(currency);
    if (mint != null) return _solanaToken(currency.title, mint);
    final tronContract = TokenUtilities.findTronTokenContract(currency);
    if (tronContract != null) return _tronToken(currency.title, tronContract);

    throw PegarouteCurrencyException('${currency.title}/${currency.tag ?? ''}');
  }

  PegarouteAssetId? _native(String? tag, String title) {
    if (tag == 'ARB' && title == 'ETH')
      return const PegarouteAssetId(chain: 'ARBITRUM', token: 'ETH', nativeToken: 'ETH');
    if (tag == 'AVAXC' && title == 'AVAX')
      return const PegarouteAssetId(chain: 'AVAX', token: 'AVAX', nativeToken: 'AVAX');
    if (tag == 'POL' && title == 'POL')
      return const PegarouteAssetId(chain: 'POLYGON', token: 'POL', nativeToken: 'POL');
    if (title == 'TRX' && (tag == null || tag == 'TRX'))
      return const PegarouteAssetId(chain: 'TRON', token: 'TRX', nativeToken: 'TRX');
    if (title == 'ADA' && (tag == null || tag == 'ADA' || tag == 'CARDANO'))
      return const PegarouteAssetId(chain: 'CARDANO', token: 'ADA', nativeToken: 'ADA');
    if (title == 'XRP' && (tag == null || tag == 'XRP'))
      return const PegarouteAssetId(chain: 'XRP', token: 'XRP', nativeToken: 'XRP');
    if (title == 'NEAR' && (tag == null || tag == 'NEAR'))
      return const PegarouteAssetId(chain: 'NEAR', token: 'NEAR', nativeToken: 'NEAR');
    if (tag == 'BSC' && title == 'BNB')
      return const PegarouteAssetId(chain: 'BSC', token: 'BNB', nativeToken: 'BNB');
    if (tag == 'BASE' && title == 'ETH')
      return const PegarouteAssetId(chain: 'BASE', token: 'ETH', nativeToken: 'ETH');
    if (title == 'ETH' && (tag == null || tag == 'ETH'))
      return const PegarouteAssetId(chain: 'ETH', token: 'ETH', nativeToken: 'ETH');
    if (title == 'SOL' && (tag == null || tag == 'SOL'))
      return const PegarouteAssetId(chain: 'SOL', token: 'SOL', nativeToken: 'SOL');

    const nativeChains = {'XMR', 'BTC', 'BCH', 'LTC', 'DOGE', 'DASH', 'ZEC'};
    if (nativeChains.contains(title) && (tag == null || tag == title)) {
      return PegarouteAssetId(chain: title, token: title, nativeToken: title);
    }
    if ((title == 'TZEC' || title == 'ZZEC') && tag == 'ZEC') {
      return const PegarouteAssetId(chain: 'ZEC', token: 'ZEC', nativeToken: 'ZEC');
    }
    return null;
  }

  PegarouteAssetId _evmToken(String symbol, String contract, String? tag, int? chainId) {
    if (contract.isEmpty) throw const PegarouteCurrencyException('missing EVM contract');
    final chain = _chainFromTagOrId(tag, chainId);
    return PegarouteAssetId(
      chain: chain,
      token: '${symbol.toUpperCase()}-${contract.toLowerCase()}',
      nativeToken: _nativeForChain(chain),
    );
  }

  PegarouteAssetId _solanaToken(String symbol, String mint) {
    if (mint.isEmpty) throw const PegarouteCurrencyException('missing Solana mint');
    return PegarouteAssetId(
        chain: 'SOL', token: '${symbol.toUpperCase()}-$mint', nativeToken: 'SOL');
  }

  PegarouteAssetId _tronToken(String symbol, String contract) {
    if (contract.isEmpty) throw const PegarouteCurrencyException('missing TRON contract');
    return PegarouteAssetId(
        chain: 'TRON', token: '${symbol.toUpperCase()}-$contract', nativeToken: 'TRX');
  }

  String _chainFromTagOrId(String? tag, int? chainId) {
    const ids = {
      1: 'ETH',
      56: 'BSC',
      137: 'POLYGON',
      43114: 'AVAX',
      42161: 'ARBITRUM',
      8453: 'BASE'
    };
    final byId = chainId == null ? null : ids[chainId];
    final byTag = _chainAliases[tag?.toUpperCase()];
    if (byId != null && byTag != null && byId != byTag) {
      throw const PegarouteCurrencyException('conflicting chain tag and chain id');
    }
    final chain = byId ?? byTag;
    if (chain == null) throw const PegarouteCurrencyException('missing EVM chain identity');
    return chain;
  }

  String _nativeForChain(String chain) {
    return nativeTokenForChain(chain);
  }

  static const _chainAliases = {
    'ARB': 'ARBITRUM',
    'ARBITRUM': 'ARBITRUM',
    'AVAXC': 'AVAX',
    'AVAX': 'AVAX',
    'POL': 'POLYGON',
    'POLYGON': 'POLYGON',
    'TRX': 'TRON',
    'TRON': 'TRON',
    'ETH': 'ETH',
    'BSC': 'BSC',
    'BASE': 'BASE',
  };
}

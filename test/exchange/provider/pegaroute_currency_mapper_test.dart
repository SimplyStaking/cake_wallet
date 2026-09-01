import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_currency_mapper.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/erc20_token.dart';

void main() {
  const mapper = PegarouteCurrencyMapper();

  test('maps native aliases to exact canonical identifiers', () {
    expect(mapper.map(CryptoCurrency.avaxc).chain, 'AVAX');
    expect(mapper.map(CryptoCurrency.avaxc).token, 'AVAX');
    expect(mapper.map(CryptoCurrency.maticpoly).chain, 'POLYGON');
    expect(mapper.map(CryptoCurrency.maticpoly).token, 'POL');
    expect(mapper.map(CryptoCurrency.trx).chain, 'TRON');
    expect(mapper.map(CryptoCurrency.bnb).chain, 'BSC');
  });

  test('preserves exact contract-qualified EVM identity', () {
    final token = Erc20Token(
      name: 'Fixture',
      symbol: 'FIX',
      contractAddress: '0x00000000000000000000000000000000000000Ab',
      decimal: 6,
      tag: 'ETH',
    );
    final asset = mapper.map(token);
    expect(asset.chain, 'ETH');
    expect(asset.token, 'FIX-0x00000000000000000000000000000000000000ab');
  });

  test('does not mistake a token ticker for a native asset', () {
    final token = Erc20Token(
      name: 'Wrapped fixture',
      symbol: 'ETH',
      contractAddress: '0x00000000000000000000000000000000000000Ab',
      decimal: 18,
      tag: 'ETH',
    );
    final asset = mapper.map(token);
    expect(asset.token, 'ETH-0x00000000000000000000000000000000000000ab');
  });

  test('rejects missing or conflicting token identity', () {
    expect(
      () => mapper.map(Erc20Token(
        name: 'Fixture',
        symbol: 'FIX',
        contractAddress: '',
        decimal: 6,
        tag: 'ETH',
      )),
      throwsA(isA<PegarouteCurrencyException>()),
    );
    expect(
      () => mapper.map(Erc20Token(
        name: 'Fixture',
        symbol: 'FIX',
        contractAddress: '0x00000000000000000000000000000000000000ab',
        decimal: 6,
        tag: 'ETH',
        chainId: 137,
      )),
      throwsA(isA<PegarouteCurrencyException>()),
    );
    expect(
      () => mapper.map(Erc20Token(
        name: 'Fixture',
        symbol: 'FIX',
        contractAddress: '0xabc',
        decimal: 6,
        tag: 'ETH',
      )),
      throwsA(isA<PegarouteCurrencyException>()),
    );
  });
}

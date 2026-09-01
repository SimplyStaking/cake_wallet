import 'package:flutter_test/flutter_test.dart';
import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_currency_mapper.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/spl_token.dart';
import 'package:cw_core/tron_token.dart';

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
      name: 'USD Coin',
      symbol: 'USDC',
      contractAddress: '0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
      decimal: 6,
      tag: 'ETH',
    );
    final asset = mapper.map(token);
    expect(asset.chain, 'ETH');
    expect(asset.token, 'USDC-0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48');
  });

  test('rejects syntactically valid but non-catalog EVM identities', () {
    final token = Erc20Token(
      name: 'Fixture',
      symbol: 'FIX',
      contractAddress: '0x00000000000000000000000000000000000000Ab',
      decimal: 18,
      tag: 'ETH',
    );
    expect(() => mapper.map(token), throwsA(isA<PegarouteCurrencyException>()));
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
    expect(
      () => mapper.map(Erc20Token(
        name: 'Fixture',
        symbol: 'USDC',
        contractAddress: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
        decimal: 6,
        tag: 'ETH',
        chainId: 10,
      )),
      throwsA(isA<PegarouteCurrencyException>()),
    );
  });

  test('maps cataloged Stellar and THOR natives', () {
    expect(mapper.map(CryptoCurrency.xlm).token, 'XLM');
    expect(mapper.map(CryptoCurrency.rune).token, 'RUNE');
  });

  test('rejects unsupported native and case-sensitive token identities', () {
    expect(() => mapper.map(CryptoCurrency.near), throwsA(isA<PegarouteCurrencyException>()));
    expect(() => mapper.map(CryptoCurrency.ltcmweb), throwsA(isA<PegarouteCurrencyException>()));
    expect(
      () => mapper.map(SPLToken(
        name: 'Fixture',
        symbol: 'FIX',
        mintAddress: 'MintAddress123',
        decimal: 6,
        mint: 'fix',
      )),
      throwsA(isA<PegarouteCurrencyException>()),
    );
    expect(
      () => mapper.map(TronToken(
        name: 'USDT',
        symbol: 'USDT',
        contractAddress: 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t',
        decimal: 6,
      )),
      throwsA(isA<PegarouteCurrencyException>()),
    );
  });
}

import 'dart:io';

import 'package:cw_core/db/sqlite.dart';
import 'package:cw_core/root_dir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Future<Set<Object?>> _migrateFrom(int? oldVersion) async {
  final root = await Directory.systemTemp.createTemp('pegaroute-trade-migration-');
  addTearDown(() => root.delete(recursive: true));
  PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
  Directory('${root.path}/cake_wallet').createSync(recursive: true);
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final appDir = await getAppDir();
  if (oldVersion != null) {
    final oldDb = await openDatabase(
      '${appDir.path}/cake.db',
      version: oldVersion,
      onCreate: (database, _) async {
        await database.execute('''
CREATE TABLE Trade (
  tradeId INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL,
  providerRaw INTEGER NOT NULL DEFAULT 0,
  fromTitle TEXT, fromTag TEXT, fromDecimals INTEGER,
  amount TEXT NOT NULL DEFAULT '',
  stateRaw TEXT NOT NULL DEFAULT ''
)
''');
        if (oldVersion >= 11) {
          await database.execute('ALTER TABLE Trade ADD COLUMN executionJson TEXT');
          await database.execute('ALTER TABLE Trade ADD COLUMN refundJson TEXT');
        }
        if (oldVersion >= 12) {
          await database.execute('ALTER TABLE Trade ADD COLUMN executionLifecycleJson TEXT');
        }
        await database.insert('Trade', {
          'id': 'legacy-token-trade',
          'providerRaw': 17,
          'amount': '1',
          'stateRaw': 'created',
          'fromTitle': 'USDC',
          'fromTag': 'ETH',
          'fromDecimals': 6,
          if (oldVersion >= 11) ...{
            'executionJson': ' legacy execution bytes ',
            'refundJson': ' legacy refund bytes ',
          },
          if (oldVersion >= 12) 'executionLifecycleJson': ' legacy lifecycle bytes ',
        });
      },
    );
    await oldDb.close();
  }

  await initDb();
  final columns = await db!.rawQuery('PRAGMA table_info(Trade)');
  final names = columns.map((row) => row['name']).toSet();
  expect(await db!.getVersion(), 13);
  if (oldVersion != null) {
    final legacy = (await db!.query('Trade')).single;
    expect(legacy['id'], 'legacy-token-trade');
    expect(legacy['tradeId'], 1);
    expect(legacy['fromAssetIdentityJson'], isNull);
    expect(legacy['toAssetIdentityJson'], isNull);
    expect(legacy['fromTitle'], 'USDC');
    expect(legacy['fromTag'], 'ETH');
    expect(legacy['fromDecimals'], 6);
    if (oldVersion >= 11) {
      expect(legacy['executionJson'], ' legacy execution bytes ');
      expect(legacy['refundJson'], ' legacy refund bytes ');
    }
    if (oldVersion >= 12) {
      expect(legacy['executionLifecycleJson'], ' legacy lifecycle bytes ');
    }
  }
  await db!.close();
  db = null;
  return names;
}

void main() {
  test('fresh Trade schema contains canonical asset identity columns', () async {
    final names = await _migrateFrom(null);
    expect(names, containsAll({'fromAssetIdentityJson', 'toAssetIdentityJson'}));
  });

  test('migrates version 12 without inventing identity for legacy token rows', () async {
    final names = await _migrateFrom(12);
    expect(names, containsAll({'fromAssetIdentityJson', 'toAssetIdentityJson'}));
  });

  test('migrates Trade version 11 to the execution lifecycle column', () async {
    final names = await _migrateFrom(11);
    expect(names, contains('executionLifecycleJson'));
  });

  test('preserves the version 10 Phase 1 envelope migration', () async {
    final names = await _migrateFrom(10);
    expect(
      names,
      containsAll({'senderAddress', 'executionJson', 'refundJson', 'executionLifecycleJson'}),
    );
  });
}

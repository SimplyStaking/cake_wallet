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

void main() {
  test('migrates Trade version 11 to the execution lifecycle column', () async {
    final root = await Directory.systemTemp.createTemp('pegaroute-trade-migration-');
    addTearDown(() => root.delete(recursive: true));
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    Directory('${root.path}/cake_wallet').createSync(recursive: true);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final appDir = await getAppDir();
    final oldDb = await openDatabase(
      '${appDir.path}/cake.db',
      version: 11,
      onCreate: (database, _) async {
        await database.execute('''
CREATE TABLE Trade (
  tradeId INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL,
  providerRaw INTEGER NOT NULL DEFAULT 0,
  amount TEXT NOT NULL DEFAULT '',
  stateRaw TEXT NOT NULL DEFAULT ''
)
''');
      },
    );
    await oldDb.close();

    await initDb();
    final columns = await db!.rawQuery('PRAGMA table_info(Trade)');
    final names = columns.map((row) => row['name']).toSet();
    expect(names, contains('executionLifecycleJson'));

    await db!.close();
    db = null;
  });
}

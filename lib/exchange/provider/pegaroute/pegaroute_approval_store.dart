import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cw_core/db/sqlite.dart';
import 'package:sqflite/sqflite.dart';

import 'pegaroute_execution_binding.dart';
import 'pegaroute_execution_lifecycle_store.dart';

/// Separate from the funding lifecycle: these hashes must never become Trade.txId.
/// The additive table is created on first approval use, including upgraded DBs.
final class PegarouteApprovalStore {
  const PegarouteApprovalStore();
  static const table = 'PegarouteApproval';

  Future<List<Map<String, Object?>>> read(ValidatedTradeExecution execution) => _withTrade(
      execution,
      (txn, trade) => txn.query(table,
          where: 'tradeId = ?', whereArgs: [trade.internalId], orderBy: 'step DESC'));

  Future<void> begin(ValidatedTradeExecution execution, String step, String hash) async {
    await _withTrade(execution, (txn, trade) async {
      final rows = await txn.query(table, where: 'tradeId = ?', whereArgs: [trade.internalId]);
      if (rows.any((row) => row['step'] == step || row['state'] != 'confirmed')) {
        throw const TradeExecutionPrerequisiteException(
            'An approval was already started. Reopen this swap to check its confirmation.');
      }
      await txn.insert(table,
          {'tradeId': trade.internalId, 'step': step, 'transactionHash': hash, 'state': 'pending'});
    });
  }

  Future<void> finish(
      ValidatedTradeExecution execution, String step, String hash, String state) async {
    await _withTrade(execution, (txn, trade) async {
      final changed = await txn.update(table, {'state': state},
          where: 'tradeId = ? AND step = ? AND transactionHash = ? AND state = ?',
          whereArgs: [trade.internalId, step, hash, 'pending']);
      if (changed != 1) {
        final rows = await txn.query(table,
            where: 'tradeId = ? AND step = ? AND transactionHash = ? AND state = ?',
            whereArgs: [trade.internalId, step, hash, state]);
        if (rows.length != 1) throw StateError('Pegaroute approval progress changed');
      }
    });
  }

  /// Called inside the final funding transaction, preventing a race with a
  /// separately prepared approval. begin() checks the funding row in turn.
  static Future<void> requireSettled(DatabaseExecutor txn, int tradeId) async {
    final rows = await txn
        .query(table, where: 'tradeId = ? AND state != ?', whereArgs: [tradeId, 'confirmed']);
    if (rows.isNotEmpty)
      throw const TradeExecutionPrerequisiteException(
          'Approval confirmation is incomplete. Reopen this swap to check its progress.');
  }

  Future<T> _withTrade<T>(ValidatedTradeExecution execution,
      Future<T> Function(Transaction txn, Trade trade) action) async {
    final database = db;
    if (database == null) throw StateError('Pegaroute database is unavailable');
    final result = await database.transaction((txn) async {
      await txn.execute('CREATE TABLE IF NOT EXISTS $table ('
          'tradeId INTEGER NOT NULL, step TEXT NOT NULL, transactionHash TEXT NOT NULL, '
          'state TEXT NOT NULL, PRIMARY KEY (tradeId, step))');
      final rows = await txn.query(Trade.tableName,
          where: 'id = ? AND providerRaw = ?',
          whereArgs: [
            execution.execution.binding.tradeId,
            ExchangeProviderDescription.pegaroute.raw
          ]);
      if (rows.length != 1) throw StateError('Bound Pegaroute trade is missing');
      final trade = Trade.fromSqliteRow(rows.single);
      const PegarouteExecutionBindingValidator()
          .validatePersisted(trade: trade, expectedRawExecutionJson: execution.rawExecutionJson);
      PegarouteExecutionLifecycleStore.requireFundingEligible(trade,
          isRefundRaw: rows.single['isRefund']);
      if (trade.executionLifecycleJson != null)
        throw const TradeExecutionPrerequisiteException(
            'Swap funding was already started. No further approval will be submitted.');
      return action(txn, trade);
    });
    return result;
  }
}

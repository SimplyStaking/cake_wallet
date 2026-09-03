import 'package:cake_wallet/exchange/provider/pegaroute/pegaroute_execution_binding.dart';
import 'package:cake_wallet/exchange/exchange_provider_description.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_execution_dispatcher.dart';
import 'package:cake_wallet/exchange/trade_execution_lifecycle.dart';
import 'package:cw_core/db/sqlite.dart';

/// SQLite-backed lifecycle bookkeeping for a future registered execution
/// handler. Each transition compares the complete bound execution row so a
/// stale UI or wallet context cannot advance another attempt.
final class PegarouteExecutionLifecycleStore implements TradeExecutionLifecycleHandler {
  PegarouteExecutionLifecycleStore({DateTime Function()? clock}) : _clock = clock;

  final DateTime Function()? _clock;

  DateTime get _now => (_clock ?? DateTime.now)().toUtc();

  @override
  Future<void> beforeBroadcast({
    required ValidatedTradeExecution execution,
    required String executionHash,
    required int tradeInternalId,
  }) async {
    await _transition(
      execution: execution,
      executionHash: executionHash,
      tradeInternalId: tradeInternalId,
      transition: (current, at) {
        final prepared = current ??
            TradeExecutionLifecycle(
              executionHash: executionHash,
              state: TradeExecutionLifecycleState.prepared,
              callbackState: TradeExecutionCallbackState.pending,
              createdAt: at,
            );
        if (prepared.executionHash != executionHash) {
          throw const PegarouteBindingException('lifecycle execution identity changed');
        }
        return prepared.beginBroadcast(at);
      },
    );
  }

  @override
  Future<void> onBroadcasted({
    required ValidatedTradeExecution execution,
    required String executionHash,
    required int tradeInternalId,
  }) async {
    await _transition(
      execution: execution,
      executionHash: executionHash,
      tradeInternalId: tradeInternalId,
      transition: (current, at) => _advance(
        current: current,
        executionHash: executionHash,
        next: (value) => value.markBroadcasted(at),
      ),
    );
  }

  @override
  Future<void> onBroadcastUnknown({
    required ValidatedTradeExecution execution,
    required String executionHash,
    required int tradeInternalId,
  }) async {
    await _transition(
      execution: execution,
      executionHash: executionHash,
      tradeInternalId: tradeInternalId,
      transition: (current, at) => _advance(
        current: current,
        executionHash: executionHash,
        next: (value) => value.markBroadcastUnknown(at),
      ),
    );
  }

  @override
  Future<void> onBroadcastAborted({
    required ValidatedTradeExecution execution,
    required String executionHash,
    required int tradeInternalId,
  }) async {
    await _transition(
      execution: execution,
      executionHash: executionHash,
      tradeInternalId: tradeInternalId,
      transition: (current, at) => _advance(
        current: current,
        executionHash: executionHash,
        next: (value) => value.markBroadcastAborted(at),
      ),
    );
  }

  Future<void> markCallbackAttempted({
    required ValidatedTradeExecution execution,
    required String executionHash,
    required int tradeInternalId,
  }) async {
    await _transition(
      execution: execution,
      executionHash: executionHash,
      tradeInternalId: tradeInternalId,
      transition: (current, at) => _advance(
        current: current,
        executionHash: executionHash,
        next: (value) => value.markCallbackAttempted(at),
      ),
    );
  }

  Future<void> markCallbackAccepted({
    required ValidatedTradeExecution execution,
    required String executionHash,
    required int tradeInternalId,
  }) async {
    await _transition(
      execution: execution,
      executionHash: executionHash,
      tradeInternalId: tradeInternalId,
      transition: (current, at) => _advance(
        current: current,
        executionHash: executionHash,
        next: (value) => value.markCallbackAccepted(at),
      ),
    );
  }

  TradeExecutionLifecycle _advance({
    required TradeExecutionLifecycle? current,
    required String executionHash,
    required TradeExecutionLifecycle Function(TradeExecutionLifecycle value) next,
  }) {
    if (current == null || current.executionHash != executionHash) {
      throw const PegarouteBindingException('lifecycle row is missing or mismatched');
    }
    return next(current);
  }

  Future<void> _transition({
    required ValidatedTradeExecution execution,
    required String executionHash,
    required int tradeInternalId,
    required TradeExecutionLifecycle Function(TradeExecutionLifecycle? current, String at)
        transition,
  }) async {
    if (tradeInternalId <= 0) {
      throw const PegarouteBindingException('Pegaroute lifecycle trade is not persisted');
    }
    final database = db;
    if (database == null)
      throw const PegarouteBindingException('Pegaroute database is unavailable');
    final at = _now.toIso8601String();
    await database.transaction((txn) async {
      final rows = await txn.query(
        Trade.tableName,
        where: '${Trade.selfIdColumn} = ? AND id = ? AND providerRaw = ?',
        whereArgs: [
          tradeInternalId,
          execution.execution.binding.tradeId,
          ExchangeProviderDescription.pegaroute.raw,
        ],
        limit: 1,
      );
      if (rows.isEmpty) throw const PegarouteBindingException('bound Pegaroute trade is missing');
      final row = Trade.fromSqliteRow(rows.single);
      if (row.executionJson != execution.rawExecutionJson) {
        throw const PegarouteBindingException('bound execution changed before broadcast');
      }
      const validator = PegarouteExecutionBindingValidator();
      validator.validatePersisted(trade: row, expectedRawExecutionJson: execution.rawExecutionJson);
      final oldJson = row.executionLifecycleJson;
      final current = oldJson == null ? null : TradeExecutionLifecycle.fromJsonString(oldJson);
      final next = transition(current, at);
      final expected = row.toSqliteMap()..remove(Trade.selfIdColumn);
      final predicates = <String>['${Trade.selfIdColumn} = ?'];
      final predicateArgs = <Object?>[tradeInternalId];
      for (final entry in expected.entries) {
        if (entry.value == null) {
          predicates.add('${entry.key} IS NULL');
        } else {
          predicates.add('${entry.key} = ?');
          predicateArgs.add(entry.value);
        }
      }
      final changed = await txn.update(
        Trade.tableName,
        {'executionLifecycleJson': next.encode()},
        where: predicates.join(' AND '),
        whereArgs: predicateArgs,
      );
      if (changed != 1) throw const PegarouteBindingException('lifecycle row changed concurrently');
    });
  }
}

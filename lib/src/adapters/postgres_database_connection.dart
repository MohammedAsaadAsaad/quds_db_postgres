import 'dart:async';
import 'package:postgres/postgres.dart';
import 'package:quds_db_interface/quds_db_interface.dart';

class PostgresDatabaseConnection extends DatabaseConnection {
  final Pool _pool;
  static final _transactionKey = Object();
  bool _isClosed = false;

  PostgresDatabaseConnection(this._pool);

  @override
  bool get isOpen => _pool.isOpen && !_isClosed;

  Session _getConnection() {
    final activeTx = Zone.current[_transactionKey];
    if (activeTx != null) {
      return activeTx as Session;
    }
    return _pool;
  }

  @override
  Future<void> close() async {
    _isClosed = true;
    // Pool handles true closing via the adapter
  }

  @override
  Future<int> execute(String sql, [List<dynamic>? parameters]) async {
    final conn = _getConnection();
    var outQuery = [sql];
    final params = _convertToNamedParams(sql, parameters ?? [], outQuery);
    final result = await conn.execute(Sql.named(outQuery[0]), parameters: params);
    return result.affectedRows;
  }

  @override
  Future<List<Map<String, dynamic>>> query(String sql, [List<dynamic>? parameters]) async {
    final conn = _getConnection();
    var outQuery = [sql];
    final params = _convertToNamedParams(sql, parameters ?? [], outQuery);
    final result = await conn.execute(Sql.named(outQuery[0]), parameters: params);
    
    return result.map((row) {
      final map = <String, dynamic>{};
      for (var i = 0; i < result.schema.columns.length; i++) {
        map[result.schema.columns[i].columnName ?? 'col$i'] = row[i];
      }
      return map;
    }).toList();
  }

  @override
  Future<int?> insert(String tableName, Map<String, dynamic> values) async {
    final keys = values.keys.map((k) => '"$k"').join(', ');
    final placeholders = values.keys.map((_) => '?').join(', ');
    final sql = 'INSERT INTO "$tableName" ($keys) VALUES ($placeholders) RETURNING *';
    
    final conn = _getConnection();
    var outQuery = [sql];
    final params = _convertToNamedParams(sql, values.values.toList(), outQuery);
    
    // Attempt to extract the ID from the RETURNING clause if it exists
    final result = await conn.execute(Sql.named(outQuery[0]), parameters: params);
    if (result.isNotEmpty) {
      try {
        final row = result.first;
        // Postgres returns values ordered by column schema. If 'id' is present, we try to return it.
        for (var i = 0; i < result.schema.columns.length; i++) {
          if (result.schema.columns[i].columnName?.toLowerCase() == 'id') {
            final idVal = row[i];
            if (idVal is int) return idVal;
            if (idVal is String) return int.tryParse(idVal);
          }
        }
      } catch (_) {}
    }
    return result.affectedRows > 0 ? 1 : null;
  }

  @override
  Future<int> update(String tableName, Map<String, dynamic> values, String where, [List<dynamic>? parameters]) async {
    final assignments = values.keys.map((k) => '"$k" = ?').join(', ');
    final sql = 'UPDATE "$tableName" SET $assignments WHERE $where';
    
    final paramsList = values.values.toList();
    if (parameters != null) {
      paramsList.addAll(parameters);
    }
    
    final conn = _getConnection();
    var outQuery = [sql];
    final params = _convertToNamedParams(sql, paramsList, outQuery);
    final result = await conn.execute(Sql.named(outQuery[0]), parameters: params);
    return result.affectedRows;
  }

  @override
  Future<int> delete(String tableName, String where, [List<dynamic>? parameters]) async {
    final sql = 'DELETE FROM "$tableName" WHERE $where';
    final conn = _getConnection();
    var outQuery = [sql];
    final params = _convertToNamedParams(sql, parameters ?? [], outQuery);
    final result = await conn.execute(Sql.named(outQuery[0]), parameters: params);
    return result.affectedRows;
  }

  @override
  Future<T> transaction<T>(Future<T> Function() operation) async {
    if (Zone.current[_transactionKey] != null) {
      return await operation(); // Already in transaction
    }
    
    return await _pool.runTx((ctx) async {
      return await runZoned(
        () async => await operation(),
        zoneValues: {_transactionKey: ctx},
      );
    });
  }

  Map<String, dynamic> _convertToNamedParams(String sql, List<dynamic> params, List<String> outQuery) {
    if (params.isEmpty && !sql.contains('?')) {
      return {};
    }
    var queryBuffer = StringBuffer();
    var mappedParams = <String, dynamic>{};
    int paramIndex = 0;
    bool inString = false;
    
    for (int i = 0; i < sql.length; i++) {
      var char = sql[i];
      if (char == "'") {
        inString = !inString;
        queryBuffer.write(char);
      } else if (char == '?' && !inString) {
        if (paramIndex < params.length) {
          var paramName = 'p$paramIndex';
          queryBuffer.write('@$paramName');
          
          var val = params[paramIndex];
          if (val is DateTime) val = val.millisecondsSinceEpoch;
          if (val is bool) val = val ? 1 : 0;
          
          mappedParams[paramName] = val;
          paramIndex++;
        } else {
          queryBuffer.write(char); 
        }
      } else {
        queryBuffer.write(char);
      }
    }
    outQuery[0] = queryBuffer.toString();
    return mappedParams;
  }
}

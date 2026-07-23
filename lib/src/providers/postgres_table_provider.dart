import 'dart:async';
import 'package:quds_db_interface/quds_db_interface.dart';
import '../adapters/postgres_database_connection.dart';
import '../builders/postgres_query_builder.dart';
import '../schema/postgres_schema_utils.dart';

class PostgresTableProvider<T extends DbModel>
    implements TableProvider<T>, TableProviderContract<T> {
  final PostgresDatabaseConnection connection;
  @override
  T Function() get modelFactory => () {
        final model = _modelFactory();
        for (var field in model.getAllFields()) {
          if (field is FieldWithValue && field.columnName != null) {
            field.queryBuilder = () => '"${field.columnName}"';
          }
        }
        return model;
      };
  final T Function() _modelFactory;
  final String _tableName;
  final List<void Function(EntryChangeType, T)> _listeners = [];

  late final T _cachedModelInstance = modelFactory();

  PostgresTableProvider(this.connection, this._modelFactory, this._tableName);

  Map<String, dynamic> _unsanitizeMap(
    Map<String, dynamic> map,
    List<FieldDefinition> fields,
  ) {
    final result = Map<String, dynamic>.from(map);
    for (var field in fields) {
      if (field is FieldWithValue) {
        final key = field.jsonMapName ?? field.columnName;
        if (key != null && result.containsKey(key)) {
          final val = result[key];
          if (val != null) {
            if (val is String) {
              if (field.valueType == int) {
                result[key] = int.tryParse(val);
              } else if (field.valueType == double) {
                result[key] = double.tryParse(val);
              } else if (field.valueType == num) {
                result[key] = num.tryParse(val);
              } else if (field.valueType == bool) {
                result[key] = (val == '1' || val.toLowerCase() == 'true');
              } else if (field.valueType == DateTime) {
                var ms = int.tryParse(val);
                if (ms != null) {
                  result[key] = DateTime.fromMillisecondsSinceEpoch(ms);
                } else {
                  result[key] = DateTime.tryParse(val);
                }
              }
            } else {
              if (field.valueType == bool) {
                result[key] = (val == 1 || val == true);
              } else if (field.valueType == DateTime && val is int) {
                result[key] = DateTime.fromMillisecondsSinceEpoch(val);
              }
            }
          }
        }
      }
    }
    return result;
  }

  T _modelFromMap(Map<String, dynamic> map) {
    final model = modelFactory();
    final fields = model.getAllFields();
    final unsanitizedMap = _unsanitizeMap(map, fields);

    if (model is StandardDbModel) {
      for (var field in fields) {
        if (field is FieldWithValue) {
          final key = field.jsonMapName ?? field.columnName;
          if (key != null && unsanitizedMap.containsKey(key)) {
            field.value = unsanitizedMap[key];
          }
        }
      }
      if (unsanitizedMap.containsKey('id')) {
        model.id.value = unsanitizedMap['id'] as int?;
      }
      if (unsanitizedMap.containsKey('creationTime')) {
        model.creationTime.value = unsanitizedMap['creationTime'] as DateTime?;
      }
      if (unsanitizedMap.containsKey('modificationTime')) {
        model.modificationTime.value =
            unsanitizedMap['modificationTime'] as DateTime?;
      }
    } else {
      model.fromMap(unsanitizedMap);
    }
    return model;
  }

  void _notifyListeners(EntryChangeType changeType, T entry) {
    for (var listener in _listeners) {
      listener(changeType, entry);
    }
  }

  @override
  void addEntryChangeListener(
    void Function(EntryChangeType changeType, T entry) listener,
  ) {
    _listeners.add(listener);
  }

  @override
  void removeEntryChangeListener(
    void Function(EntryChangeType changeType, T entry) listener,
  ) {
    _listeners.remove(listener);
  }

  T get modelInstance => _cachedModelInstance;

  @override
  String get tableName => _tableName;

  String _mapToPostgresColumnDef(FieldDefinition field) {
    return PostgresSchemaUtils.mapToColumnDef(field);
  }

  @override
  Future<void> ensureField(FieldDefinition field, {bool safe = false}) async {
    try {
      await connection.migration.ensureField(tableName, field);
    } catch (e) {
      if (safe) {
        // ignore: avoid_print
        print('Migration warning ($tableName.${field.columnName}): $e');
      } else {
        rethrow;
      }
    }
  }

  @override
  Future<void> ensureBooleanNotNull(BoolField field, {bool safe = false}) async {
    await connection.migration.ensureBooleanNotNull(
      tableName,
      field,
      safe: safe,
    );
  }

  @override
  Future<void> initialize() async {
    final fields = _cachedModelInstance.getFields() ?? [];
    if (fields.isEmpty) return;

    var columns = fields
        .map((f) => _mapToPostgresColumnDef(f))
        .join(', ');

    if (_cachedModelInstance is StandardDbModel) {
      final stdCols = [
        '"id" BIGSERIAL PRIMARY KEY',
        '"serverId" BIGINT',
        '"creationTime" BIGINT',
        '"modificationTime" BIGINT',
      ];
      columns = '${stdCols.join(', ')}, $columns';
    }

    final createTableSql = 'CREATE TABLE IF NOT EXISTS "$tableName" ($columns)';
    await connection.execute(createTableSql);

    for (var field in _cachedModelInstance.getAllFields()) {
      await connection.migration.ensureField(tableName, field);
    }
  }

  @override
  Future<int?> insertEntry(T entry, {bool notifyListeners = true}) async {
    final map = entry.toMap();
    map.remove('id');

    if (entry is StandardDbModel) {
      final nowDT = DateTime.now();
      final now = nowDT.millisecondsSinceEpoch;
      map['creationTime'] = now;
      map['modificationTime'] = now;
      entry.creationTime.value = nowDT;
      entry.modificationTime.value = nowDT;
    }

    final id = await connection.insert(tableName, map);
    if (id != null) {
      if (entry is StandardDbModel) {
        entry.id.value = id;
      }
      if (notifyListeners) {
        _notifyListeners(EntryChangeType.insertion, entry);
      }
    }
    return id;
  }

  @override
  Future<List<int?>> insertCollection(List<T> entries) async {
    if (entries.isEmpty) return [];

    final ids = await connection.transaction(() async {
      final ids = <int?>[];
      for (var entry in entries) {
        final id = await insertEntry(entry, notifyListeners: false);
        ids.add(id);
      }
      return ids;
    });

    for (var entry in entries) {
      _notifyListeners(EntryChangeType.insertion, entry);
    }
    return ids;
  }

  @override
  Future<bool> updateEntry(T entry) async {
    if (entry is! StandardDbModel) return false;
    final stdEntry = entry as StandardDbModel;
    if (stdEntry.id.value == null) return false;

    final map = entry.toMap();
    map.remove('id');
    map.remove('creationTime');

    final nowDT = DateTime.now();
    final now = nowDT.millisecondsSinceEpoch;
    map['modificationTime'] = now;
    stdEntry.modificationTime.value = nowDT;

    final updated = await connection.update(tableName, map, '"id" = ?', [
      stdEntry.id.value,
    ]);

    if (updated > 0) {
      _notifyListeners(EntryChangeType.modification, entry);
      return true;
    }
    return false;
  }

  @override
  Future<bool> deleteEntry(T entry) async {
    if (entry is! StandardDbModel) return false;
    final stdEntry = entry as StandardDbModel;
    if (stdEntry.id.value == null) return false;

    final deleted = await connection.delete(tableName, '"id" = ?', [
      stdEntry.id.value,
    ]);

    if (deleted > 0) {
      _notifyListeners(EntryChangeType.deletion, entry);
      return true;
    }
    return false;
  }

  @override
  Future<int> clear() async {
    final count = await connection.delete(tableName, '1=1');
    if (count > 0) {
      _notifyListeners(EntryChangeType.deletion, modelInstance);
    }
    return count;
  }

  @override
  Future<bool> drop() async {
    try {
      await connection.execute('DROP TABLE IF EXISTS "$tableName"');
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int> deleteWhere(Condition Function(T model)? where) async {
    if (where == null) return await clear();

    final condition = where(modelInstance);
    final count = await connection.delete(
      tableName,
      condition.buildQuery(),
      condition.getParameters(),
    );

    if (count > 0) {
      _notifyListeners(EntryChangeType.deletion, modelInstance);
    }
    return count;
  }

  @override
  Future<List<T>> select({
    Condition Function(T model)? where,
    List<FieldOrder> Function(T model)? orderBy,
    List<FieldDefinition> Function(T model)? desiredFields,
    int? limit,
    int? offset,
  }) async {
    var q = query();

    if (desiredFields != null) {
      q = q.select(desiredFields(_cachedModelInstance));
    }

    if (where != null) {
      q = q.where(where(_cachedModelInstance));
    }

    if (orderBy != null) {
      q = q.orderBy(orderBy(_cachedModelInstance));
    }

    if (limit != null) {
      q = q.limit(limit, offset);
    }

    final rows = await q.executeRaw();
    return rows.map((row) => _modelFromMap(row)).toList();
  }

  @override
  Future<DataPageQueryResult<T>> loadAllEntriesByPaging({
    required DataPageQuery<T> pageQuery,
    Condition Function(T model)? where,
    List<FieldOrder> Function(T model)? orderBy,
    List<FieldDefinition> Function(T model)? desiredFields,
  }) async {
    final limit = pageQuery.resultsPerPage;
    final offset = (pageQuery.page - 1) * limit;

    final results = await select(
      where: where,
      orderBy: orderBy,
      desiredFields: desiredFields,
      limit: limit,
      offset: offset,
    );

    int total = await countWhere(where);

    return DataPageQueryResult<T>(total, results, pageQuery.page, limit);
  }

  @override
  Future<int> count() async {
    final result = await connection.query('SELECT COUNT(*) FROM "$tableName"');
    if (result.isNotEmpty) {
      return int.tryParse(result.first.values.first.toString()) ?? 0;
    }
    return 0;
  }

  @override
  Future<int> countWhere(Condition Function(T model)? where) async {
    if (where == null) return await count();

    final condition = where(modelInstance);
    final sql =
        'SELECT COUNT(*) FROM "$tableName" WHERE ${condition.buildQuery()}';

    final result = await connection.query(sql, condition.getParameters());
    if (result.isNotEmpty) {
      return int.tryParse(result.first.values.first.toString()) ?? 0;
    }
    return 0;
  }

  @override
  SelectQueryBuilder<T> query() {
    final builder = PostgresSelectQueryBuilder<T>(connection);
    builder.from(this);
    return builder;
  }

  @override
  AggregateQueryBuilder<T> aggregateQuery() {
    final builder = PostgresSelectQueryBuilder<T>(connection);
    builder.from(this);
    return PostgresAggregateQueryBuilder<T>(builder);
  }

  @override
  SelectQueryBuilder<T> complexQuery() {
    return PostgresSelectQueryBuilder<T>(connection);
  }

  @override
  Future<bool> closeDB() async {
    await connection.close();
    return true;
  }
}

class PostgresStandardTableProvider<T extends StandardDbModel>
    extends PostgresTableProvider<T> {
  PostgresStandardTableProvider(
    super.connection,
    super.modelFactory,
    super.tableName,
  );

  Future<T?> selectById(int id) async {
    final results = await select(
      where: (model) => model.id.equals(id),
      limit: 1,
    );
    if (results.isNotEmpty) return results.first;
    return null;
  }

  Future<bool> deleteById(int id) async {
    return (await deleteWhere((model) => model.id.equals(id))) > 0;
  }
}

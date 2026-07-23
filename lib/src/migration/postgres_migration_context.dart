import 'package:quds_db_interface/quds_db_interface.dart';
import '../adapters/postgres_database_connection.dart';
import '../schema/postgres_schema_utils.dart';

/// PostgreSQL implementation of the Dart-first [MigrationContext].
class PostgresMigrationContext implements MigrationContext {
  PostgresMigrationContext(this.connection);

  @override
  final PostgresDatabaseConnection connection;

  @override
  SchemaMigrator get migrator => connection.migration;

  @override
  SchemaInspector get inspector => connection.schema;

  static Future<void> ensureJournalTable(MigrationContext ctx) async {
    await ctx.rawSql('''
CREATE TABLE IF NOT EXISTS "${SchemaMigrationRunner.defaultJournalTableName}" (
  version BIGINT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL UNIQUE,
  applied_at BIGINT NOT NULL
)
''');
  }

  @override
  Future<void> createTable(
    String table,
    List<FieldDefinition> fields, {
    bool ifNotExists = true,
  }) async {
    _assertSafeIdent(table, 'table');
    if (fields.isEmpty) {
      throw MigrationException(
        'createTable("$table") requires at least one field.',
      );
    }

    final defs = <String>[];
    for (final field in fields) {
      final column = field.columnName;
      if (column == null || column.isEmpty) {
        throw MigrationException(
          'createTable("$table") encountered a field without columnName.',
        );
      }
      _assertSafeIdent(column, 'column');
      defs.add(_columnDefinition(field));
    }

    final existsClause = ifNotExists ? 'IF NOT EXISTS ' : '';
    await connection.execute(
      'CREATE TABLE $existsClause"$table" (${defs.join(', ')})',
    );
  }

  @override
  Future<void> dropTable(String table, {bool ifExists = true}) async {
    _assertSafeIdent(table, 'table');
    final existsClause = ifExists ? 'IF EXISTS ' : '';
    await connection.execute('DROP TABLE $existsClause"$table"');
  }

  @override
  Future<void> renameTable(String from, String to) async {
    _assertSafeIdent(from, 'table');
    _assertSafeIdent(to, 'table');
    await connection.execute('ALTER TABLE "$from" RENAME TO "$to"');
  }

  @override
  Future<void> addColumn(String table, FieldDefinition field) async {
    _assertSafeIdent(table, 'table');
    final column = field.columnName;
    if (column == null || column.isEmpty) {
      throw MigrationException('addColumn requires field.columnName.');
    }
    _assertSafeIdent(column, 'column');

    if (await inspector.columnExists(table, column)) {
      return;
    }

    await connection.execute(
      'ALTER TABLE "$table" ADD COLUMN ${_columnDefinition(field)}',
    );

    if (field is FieldWithValue && field.isIndexed) {
      await createIndex(table, column);
    }
  }

  @override
  Future<void> dropColumn(String table, String column) async {
    _assertSafeIdent(table, 'table');
    _assertSafeIdent(column, 'column');
    if (!await inspector.columnExists(table, column)) return;
    await connection.execute(
      'ALTER TABLE "$table" DROP COLUMN IF EXISTS "$column"',
    );
  }

  @override
  Future<void> renameColumn(String table, String from, String to) async {
    _assertSafeIdent(table, 'table');
    _assertSafeIdent(from, 'column');
    _assertSafeIdent(to, 'column');
    if (from == to) return;

    if (!await inspector.columnExists(table, from)) {
      throw MigrationException(
        'Cannot rename missing column "$from" on table "$table".',
      );
    }
    if (await inspector.columnExists(table, to)) {
      throw MigrationException(
        'Cannot rename "$from" to "$to": target column already exists on "$table".',
      );
    }

    await connection.execute(
      'ALTER TABLE "$table" RENAME COLUMN "$from" TO "$to"',
    );
  }

  @override
  Future<void> ensureField(String table, FieldDefinition field) {
    return migrator.ensureField(table, field);
  }

  @override
  Future<void> createIndex(
    String table,
    String column, {
    String? name,
    bool unique = false,
  }) async {
    _assertSafeIdent(table, 'table');
    _assertSafeIdent(column, 'column');
    final indexName = name ?? 'idx_${table}_$column';
    _assertSafeIdent(indexName, 'index');
    final uniqueSql = unique ? 'UNIQUE ' : '';
    await connection.execute(
      'CREATE $uniqueSql'
      'INDEX IF NOT EXISTS "$indexName" ON "$table" ("$column")',
    );
  }

  @override
  Future<void> dropIndex(String indexName, {String? table}) async {
    _assertSafeIdent(indexName, 'index');
    await connection.execute('DROP INDEX IF EXISTS "$indexName"');
  }

  @override
  Future<int> updateRows({
    required String table,
    required Map<String, Object?> Function(Map<String, dynamic> row) transform,
    String primaryKey = 'id',
    String? where,
    List<Object?>? whereArgs,
  }) async {
    _assertSafeIdent(table, 'table');
    _assertSafeIdent(primaryKey, 'primaryKey');

    final sql = StringBuffer('SELECT * FROM "$table"');
    if (where != null && where.trim().isNotEmpty) {
      sql.write(' WHERE $where');
    }
    final rows = await connection.query(sql.toString(), whereArgs);

    var updated = 0;
    for (final row in rows) {
      if (!row.containsKey(primaryKey)) {
        throw MigrationException(
          'updateRows("$table") row is missing primary key "$primaryKey".',
        );
      }
      final next = transform(Map<String, dynamic>.from(row));
      final pkValue = next.containsKey(primaryKey)
          ? next[primaryKey]
          : row[primaryKey];

      final changes = <String, Object?>{};
      next.forEach((key, value) {
        if (key == primaryKey) return;
        if (row[key] != value) {
          changes[key] = value;
        }
      });
      if (changes.isEmpty) continue;

      await connection.update(
        table,
        changes,
        '"$primaryKey" = ?',
        [pkValue],
      );
      updated++;
    }
    return updated;
  }

  @override
  Future<void> rawSql(String sql, [List<Object?>? params]) async {
    await connection.execute(sql, params);
  }

  String _columnDefinition(FieldDefinition field) {
    if (field is BoolField) {
      return PostgresSchemaUtils.mapBoolColumnDef(field);
    }
    var def = PostgresSchemaUtils.mapToColumnDef(field);
    if (field is FieldWithValue && field.value != null) {
      final upper = def.toUpperCase();
      if (!upper.contains(' DEFAULT ')) {
        def = '$def DEFAULT ${_sqlLiteral(field.value)}';
      }
    }
    return def;
  }

  String _sqlLiteral(Object? value) {
    if (value == null) return 'NULL';
    if (value is bool) return PostgresSchemaUtils.boolLiteral(value);
    if (value is num) return value.toString();
    if (value is DateTime) return value.millisecondsSinceEpoch.toString();
    final escaped = value.toString().replaceAll("'", "''");
    return "'$escaped'";
  }

  static final RegExp _safeIdent = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  void _assertSafeIdent(String value, String label) {
    if (!_safeIdent.hasMatch(value)) {
      throw MigrationException(
        'Invalid $label identifier "$value". '
        'Only letters, digits, and underscore are allowed.',
      );
    }
  }
}

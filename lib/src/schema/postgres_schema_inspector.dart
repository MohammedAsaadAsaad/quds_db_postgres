import 'package:quds_db_interface/quds_db_interface.dart';
import '../adapters/postgres_database_connection.dart';

class PostgresSchemaInspector implements SchemaInspector {
  final PostgresDatabaseConnection connection;
  static const defaultSchema = 'public';

  PostgresSchemaInspector(this.connection);

  @override
  Future<bool> tableExists(String table, {String? schema}) async {
    final result = await connection.query(
      '''
SELECT 1
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = ?
  AND c.relname = ?
  AND c.relkind IN ('r', 'p')
LIMIT 1
''',
      [schema ?? defaultSchema, table],
    );
    return result.isNotEmpty;
  }

  @override
  Future<bool> columnExists(
    String table,
    String column, {
    String? schema,
  }) async {
    final result = await connection.query(
      '''
SELECT 1
FROM pg_attribute a
JOIN pg_class c ON a.attrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = ?
  AND c.relname = ?
  AND a.attname = ?
  AND a.attnum > 0
  AND NOT a.attisdropped
LIMIT 1
''',
      [schema ?? defaultSchema, table, column],
    );
    return result.isNotEmpty;
  }

  @override
  Future<String?> columnNativeType(
    String table,
    String column, {
    String? schema,
  }) async {
    final result = await connection.query(
      '''
SELECT format_type(a.atttypid, a.atttypmod) AS pg_type
FROM pg_attribute a
JOIN pg_class c ON a.attrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = ?
  AND c.relname = ?
  AND a.attname = ?
  AND a.attnum > 0
  AND NOT a.attisdropped
''',
      [schema ?? defaultSchema, table, column],
    );
    if (result.isEmpty) return null;
    return result.first['pg_type']?.toString().toLowerCase();
  }

  @override
  Future<List<ColumnInfo>> listColumns(String table, {String? schema}) async {
    final result = await connection.query(
      '''
SELECT
  a.attname AS column_name,
  format_type(a.atttypid, a.atttypmod) AS pg_type,
  NOT a.attnotnull AS is_nullable,
  a.atthasdef AS has_default
FROM pg_attribute a
JOIN pg_class c ON a.attrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = ?
  AND c.relname = ?
  AND a.attnum > 0
  AND NOT a.attisdropped
ORDER BY a.attnum
''',
      [schema ?? defaultSchema, table],
    );

    return result
        .map(
          (row) => ColumnInfo(
            name: row['column_name']?.toString() ?? '',
            nativeType: row['pg_type']?.toString().toLowerCase() ?? '',
            isNullable: _parseBool(row['is_nullable'], defaultValue: true),
            hasDefault: _parseBool(row['has_default']),
          ),
        )
        .toList();
  }

  bool _parseBool(dynamic value, {bool defaultValue = false}) {
    if (value is bool) return value;
    if (value is int) return value != 0;
    if (value is String) {
      final lower = value.toLowerCase();
      return lower == 't' || lower == 'true' || lower == '1' || lower == 'yes';
    }
    return defaultValue;
  }
}

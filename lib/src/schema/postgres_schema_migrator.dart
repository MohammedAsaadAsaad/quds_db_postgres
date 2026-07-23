import 'package:quds_db_interface/quds_db_interface.dart';
import '../adapters/postgres_database_connection.dart';
import 'postgres_schema_inspector.dart';
import 'postgres_schema_utils.dart';

class PostgresSchemaMigrator implements SchemaMigrator {
  final PostgresDatabaseConnection connection;
  late final PostgresSchemaInspector _inspector = PostgresSchemaInspector(connection);

  PostgresSchemaMigrator(this.connection);

  @override
  SchemaInspector get inspector => _inspector;

  @override
  Future<void> ensureField(String table, FieldDefinition field) async {
    final column = field.columnName;
    if (column == null || column == 'id') return;

    if (field is BoolField) {
      if (field.notNull == true) {
        await ensureBooleanNotNull(table, field);
      } else {
        await _ensureBooleanColumn(table, field);
      }
      if (field.isIndexed) await _ensureIndex(table, field);
      return;
    }

    final exists = await _inspector.columnExists(table, column);
    if (!exists) {
      final colDef = _columnDefForAdd(field);
      await connection.execute(
        'ALTER TABLE "$table" ADD COLUMN $colDef',
      );
    } else if (field is FieldWithValue && field.notNull == true) {
      await _backfillAndSetNotNull(table, column, field.value);
    }

    if (field is FieldWithValue && field.isIndexed) {
      await _ensureIndex(table, field);
    }
  }

  @override
  Future<void> ensureBooleanNotNull(
    String table,
    BoolField field, {
    bool safe = false,
  }) async {
    try {
      await _ensureBooleanNotNullInternal(table, field);
    } catch (e) {
      if (safe) {
        // ignore: avoid_print
        print('Migration warning ($table.${field.columnName}): $e');
      } else {
        rethrow;
      }
    }
  }

  Future<void> _ensureBooleanNotNullInternal(String table, BoolField field) async {
    final column = field.columnName;
    if (column == null) return;

    final defaultValue = field.value ?? false;
    final literal = PostgresSchemaUtils.boolLiteral(defaultValue);
    final exists = await _inspector.columnExists(table, column);
    final nativeType =
        exists ? await _inspector.columnNativeType(table, column) : null;

    if (!exists) {
      await connection.execute(
        'ALTER TABLE "$table" ADD COLUMN ${PostgresSchemaUtils.mapBoolColumnDef(field)}',
      );
    } else if (!PostgresSchemaUtils.isBooleanType(nativeType)) {
      final using = PostgresSchemaUtils.booleanCoerceExpression(
        column,
        nativeType ?? 'unknown',
        literal,
      );
      await connection.execute(
        'ALTER TABLE "$table" ALTER COLUMN "$column" TYPE BOOLEAN USING ($using)',
      );
    }

    await connection.execute(
      'UPDATE "$table" SET "$column" = $literal WHERE "$column" IS NULL',
    );
    await connection.execute(
      'ALTER TABLE "$table" ALTER COLUMN "$column" SET DEFAULT $literal',
    );

    try {
      await connection.execute(
        'ALTER TABLE "$table" ALTER COLUMN "$column" SET NOT NULL',
      );
    } catch (_) {
      // Already NOT NULL.
    }
  }

  Future<void> _ensureBooleanColumn(String table, BoolField field) async {
    final column = field.columnName;
    if (column == null) return;

    final exists = await _inspector.columnExists(table, column);
    if (!exists) {
      await connection.execute(
        'ALTER TABLE "$table" ADD COLUMN ${PostgresSchemaUtils.mapBoolColumnDef(field)}',
      );
      return;
    }

    final nativeType = await _inspector.columnNativeType(table, column);
    if (!PostgresSchemaUtils.isBooleanType(nativeType)) {
      final literal = PostgresSchemaUtils.boolLiteral(field.value ?? false);
      final using = PostgresSchemaUtils.booleanCoerceExpression(
        column,
        nativeType ?? 'unknown',
        literal,
      );
      await connection.execute(
        'ALTER TABLE "$table" ALTER COLUMN "$column" TYPE BOOLEAN USING ($using)',
      );
    }
  }

  String _columnDefForAdd(FieldDefinition field) {
    if (['serverId', 'creationTime', 'modificationTime']
        .contains(field.columnName)) {
      return '"${field.columnName}" ${PostgresSchemaUtils.standardFieldColumnDef(field.columnName!)}';
    }
    return PostgresSchemaUtils.mapToColumnDef(field);
  }

  Future<void> _backfillAndSetNotNull(
    String table,
    String column,
    dynamic defaultValue,
  ) async {
    if (defaultValue != null) {
      await connection.execute(
        'UPDATE "$table" SET "$column" = ? WHERE "$column" IS NULL',
        [defaultValue],
      );
    }
    try {
      await connection.execute(
        'ALTER TABLE "$table" ALTER COLUMN "$column" SET NOT NULL',
      );
    } catch (_) {
      // Already NOT NULL.
    }
  }

  Future<void> _ensureIndex(String table, FieldWithValue field) async {
    final column = field.columnName;
    if (column == null) return;
    final indexName = 'idx_${table}_$column';
    await connection.execute(
      'CREATE INDEX IF NOT EXISTS "$indexName" ON "$table" ("$column")',
    );
  }
}

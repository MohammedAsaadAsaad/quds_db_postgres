import 'package:quds_db_interface/quds_db_interface.dart';
import 'package:quds_db_postgres/quds_db_postgres.dart';
import 'package:test/test.dart';

class SchemaNote extends StandardDbModel {
  final title = StringField(columnName: 'title', notNull: true);
  final isImportant = BoolField(columnName: 'isImportant', defaultValue: false);

  @override
  List<FieldDefinition>? getFields() => [title, isImportant];
}

class SchemaNoteProvider extends PostgresStandardTableProvider<SchemaNote> {
  SchemaNoteProvider(super.connection, super.modelFactory, super.tableName);
}

void main() {
  late PostgresDatabaseAdapter adapter;
  late PostgresDatabaseConnection connection;
  late SchemaNoteProvider provider;

  setUpAll(() async {
    adapter = PostgresDatabaseAdapter();
    await adapter.initialize(
      PostgresDatabaseSettings(
        dbName: 'test_db',
        version: 1,
        host: '127.0.0.1',
        port: 5432,
        userName: 'postgres',
        password: 'postgres',
      ),
    );

    connection = await adapter.getConnection() as PostgresDatabaseConnection;
    provider = SchemaNoteProvider(connection, () => SchemaNote(), 'schema_notes');
    await provider.initialize();
  });

  tearDown(() async {
    await connection.execute('DROP TABLE IF EXISTS pg_bool_bigint_test');
    await connection.execute('DROP TABLE IF EXISTS pg_bool_text_test');
    await connection.execute('DROP TABLE IF EXISTS pg_bool_missing_test');
    await connection.execute('DROP TABLE IF EXISTS pg_ensure_field_test');
  });

  tearDownAll(() async {
    await provider.drop();
    await adapter.close();
  });

  group('SchemaInspector', () {
    test('tableExists returns true for initialized provider table', () async {
      expect(await connection.schema.tableExists('schema_notes'), isTrue);
    });

    test('columnExists detects present and missing columns', () async {
      expect(await connection.schema.columnExists('schema_notes', 'title'), isTrue);
      expect(await connection.schema.columnExists('schema_notes', 'missing'), isFalse);
    });

    test('columnNativeType returns postgres type name', () async {
      final type = await connection.schema.columnNativeType('schema_notes', 'title');
      expect(type, isNotNull);
      expect(type, contains('text'));
    });

    test('listColumns returns metadata for all columns', () async {
      final columns = await connection.schema.listColumns('schema_notes');
      expect(columns.map((c) => c.name), contains('title'));
      expect(columns.map((c) => c.name), contains('isImportant'));
    });
  });

  group('SchemaMigrator.ensureBooleanNotNull', () {
    test('adds missing boolean column with default and NOT NULL', () async {
      await connection.execute(
        'CREATE TABLE pg_bool_missing_test (id BIGSERIAL PRIMARY KEY)',
      );

      final field = BoolField(
        columnName: 'is_active',
        defaultValue: true,
        notNull: true,
      );

      await connection.migration.ensureBooleanNotNull('pg_bool_missing_test', field);

      expect(await connection.schema.columnExists('pg_bool_missing_test', 'is_active'), isTrue);
      final type = await connection.schema.columnNativeType('pg_bool_missing_test', 'is_active');
      expect(type, anyOf(equals('boolean'), equals('bool')));

      final rows = await connection.query('SELECT is_active FROM pg_bool_missing_test');
      expect(rows, isEmpty);
    });

    test('coerces legacy bigint column to boolean', () async {
      await connection.execute(
        'CREATE TABLE pg_bool_bigint_test (legacy_flag BIGINT)',
      );
      await connection.execute(
        'INSERT INTO pg_bool_bigint_test (legacy_flag) VALUES (1), (0), (NULL)',
      );

      final field = BoolField(
        columnName: 'legacy_flag',
        defaultValue: false,
        notNull: true,
      );

      await connection.migration.ensureBooleanNotNull('pg_bool_bigint_test', field);

      final type = await connection.schema.columnNativeType('pg_bool_bigint_test', 'legacy_flag');
      expect(type, anyOf(equals('boolean'), equals('bool')));

      final rows = await connection.query(
        'SELECT legacy_flag FROM pg_bool_bigint_test ORDER BY legacy_flag DESC',
      );
      expect(rows.length, equals(3));
      expect(rows.any((r) => r['legacy_flag'] == true), isTrue);
      expect(rows.any((r) => r['legacy_flag'] == false), isTrue);
    });

    test('coerces legacy text column to boolean', () async {
      await connection.execute(
        'CREATE TABLE pg_bool_text_test (legacy_text TEXT)',
      );
      await connection.execute(
        "INSERT INTO pg_bool_text_test (legacy_text) VALUES ('true'), ('false'), ('1'), (NULL)",
      );

      final field = BoolField(
        columnName: 'legacy_text',
        defaultValue: false,
        notNull: true,
      );

      await connection.migration.ensureBooleanNotNull('pg_bool_text_test', field);

      final rows = await connection.query('SELECT legacy_text FROM pg_bool_text_test');
      expect(rows.where((r) => r['legacy_text'] == true).length, greaterThan(0));
      expect(rows.where((r) => r['legacy_text'] == false).length, greaterThan(0));
    });

    test('safe mode does not throw when column is already NOT NULL', () async {
      await connection.execute(
        'CREATE TABLE pg_bool_missing_test (flag BOOLEAN NOT NULL DEFAULT FALSE)',
      );

      final field = BoolField(
        columnName: 'flag',
        defaultValue: false,
        notNull: true,
      );

      await connection.migration.ensureBooleanNotNull(
        'pg_bool_missing_test',
        field,
        safe: true,
      );
    });
  });

  group('TableProvider schema helpers', () {
    test('ensureBooleanNotNull via provider', () async {
      final field = BoolField(
        columnName: 'isImportant',
        defaultValue: false,
        notNull: true,
      );

      await provider.ensureBooleanNotNull(field, safe: true);
      expect(await connection.schema.columnExists('schema_notes', 'isImportant'), isTrue);
    });

    test('ensureField adds a new column through migration API', () async {
      await connection.execute(
        'CREATE TABLE pg_ensure_field_test (id BIGSERIAL PRIMARY KEY)',
      );

      final nickname = StringField(columnName: 'nickname', defaultValue: 'anon');
      await connection.migration.ensureField('pg_ensure_field_test', nickname);

      expect(await connection.schema.columnExists('pg_ensure_field_test', 'nickname'), isTrue);
    });
  });
}

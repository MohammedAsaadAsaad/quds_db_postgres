import 'package:quds_db_postgres/quds_db_postgres.dart';
import 'package:test/test.dart';

List<Migration> buildTaskMigrations() {
  return [
    ClosureMigration(
      version: 1,
      name: 'create_tasks',
      up: (ctx) async {
        await ctx.createTable('mig_tasks', [
          IdField(),
          StringField(columnName: 'title', notNull: true),
          BoolField(columnName: 'isDone', defaultValue: false),
        ]);
      },
      down: (ctx) async {
        await ctx.dropTable('mig_tasks');
      },
    ),
    ClosureMigration(
      version: 2,
      name: 'add_priority',
      up: (ctx) async {
        final priority = IntField(columnName: 'priority', notNull: true)
          ..value = 0;
        await ctx.addColumn('mig_tasks', priority);
        await ctx.createIndex('mig_tasks', 'priority');
        await ctx.updateRows(
          table: 'mig_tasks',
          transform: (row) {
            final title = row['title']?.toString() ?? '';
            return {
              ...row,
              'priority': title.startsWith('URGENT') ? 10 : 0,
            };
          },
        );
      },
      down: (ctx) async {
        await ctx.dropIndex('idx_mig_tasks_priority');
        await ctx.dropColumn('mig_tasks', 'priority');
      },
    ),
    ClosureMigration(
      version: 3,
      name: 'rename_title_to_name',
      up: (ctx) async {
        await ctx.renameColumn('mig_tasks', 'title', 'name');
      },
      down: (ctx) async {
        await ctx.renameColumn('mig_tasks', 'name', 'title');
      },
    ),
  ];
}

void main() {
  late PostgresDatabaseAdapter adapter;
  late PostgresDatabaseConnection connection;

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
  });

  setUp(() async {
    await connection.execute('DROP TABLE IF EXISTS mig_tasks CASCADE');
    await connection.execute('DROP TABLE IF EXISTS mig_fail_demo CASCADE');
    await connection.execute('DROP TABLE IF EXISTS mig_name_check CASCADE');
    await connection.execute('DROP TABLE IF EXISTS mig_raw CASCADE');
    await connection.execute(
      'DROP TABLE IF EXISTS "${SchemaMigrationRunner.defaultJournalTableName}" CASCADE',
    );
  });

  tearDownAll(() async {
    await connection.execute('DROP TABLE IF EXISTS mig_tasks CASCADE');
    await connection.execute(
      'DROP TABLE IF EXISTS "${SchemaMigrationRunner.defaultJournalTableName}" CASCADE',
    );
    await adapter.close();
  });

  group('SchemaMigrationRunner (Postgres)', () {
    test('migrate applies versions in order and journals them', () async {
      final migrations = buildTaskMigrations();
      final result = await connection.migrations.migrate(migrations);

      expect(result.fromVersion, 0);
      expect(result.toVersion, 3);
      expect(result.executed.map((m) => m.version), [1, 2, 3]);
      expect(await connection.migrations.currentVersion(), 3);
      expect(await connection.schema.tableExists('mig_tasks'), isTrue);
      expect(await connection.schema.columnExists('mig_tasks', 'name'), isTrue);
      expect(
        await connection.schema.columnExists('mig_tasks', 'title'),
        isFalse,
      );
    });

    test('migrate is idempotent when already at latest', () async {
      final migrations = buildTaskMigrations();
      await connection.migrations.migrate(migrations);
      final second = await connection.migrations.migrate(migrations);
      expect(second.didChange, isFalse);
      expect(second.toVersion, 3);
    });

    test('updateRows transforms data in Dart during migration', () async {
      await connection.migrations.migrate(
        buildTaskMigrations(),
        targetVersion: 1,
      );
      await connection.insert('mig_tasks', {'title': 'URGENT a', 'isDone': false});
      await connection.insert('mig_tasks', {'title': 'b', 'isDone': false});
      await connection.migrations.migrate(
        buildTaskMigrations(),
        targetVersion: 2,
      );

      final rows = await connection.query(
        'SELECT title, priority FROM mig_tasks ORDER BY id ASC',
      );
      expect(int.parse(rows[0]['priority'].toString()), 10);
      expect(int.parse(rows[1]['priority'].toString()), 0);
    });

    test('full rollback to 0 drops created schema', () async {
      await connection.migrations.migrate(buildTaskMigrations());
      final result = await connection.migrations.rollback(
        buildTaskMigrations(),
        targetVersion: 0,
      );
      expect(result.toVersion, 0);
      expect(await connection.schema.tableExists('mig_tasks'), isFalse);
    });

    test('failed migration does not advance journal version', () async {
      final migrations = [
        ClosureMigration(
          version: 1,
          name: 'ok_create',
          up: (ctx) async {
            await ctx.createTable('mig_fail_demo', [
              IdField(),
              StringField(columnName: 'label'),
            ]);
          },
        ),
        ClosureMigration(
          version: 2,
          name: 'boom',
          up: (ctx) async {
            await ctx.addColumn(
              'mig_fail_demo',
              StringField(columnName: 'ok_col'),
            );
            throw StateError('simulated failure');
          },
        ),
      ];

      await expectLater(
        connection.migrations.migrate(migrations),
        throwsA(isA<MigrationException>()),
      );
      expect(await connection.migrations.currentVersion(), 1);
    });

    test('rawSql escape hatch is available', () async {
      final result = await connection.migrations.migrate([
        ClosureMigration(
          version: 1,
          name: 'raw_sql_case',
          up: (ctx) async {
            await ctx.createTable('mig_raw', [
              IdField(),
              IntField(columnName: 'n'),
            ]);
            await ctx.rawSql('INSERT INTO mig_raw (n) VALUES (?)', [42]);
          },
        ),
      ]);
      expect(result.toVersion, 1);
      final rows = await connection.query('SELECT n FROM mig_raw');
      expect(int.parse(rows.single['n'].toString()), 42);
    });
  });
}

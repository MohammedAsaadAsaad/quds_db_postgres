import 'package:test/test.dart';
import 'package:quds_db_postgres/quds_db_postgres.dart';
import 'package:quds_db_interface/quds_db_interface.dart';

class Note extends StandardDbModel {
  final title = StringField(columnName: 'title', notNull: true);
  final isImportant = BoolField(columnName: 'isImportant', defaultValue: false);
  final dueDate = DateTimeField(columnName: 'dueDate');

  @override
  List<FieldDefinition>? getFields() => [title, isImportant, dueDate];
}

class NoteProvider extends PostgresStandardTableProvider<Note> {
  NoteProvider(super.connection, super.modelFactory, super.tableName);
}

void main() {
  late PostgresDatabaseAdapter adapter;
  late NoteProvider provider;

  setUpAll(() async {
    adapter = PostgresDatabaseAdapter();
    await adapter.initialize(
      PostgresDatabaseSettings(
        dbName: 'test_db',
        version: 1,
        host: '127.0.0.1',
        port: 5432,
        userName: 'postgres',
        password:
            '0', // Adjust if 'postgres' is the password for the local instance
      ),
    );

    final conn = await adapter.getConnection() as PostgresDatabaseConnection;
    provider = NoteProvider(conn, () => Note(), 'notes_table');
    await provider.initialize();
  });

  tearDownAll(() async {
    await provider.drop();
    await adapter.close();
  });

  group('CRUD Operations', () {
    test('Insert and Select', () async {
      await provider.clear();

      final note = Note()
        ..title.value = 'My Postgres Note'
        ..isImportant.value = true
        ..dueDate.value = DateTime.fromMillisecondsSinceEpoch(1749360000000);

      final id = await provider.insertEntry(note);
      expect(id, isNotNull);

      final allNotes = await provider.select();
      expect(allNotes.length, equals(1));
      expect(allNotes.first.title.value, equals('My Postgres Note'));
      expect(allNotes.first.isImportant.value, equals(true));
      expect(
        allNotes.first.dueDate.value?.millisecondsSinceEpoch,
        equals(1749360000000),
      );
    });

    test('Bulk Transactions', () async {
      await provider.clear();

      final notes = List.generate(50, (i) => Note()..title.value = 'Batch \$i');
      await provider.insertCollection(notes);

      final count = await provider.count();
      expect(count, equals(50));
    });

    test('Update and Delete', () async {
      await provider.clear();
      final note = Note()..title.value = 'To Delete';
      await provider.insertEntry(note);

      expect(note.id.value, isNotNull);

      note.title.value = 'Updated Title';
      await provider.updateEntry(note);

      final selected = await provider.selectById(note.id.value!);
      expect(selected?.title.value, equals('Updated Title'));

      await provider.deleteById(note.id.value!);
      final count = await provider.count();
      expect(count, equals(0));
    });
  });
}

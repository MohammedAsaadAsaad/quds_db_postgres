# Quds DB Postgres

A robust, abstract, and highly declarative PostgreSQL database implementation for the `quds_db_interface` ecosystem.

This package provides a seamless ORM-like experience tailored explicitly for PostgreSQL databases in Dart and Flutter. Built upon the official `postgres` Dart driver, it handles database schemas, connection pooling, indexing, transaction handling, and type-safety invisibly—allowing you to focus strictly on your application's logic without ever writing raw SQL.

## Features

*   **Declarative Models:** Define your models in pure Dart; table creation, column definition, and indexing are handled automatically.
*   **Automatic Migrations:** The engine seamlessly creates databases and table structures on initialization if they do not exist.
*   **Type Safety & Type Mapping:** Built-in translations between standard SQL primitives and PostgreSQL equivalents (`BIGSERIAL`, `BIGINT`, `DOUBLE PRECISION`).
*   **Performance:** Implements native connection pooling out-of-the-box.
*   **Powerful Query Building:** Supports complex joins, aggregations, paginations, and nested conditions.
*   **Automated Transactions:** Secure bulk insertions and automated rollback handling.
*   **Reactive UI:** Listeners allow widgets to react instantly to database changes (insertions, updates, deletions).

## Getting Started

Add the following to your `pubspec.yaml` file:

```yaml
dependencies:
  quds_db_postgres: ^1.0.0
  quds_db_interface: ^1.0.0
```

## Basic Usage

### 1. Define a Database Model

Create a class extending `StandardDbModel`. Specify your columns using strictly typed fields.

```dart
import 'package:quds_db_interface/quds_db_interface.dart';

class Task extends StandardDbModel {
  final title = StringField(columnName: 'title', notNull: true);
  final isCompleted = BoolField(columnName: 'isCompleted', defaultValue: false);
  final priority = IntField(columnName: 'priority', defaultValue: 0);
  final dueDate = DateTimeField(columnName: 'dueDate');

  @override
  List<FieldDefinition>? getFields() => [title, isCompleted, priority, dueDate];
}
```

### 2. Create a Table Provider

Extend the native `PostgresStandardTableProvider` to inject your model and table name.

```dart
import 'package:quds_db_postgres/quds_db_postgres.dart';

class TaskProvider extends PostgresStandardTableProvider<Task> {
  TaskProvider(super.connection, super.modelFactory, super.tableName);
}
```

### 3. Initialize the Adapter and Provider

Set up your adapter with PostgreSQL connection details, then initialize the provider. This automatically establishes the connection pools and ensures the database exists.

```dart
void main() async {
  final adapter = PostgresDatabaseAdapter();
  
  // Establish connection settings
  await adapter.initialize(
    PostgresDatabaseSettings(
      dbName: 'quds_demo',
      version: 1,
      host: '127.0.0.1',
      port: 5432, // Default Postgres port
      userName: 'postgres',
      password: 'your_password',
    ),
  );

  final connection = await adapter.getConnection() as PostgresDatabaseConnection;

  // Initialize Provider
  final taskProvider = TaskProvider(connection, () => Task(), 'tasks_table');
  await taskProvider.initialize(); // Schema is generated and verified here
}
```

## CRUD Operations

The package offers simple, abstracted methods for standard Data operations.

### Insert Data

```dart
final task = Task()
  ..title.value = 'Finish Documentation'
  ..isCompleted.value = false
  ..dueDate.value = DateTime.now().add(Duration(days: 2));

// Insert a single entry. The ID is automatically populated on success.
await taskProvider.insertEntry(task);
```

### Query Data

Query results natively return hydrated Dart objects. You can build advanced conditions through abstract lambda functions.

```dart
// Select all tasks
final allTasks = await taskProvider.select();

// Select with condition and sorting
final pendingHighPriority = await taskProvider.select(
  where: (t) => t.isCompleted.equals(false),
  orderBy: (t) => [t.priority.descOrder],
);

// Count active records
final count = await taskProvider.countWhere(
  (t) => t.isCompleted.equals(false),
);
```

### Update Data

```dart
// Retrieve the task you wish to update
final tasks = await taskProvider.select(where: (t) => t.title.equals('Finish Documentation'));

if (tasks.isNotEmpty) {
  final task = tasks.first;
  task.isCompleted.value = true;
  
  await taskProvider.updateEntry(task);
}
```

### Delete Data

```dart
// Delete a specific entry
await taskProvider.deleteEntry(task);

// Delete entries dynamically
await taskProvider.deleteWhere((t) => t.isCompleted.equals(true));

// Empty the entire table (leaves schema intact)
await taskProvider.clear();

// Destroys the table entirely
await taskProvider.drop();
```

## Advanced Querying

### Transactions & Bulk Operations

Bulk operations natively wrap commands inside a PostgreSQL transaction block. If any insertion fails, the engine safely rolls back.

```dart
try {
  final t1 = Task()..title.value = 'Bulk 1';
  final t2 = Task()..title.value = 'Bulk 2';

  // Automatically executed inside a single transaction
  await taskProvider.insertCollection([t1, t2]);
} catch (e) {
  print('Transaction rolled back due to error.');
}
```

### Joins & Complex Queries

Use the `query()` or `complexQuery()` builders for relational datasets.

```dart
var result = taskProvider.query()
  .innerJoin(userProvider, (task, user) => task.userId.equals(user.id))
  .where((task, user) => user.isActive.isTrue)
  .executeRaw();
```

## Architectural Guidelines

The `quds_db_postgres` package accurately maps interface types to PostgreSQL syntax to preserve integrity and compatibility:
*   `INTEGER` definitions strictly translate to `BIGINT` to safely store robust 64-bit Dart primitives like `DateTime.millisecondsSinceEpoch`.
*   Standard boolean types are persisted logically.
*   Auto-incrementing primary keys are mapped to `BIGSERIAL`.
*   Field definitions intelligently utilize double-quote encapsulation (e.g., `"creationTime"`) to strictly enforce case-sensitivity, bypassing PostgreSQL's default auto-lowercase casting.

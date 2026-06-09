import 'package:postgres/postgres.dart';
import 'package:quds_db_interface/quds_db_interface.dart';
import 'postgres_database_connection.dart';

class PostgresDatabaseSettings extends DatabaseSettings {
  final String dbName;
  final int version;
  final String host;
  final int port;
  final String userName;
  final String password;

  PostgresDatabaseSettings({
    required this.dbName,
    required this.version,
    this.host = '127.0.0.1',
    this.port = 5432,
    this.userName = 'postgres',
    this.password = '',
  }) : super();
}

class PostgresDatabaseAdapter extends DatabaseAdapter {
  PostgresDatabaseSettings? _settings;
  Pool? _pool;

  @override
  Future<void> initialize(DatabaseSettings settings) async {
    _settings = settings as PostgresDatabaseSettings;

    // Connect to 'postgres' database first to ensure target dbName exists
    final defaultEndpoint = Endpoint(
      host: _settings!.host,
      port: _settings!.port,
      database: 'postgres', // default maintenance db
      username: _settings!.userName,
      password: _settings!.password,
    );

    try {
      final conn = await Connection.open(defaultEndpoint, settings: ConnectionSettings(sslMode: SslMode.disable));
      try {
        await conn.execute('CREATE DATABASE "${_settings!.dbName}"');
      } catch (e) {
        // Database probably already exists, which is fine
        final message = e.toString();
        if (!message.contains('already exists')) {
          print('Postgres database creation note: $e');
        }
      } finally {
        await conn.close();
      }
    } catch (e) {
      print('Warning: Failed to auto-create database (might not have permissions): $e');
    }

    final endpoint = Endpoint(
      host: _settings!.host,
      port: _settings!.port,
      database: _settings!.dbName,
      username: _settings!.userName,
      password: _settings!.password,
    );

    _pool = Pool.withEndpoints([endpoint], settings: PoolSettings(
      maxConnectionCount: 10,
      sslMode: SslMode.disable,
    ));
  }

  @override
  Future<DatabaseConnection> getConnection() async {
    if (_pool == null) {
      throw Exception("PostgresDatabaseAdapter not initialized.");
    }
    return PostgresDatabaseConnection(_pool!);
  }

  @override
  Future<void> close() async {
    await _pool?.close();
    _pool = null;
  }

  @override
  Future<int> rawExecute(String sql, [List<dynamic>? parameters]) async {
    final conn = await getConnection();
    return await conn.execute(sql, parameters);
  }

  @override
  Future<List<Map<String, dynamic>>> rawQuery(String sql, [List<dynamic>? parameters]) async {
    final conn = await getConnection();
    return await conn.query(sql, parameters);
  }
}

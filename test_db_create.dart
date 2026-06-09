import 'package:postgres/postgres.dart';

void main() async {
  final defaultEndpoint = Endpoint(
    host: 'localhost',
    port: 5432,
    database: 'postgres',
    username: 'postgres',
    password: 'postgres',
  );

  try {
    final conn = await Connection.open(defaultEndpoint, settings: ConnectionSettings(sslMode: SslMode.disable));
    try {
      await conn.execute('CREATE DATABASE "quds_demo_test"');
      print('Database created successfully!');
    } catch (e) {
      print('Execute error: $e');
    } finally {
      await conn.close();
    }
  } catch (e) {
    print('Connection error: $e');
  }
}

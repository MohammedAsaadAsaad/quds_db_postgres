import 'package:quds_db_interface/quds_db_interface.dart';

/// Shared PostgreSQL column-definition helpers.
class PostgresSchemaUtils {
  static String mapToColumnDef(FieldDefinition field) {
    String def = field.columnDefinition;
    if (field.columnName != null && def.startsWith(field.columnName!)) {
      def = '"${field.columnName}"' + def.substring(field.columnName!.length);
    }
    def = def.replaceAll(
      'INTEGER PRIMARY KEY AUTOINCREMENT',
      'BIGSERIAL PRIMARY KEY',
    );
    def = def.replaceAll('INTEGER', 'BIGINT');
    def = def.replaceAll('REAL', 'DOUBLE PRECISION');
    return def;
  }

  static String mapBoolColumnDef(BoolField field) {
    final parts = <String>['BOOLEAN'];
    if (field.notNull == true) parts.add('NOT NULL');
    if (field.value != null) {
      parts.add('DEFAULT ${field.value! ? 'TRUE' : 'FALSE'}');
    }
    return '"${field.columnName}" ${parts.join(' ')}';
  }

  static String boolLiteral(bool value) => value ? 'TRUE' : 'FALSE';

  static bool isBooleanType(String? nativeType) {
    if (nativeType == null) return false;
    final t = nativeType.toLowerCase();
    return t == 'boolean' || t == 'bool';
  }

  static String booleanCoerceExpression(
    String column,
    String nativeType,
    String defaultLiteral,
  ) {
    final t = nativeType.toLowerCase();
    if (t == 'bigint' ||
        t == 'int8' ||
        t == 'integer' ||
        t == 'int4' ||
        t == 'smallint' ||
        t == 'int2' ||
        t == 'numeric' ||
        t == 'double precision' ||
        t == 'real') {
      return 'CASE WHEN "$column" IS NULL THEN $defaultLiteral ELSE "$column"::int8 <> 0 END';
    }
    if (t == 'text' || t == 'character varying' || t.startsWith('varchar')) {
      return '''CASE
        WHEN "$column" IS NULL THEN $defaultLiteral
        WHEN lower(trim("$column"::text)) IN ('true', 't', '1', 'yes') THEN TRUE
        ELSE FALSE
      END''';
    }
    return 'CASE WHEN "$column" IS NULL THEN $defaultLiteral ELSE FALSE END';
  }

  static String standardFieldColumnDef(String columnName) {
    if (columnName == 'serverId' ||
        columnName == 'creationTime' ||
        columnName == 'modificationTime') {
      return 'BIGINT';
    }
    return 'BIGINT';
  }
}

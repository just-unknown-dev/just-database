# just_database Examples

This directory contains examples demonstrating various features of just_database.

## Running the Examples

### Basic Example (`example.dart`)

Demonstrates basic CRUD operations, table creation, queries, and indexes:

```bash
dart run example/example.dart
```

### Persistence Example (`persistence_example.dart`)

Shows how to use persistent storage and automatic indexing:

```bash
dart run example/persistence_example.dart
```

### Flutter Admin UI Example (`flutter_admin_example.dart`)

A complete Flutter application with the built-in admin UI:

```bash
flutter run example/flutter_admin_example.dart
```

## What Each Example Covers

### example.dart
- Creating a database
- Creating tables with constraints
- Inserting data
- Querying with WHERE clauses
- Updating records
- Creating foreign keys
- Composite indexes
- Checking table schemas
- Deleting records

### persistence_example.dart
- Creating persistent databases
- Database modes
- Automatic query-based indexing
- Index metadata and statistics
- Closing and reopening databases
- Listing all databases

### flutter_admin_example.dart
- Using the built-in Flutter admin UI
- Database provider setup
- Custom theme configuration
- Seed data integration

## Additional Resources

- [README.md](../README.md) - Full package documentation
- [API Documentation](https://pub.dev/documentation/just_database/latest/) - Detailed API reference
- [CHANGELOG.md](../CHANGELOG.md) - Version history and changes

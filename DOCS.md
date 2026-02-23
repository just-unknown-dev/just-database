# just_database Documentation

Complete documentation index for the just_database package.

## 📚 Documentation Files

### Getting Started

1. **[README.md](README.md)** - Main package documentation
   - Features overview
   - Installation instructions
   - Quick start guide
   - Usage examples
   - Performance tips
   - Limitations and roadmap

### API Reference

2. **[API.md](API.md)** - Complete API reference
   - All classes and methods
   - Parameters and return types
   - Code examples for each API
   - Best practices
   - Error handling

### Migration & Upgrades

3. **[MIGRATION.md](MIGRATION.md)** - Migration guide
   - Migrating from SQLite
   - Migrating from Hive
   - Migrating from SharedPreferences
   - Version upgrade instructions
   - Data format conversion
   - Troubleshooting

### Version History

4. **[CHANGELOG.md](CHANGELOG.md)** - Version history
   - Release notes
   - New features
   - Bug fixes
   - Breaking changes
   - Planned features

### Contributing

5. **[CONTRIBUTING.md](CONTRIBUTING.md)** - Contributor guide
   - Development setup & prerequisites
   - Project structure
   - Branch naming & Conventional Commits format
   - Code style & `flutter analyze` requirements
   - Testing guidelines & coverage targets
   - Pull request checklist
   - Versioning policy

### Examples

6. **[example/](example/)** - Working code examples
   - Basic usage example
   - Persistence example
   - Flutter admin UI example
   - README with instructions

## 🚀 Quick Links

### For New Users

Start here:
1. Read the [README.md](README.md) introduction
2. Follow the Quick Start section
3. Run the [basic example](example/example.dart)
4. Explore the [API reference](API.md) as needed

### For Migrating Users

1. Check [MIGRATION.md](MIGRATION.md) for your current database
2. If upgrading from 1.0.0, see the [version upgrade notes](MIGRATION.md#version-upgrades)
3. Review [API.md](API.md) for feature equivalents
4. Test with the [examples](example/)

### For Contributors

1. Read [CONTRIBUTING.md](CONTRIBUTING.md) — setup, branch naming, PR checklist
2. Check open issues on [GitHub](https://github.com/just-unknown-dev/just-database/issues)
3. Open a discussion before large changes

### For Advanced Users

1. Review [API.md](API.md) for advanced features
2. Check index optimization in README
3. Explore `DatabaseMode.secure` and `SecureKeyManager`
4. Review query tracking and benchmark features

## 📖 Documentation by Topic

### Database Operations

- **Creating databases:** [README#quick-start](README.md#quick-start)
- **Persistence:** [README#with-file-persistence](README.md#with-file-persistence)
- **Database modes:** [README#database-modes](README.md#database-modes)
- **API details:** [API#database-management](API.md#database-management)

### Tables & Schema

- **Creating tables:** [README#quick-start](README.md#quick-start)
- **Constraints:** [README#table-constraints](README.md#table-constraints)
- **Schema API:** [API#schema--tables](API.md#schema--tables)
- **Data types:** [API#data-types](API.md#data-types)

### Indexing

- **Basic indexes:** [README#index-management](README.md#index-management)
- **Composite indexes:** [README#composite-indexes](README.md#composite-indexes)
- **Auto-indexing:** [README#automatic-query-based-indexing](README.md#automatic-query-based-indexing)
- **API reference:** [API#indexing](API.md#indexing)

### Queries

- **SQL support:** [README#sql-support](README.md#sql-support)
- **Query results:** [API#query-execution](API.md#query-execution)
- **Examples:** [example/example.dart](example/example.dart)

### Advanced Queries

- **JOIN operations:** [README#join-operations](README.md#join-operations), [API#join-operations](API.md#join-operations)
- **Aggregate functions:** [README#aggregate-functions-and-group-by](README.md#aggregate-functions-and-group-by), [API#aggregate-functions](API.md#aggregate-functions)
- **GROUP BY & HAVING:** [README#aggregate-functions-and-group-by](README.md#aggregate-functions-and-group-by), [API#group-by-and-having](API.md#group-by-and-having)
- **ALTER TABLE:** [README#alter-table-operations](README.md#alter-table-operations), [API#alter-table-operations](API.md#alter-table-operations)

### UI Components

- **Admin UI:** [README#built-in-admin-ui](README.md#built-in-admin-ui)
- **Flutter example:** [example/flutter_admin_example.dart](example/flutter_admin_example.dart)
- **UI API:** [API#ui-components](API.md#ui-components)
- **ORM layer:** [README#orm-layer](README.md#orm-layer), [API#orm-layer](API.md#orm-layer)

## 🎯 Common Tasks

### How do I...

**...use an encrypted / secure database?**
```dart
// Automatic key management (recommended)
final key = await SecureKeyManager.resolveAutoKey(dbName: 'vault');
final db  = await JustDatabase.open('vault',
    mode: DatabaseMode.secure, encryptionKey: key);

// Password-based key derivation (PBKDF2)
final key = await SecureKeyManager.resolveKey(
    dbName: 'vault', password: 'user-password');
final db  = await JustDatabase.open('vault',
    mode: DatabaseMode.secure, encryptionKey: key);
```
See: [API.md#secure-key-management](API.md#secure-key-management)

**...create a database?**
```dart
// Persisted by default:
final db = await JustDatabase.open('mydb');
// In-memory only:
final db = await JustDatabase.open('mydb', persist: false);
```
See: [README#quick-start](README.md#quick-start)

**...persist data to disk?**
```dart
// Persistence is enabled by default
final db = await JustDatabase.open('mydb');

// Explicit in-memory only:
final db = await JustDatabase.open('mydb', persist: false);
// Or via DatabaseManager:
final db = await DatabaseManager.open('mydb', persist: false);
```
See: [README#database-modes](README.md#database-modes)

**...create a table?**
```dart
await db.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)');
```
See: [README#quick-start](README.md#quick-start)

**...insert data?**
```dart
await db.execute("INSERT INTO users (name) VALUES ('Alice')");
```
See: [README#quick-start](README.md#quick-start)

**...query data?**
```dart
final result = await db.execute('SELECT * FROM users WHERE age > 25');
```
See: [README#quick-start](README.md#quick-start)

**...perform a JOIN?**
```dart
final result = await db.execute('''
  SELECT orders.id, customers.name
  FROM orders
  INNER JOIN customers ON orders.customer_id = customers.id
''');
```
See: [README#join-operations](README.md#join-operations)

**...use aggregate functions?**
```dart
final result = await db.execute('''
  SELECT category, COUNT(*) as count, AVG(price) as avg_price
  FROM products
  GROUP BY category
  HAVING COUNT(*) > 5
''');
```
See: [README#aggregate-functions-and-group-by](README.md#aggregate-functions-and-group-by)

**...modify table structure?**
```dart
await db.execute('ALTER TABLE users ADD COLUMN phone TEXT');
await db.execute('ALTER TABLE users RENAME COLUMN name TO full_name');
```
See: [README#alter-table-operations](README.md#alter-table-operations)

**...create an index?**
```dart
final table = db.getTable('users');
table.createIndex('email', IndexType.hash);
```
See: [README#index-management](README.md#index-management)

**...use the admin UI?**
```dart
ChangeNotifierProvider(
  create: (_) => DatabaseProvider(),
  child: MaterialApp(
    home: JUDatabaseAdminScreen(
      // optional: seed data callback
      onSeedDatabase: (db) async { /* ... */ },
    ),
  ),
)
```
See: [README#built-in-admin-ui](README.md#built-in-admin-ui)

**...migrate from SQLite?**

See: [MIGRATION#migrating-from-sqlite](MIGRATION.md#migrating-from-sqlite)

**...optimize performance?**

See: [README#performance-tips](README.md#performance-tips) and [MIGRATION#performance-optimization-guide](MIGRATION.md#performance-optimization-guide)

## 🔍 Searching Documentation

### By Feature

- **Indexing:** README, API.md (Indexing section), examples
- **Persistence:** README (With File Persistence), API.md (DatabaseManager)
- **UI:** README (Built-in Admin UI), API.md (UI Components), flutter_admin_example.dart
- **Migration:** MIGRATION.md (entire document)
- **Constraints:** README (Table Constraints), API.md (Schema & Tables)

### By API Class

- **JustDatabase:** API.md → Core Classes → JustDatabase
- **SecureKeyManager:** API.md → Secure Key Management
- **DatabaseManager:** API.md → Database Management → DatabaseManager
- **Table / DatabaseRow:** API.md → Schema & Tables → Table
- **DbTable / DbRecord:** API.md → ORM Layer
- **DatabaseProvider:** API.md → UI Components → DatabaseProvider

### By Use Case

- **Mobile app with persistence:** README (With File Persistence) + flutter_admin_example.dart
- **In-memory analytics:** README (Quick Start) + example.dart
- **Data migration:** MIGRATION.md
- **Admin dashboard:** README (Built-in Admin UI)

## 💡 Tips

1. **Start simple:** Begin with the basic example before exploring advanced features
2. **Use the admin UI:** Great for learning and debugging
3. **Enable persistence:** For production apps, always use `persist: true`
4. **Monitor indexes:** Check `indexMetadata` to optimize queries
5. **Read examples:** Working code is often clearer than text

## 🐛 Troubleshooting

If you encounter issues:

1. Check [README#limitations](README.md#limitations) for known constraints
2. Review [MIGRATION#troubleshooting](MIGRATION.md#troubleshooting) for common problems
- Search [closed issues](https://github.com/just-unknown-dev/just-database/issues?q=is%3Aissue+is%3Aclosed)
- Ask in [discussions](https://github.com/just-unknown-dev/just-database/discussions)
- Open a [new issue](https://github.com/just-unknown-dev/just-database/issues/new)

## 📝 Contributing to Documentation

Found an error or want to improve the docs?

1. Fork the repository
2. Edit the relevant .md file
3. Submit a pull request
4. Include "docs:" in your commit message

## 📦 Package Structure

```
just_database/
├── README.md              # Main documentation
├── API.md                 # API reference
├── MIGRATION.md           # Migration guide (incl. 1.0.0 → 1.1.0)
├── CHANGELOG.md           # Version history
├── CONTRIBUTING.md        # Contributor guide
├── CODE_OF_CONDUCT.md     # Code of conduct
├── LICENSE                # BSD 3-Clause
├── lib/                   # Package source code
│   ├── just_database.dart # Main export
│   ├── ui.dart            # UI exports
│   └── src/               # Implementation
├── example/               # Code examples
│   ├── README.md          # Example guide
│   ├── example.dart       # Basic example
│   ├── persistence_example.dart
│   └── flutter_admin_example.dart
└── test/                  # Unit tests
```

## 🌟 Additional Resources

- **Pub.dev page:** https://pub.dev/packages/just_database
- **GitHub repository:** https://github.com/just-unknown-dev/just-database
- **Issue tracker:** https://github.com/just-unknown-dev/just-database/issues
- **Discussions:** https://github.com/just-unknown-dev/just-database/discussions

---

**Last updated:** 2026-02-23

**Package version:** 1.1.0

import 'package:flutter/foundation.dart';
import 'package:just_database/just_database.dart';

// =============================================================================
// Example entities using DbTable / DbRecord
// =============================================================================
// Drop this file into your project for a ready-to-run ORM demo.
// Run: ormExample();

//  User model

class User extends DbRecord {
  final String name;
  final String email;
  final int age;
  final bool active;

  const User({
    super.id,
    required this.name,
    required this.email,
    required this.age,
    this.active = true,
  });

  @override
  Map<String, dynamic> toMap() => {
    'name': name,
    'email': email,
    'age': age,
    'active': active,
  };

  User copyWith({
    int? id,
    String? name,
    String? email,
    int? age,
    bool? active,
  }) => User(
    id: id ?? this.id,
    name: name ?? this.name,
    email: email ?? this.email,
    age: age ?? this.age,
    active: active ?? this.active,
  );

  @override
  String toString() =>
      'User(id=$id, name=$name, email=$email, age=$age, active=$active)';
}

//  UserTable

class UserTable extends DbTable<User> {
  @override
  String get tableName => 'users';

  @override
  List<DbColumn> get columns => [
    DbColumn.text('name', notNull: true),
    DbColumn.text('email', notNull: true, unique: true),
    DbColumn.integer('age', defaultValue: 0),
    DbColumn.boolean('active', defaultValue: true),
  ];

  @override
  User fromRow(Map<String, dynamic> row) => User(
    id: row['id'] as int?,
    name: row['name'] as String? ?? '',
    email: row['email'] as String? ?? '',
    age: row['age'] as int? ?? 0,
    active: row['active'] as bool? ?? true,
  );
}

//  Product model

class Product extends DbRecord {
  final String name;
  final double price;
  final String? category;
  final int stock;

  const Product({
    super.id,
    required this.name,
    required this.price,
    this.category,
    this.stock = 0,
  });

  @override
  Map<String, dynamic> toMap() => {
    'name': name,
    'price': price,
    if (category != null) 'category': category,
    'stock': stock,
  };

  Product copyWith({
    int? id,
    String? name,
    double? price,
    String? category,
    int? stock,
  }) => Product(
    id: id ?? this.id,
    name: name ?? this.name,
    price: price ?? this.price,
    category: category ?? this.category,
    stock: stock ?? this.stock,
  );

  @override
  String toString() =>
      'Product(id=$id, name=$name, price=$price, category=$category, stock=$stock)';
}

//  ProductTable

class ProductTable extends DbTable<Product> {
  @override
  String get tableName => 'products';

  @override
  List<DbColumn> get columns => [
    DbColumn.text('name', notNull: true),
    DbColumn.real('price', notNull: true),
    DbColumn.text('category'),
    DbColumn.integer('stock', defaultValue: 0),
  ];

  @override
  Product fromRow(Map<String, dynamic> row) => Product(
    id: row['id'] as int?,
    name: row['name'] as String? ?? '',
    price: (row['price'] as num?)?.toDouble() ?? 0.0,
    category: row['category'] as String?,
    stock: row['stock'] as int? ?? 0,
  );
}

// =============================================================================
// Demo runner
// =============================================================================

/// Runs a complete CRUD demo using the ORM layer and prints results to stdout.
Future<void> ormExample() async {
  final db = await JustDatabase.open('orm_demo');
  final users = UserTable();
  final products = ProductTable();

  //  Schema
  debugPrint('=== ORM Demo ===\n');
  await users.createTable(db);
  await products.createTable(db);
  debugPrint('Tables created: ${db.tableNames.join(', ')}');

  //  Insert
  final alice = await users.insert(
    db,
    const User(name: 'Alice', email: 'alice@example.com', age: 30),
  );
  final bob = await users.insert(
    db,
    const User(name: 'Bob', email: 'bob@example.com', age: 24),
  );
  debugPrint('\nInserted: $alice');
  debugPrint('Inserted: $bob');

  await users.insertAll(db, [
    const User(name: 'Carol', email: 'carol@example.com', age: 28),
    const User(name: 'Dave', email: 'dave@example.com', age: 19, active: false),
  ]);
  debugPrint('Bulk-inserted 2 more users.');

  //  Select
  final all = await users.findAll(db, orderBy: 'age');
  debugPrint(
    '\nAll users (ordered by age): ${all.map((u) => u.name).join(', ')}',
  );

  final active = await users.findWhere(db, 'active = 1');
  debugPrint('Active users: ${active.map((u) => u.name).join(', ')}');

  final youngest = await users.findFirst(db, orderBy: 'age');
  debugPrint('Youngest: ${youngest?.name} (${youngest?.age})');

  final byId = await users.findById(db, alice.id!);
  debugPrint('findById(${alice.id}): ${byId?.name}');

  final total = await users.count(db);
  debugPrint('Total users: $total');

  //  Update
  final updatedRows = await users.update(db, alice.copyWith(age: 31));
  debugPrint('\nUpdated $updatedRows row(s). Alice is now 31.');

  await users.updateWhere(db, {'active': true}, 'age < 20');
  debugPrint('Re-activated all users under 20.');

  //  Products
  await products.insertAll(db, [
    const Product(
      name: 'Widget Pro',
      price: 9.99,
      category: 'Tools',
      stock: 100,
    ),
    const Product(
      name: 'Gadget X',
      price: 49.99,
      category: 'Electronics',
      stock: 25,
    ),
    const Product(
      name: 'Bolt Pack',
      price: 2.49,
      category: 'Tools',
      stock: 500,
    ),
  ]);

  final affordable = await products.findAll(
    db,
    where: "price < 20",
    orderBy: 'price',
  );
  debugPrint(
    '\nProducts under \$20: ${affordable.map((p) => p.name).join(', ')}',
  );

  final cheapest = await products.findFirst(db, orderBy: 'price');
  debugPrint('Cheapest: ${cheapest?.name} @ \$${cheapest?.price}');

  final productCount = await products.count(db, where: "category = 'Tools'");
  debugPrint('Tool products: $productCount');

  //  Delete
  await users.deleteById(db, bob.id!);
  debugPrint('\nDeleted Bob (id=${bob.id}).');

  final remaining = await users.count(db);
  debugPrint('Remaining users: $remaining');

  await products.deleteWhere(db, "stock > 200");
  debugPrint('Deleted products with stock > 200.');

  //  Raw query
  final fromRaw = await users.rawQuery(
    db,
    'SELECT * FROM users WHERE age BETWEEN 25 AND 35 ORDER BY name',
  );
  debugPrint(
    '\nRaw query (age 25-35): ${fromRaw.map((u) => u.name).join(', ')}',
  );

  //  Cleanup
  await users.dropTable(db);
  await products.dropTable(db);
  await db.close();
  debugPrint('\nTables dropped and database closed. Done!');
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/ui.dart';

/// Example Flutter app demonstrating the built-in admin UI
void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => DatabaseProvider(),
      child: MaterialApp(
        title: 'just_database Admin',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
        home: const JUDatabaseAdminScreen(
          // Optional: Override theme for just the database screen
          // theme: ThemeData(
          //   colorScheme: ColorScheme.fromSeed(
          //     seedColor: Colors.purple,
          //   ),
          //   useMaterial3: true,
          // ),
        ),
        // Note: Custom seed data can be provided via DatabasesTab widget
        // when building a custom UI
      ),
    );
  }
}

/// Alternative: Simple wrapper showing minimal setup
class SimpleAdminApp extends StatelessWidget {
  const SimpleAdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => DatabaseProvider(),
      child: MaterialApp(
        title: 'just_database Admin',
        theme: ThemeData.from(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        ),
        home: const JUDatabaseAdminScreen(),
      ),
    );
  }
}

/// Alternative: Very minimal example
class MinimalExample extends StatelessWidget {
  const MinimalExample({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => DatabaseProvider(),
      child: MaterialApp(
        title: 'just_database',
        home: const JUDatabaseAdminScreen(),
      ),
    );
  }
}

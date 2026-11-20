# just_database example

* `lib/main.dart` — a Flutter app that opens a saved `sample` database and
  shows the workbench (`JustDatabaseAdminScreen`). The bar above it runs the
  API tour and switches the workbench to read-only. Make the window narrow
  to see the phone layout.
* `lib/tour.dart` — the API tour: tables, bound parameters, a join, a
  transaction, a migration, the ORM and a backup (`runTour()`).
  `example.dart` runs it on its own (`flutter run -t example.dart`).

Run it:

```bash
cd example
flutter create .   # once, to add the platform folders
flutter pub get
flutter run
```

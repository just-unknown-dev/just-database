# just_database example

* `lib/main.dart` — a Flutter app that opens a saved `sample` database and
  shows the admin UI (`JustDatabaseAdminScreen`), with a button that runs
  the API tour.
* `example.dart` — the API tour: tables, bound parameters, a join, a
  transaction, a migration, the ORM and a backup (`runTour()`).

Run it:

```bash
cd example
flutter create .   # once, to add the platform folders
flutter pub get
flutter run
```

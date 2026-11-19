/// The admin UI: the screen, its state, tabs and pages. The helpers under
/// widgets/ and admin_utils.dart are internal.
library;

export 'database_provider.dart' show DatabaseProvider;
export 'just_database_admin_screen.dart'
    show JustDatabaseAdminScreen, SeedDatabaseCallback;
export 'pages/benchmark_page.dart' show BenchmarkPage;
export 'pages/database_detail_page.dart' show DatabaseDetailPage;
export 'pages/insert_page.dart' show InsertPage;
export 'tabs/databases_tab.dart' show DatabasesTab;
export 'tabs/query_editor_tab.dart' show QueryEditorTab;
export 'tabs/schema_tab.dart' show SchemaTab;
export 'tabs/settings_tab.dart' show SettingsTab;

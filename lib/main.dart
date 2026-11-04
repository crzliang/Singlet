import 'package:flutter/material.dart';

import 'app.dart';
import 'services/app_support_migration.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSupportMigration.migrateIfNeeded();
  runApp(SingletApp());
}

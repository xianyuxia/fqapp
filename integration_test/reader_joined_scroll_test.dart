import 'package:integration_test/integration_test.dart';

import '../test/reader_scroll_chapter_mode_test.dart' as reader_tests;
import '../test/reader_joined_scroll_anchor_test.dart' as anchor_tests;

// Run with `flutter test integration_test/reader_joined_scroll_test.dart
// -d <device> --no-uninstall`. The default integration-test cleanup uninstalls
// this package and deletes its data; always use a dedicated test device/package.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  reader_tests.main();
  anchor_tests.main();
}

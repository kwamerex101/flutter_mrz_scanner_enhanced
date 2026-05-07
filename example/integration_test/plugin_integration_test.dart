// Runner shim that allows `cd example && flutter test integration_test/...`
// to discover & execute the plugin's benchmark via the example app's native
// host. The actual bench body lives in the plugin at
// `../../integration_test/scan_image_bench_test.dart`.
//
// To run the bench against the example app on a connected device/emulator:
//
//   cd example
//   flutter test integration_test/plugin_integration_test.dart \
//     --reporter=expanded
//
// (Or run the file at the plugin root directly if the dart vm + plugin
// channels resolve in your toolchain.)

import 'package:integration_test/integration_test.dart';

import '../../integration_test/scan_image_bench_test.dart' as bench;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  bench.main();
}

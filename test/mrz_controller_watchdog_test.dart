import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mrz_scanner_enhanced/flutter_mrz_scanner_enhanced.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the MRZController no-result watchdog (the "scanning but never
/// finds an MRZ" hang). The watchdog fires [onError] once if neither a
/// successful parse nor a native onError arrives within the timeout.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'mrzscanner_0';
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Canonical ICAO Doc 9303 TD3 sample — parses cleanly via mrz_parser.
  const validMrz =
      'P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<\n'
      'L898902C36UTO7408122F1204159ZE184226B<<<<<10';

  /// Builds a real MRZController bound to `mrzscanner_0` via the public
  /// platform-view entry point, and stubs outgoing start/stop calls.
  MRZController makeController() {
    late MRZController controller;
    MRZScanner(onControllerCreated: (c) => controller = c)
        .onPlatformViewCreated(0);
    messenger.setMockMethodCallHandler(
      const MethodChannel(channelName),
      (call) async => null, // swallow start/stop/flashlight
    );
    return controller;
  }

  /// Simulates the native side invoking a method on the Dart handler.
  Future<void> sendFromNative(String method, [dynamic args]) {
    return messenger.handlePlatformMessage(
      channelName,
      codec.encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel(channelName),
      null,
    );
  });

  test('fires onError after timeout when nothing arrives', () {
    fakeAsync((async) {
      final controller = makeController();
      String? error;
      var errorCalls = 0;
      controller.onError = (e) {
        error = e;
        errorCalls++;
      };

      controller.startPreview(scanTimeout: const Duration(seconds: 25));
      async.elapse(const Duration(seconds: 24));
      expect(errorCalls, 0, reason: 'must not fire before timeout');

      async.elapse(const Duration(seconds: 2));
      expect(errorCalls, 1);
      expect(error, contains('timed out'));
    });
  });

  test('successful parse cancels the watchdog', () {
    fakeAsync((async) {
      final controller = makeController();
      var errorCalls = 0;
      var parsedCalls = 0;
      controller.onError = (_) => errorCalls++;
      controller.onParsed = (_) => parsedCalls++;

      controller.startPreview(scanTimeout: const Duration(seconds: 25));
      sendFromNative('onParsed', validMrz);
      async.flushMicrotasks();

      expect(parsedCalls, 1);
      async.elapse(const Duration(seconds: 30));
      expect(errorCalls, 0, reason: 'watchdog must be cancelled on success');
    });
  });

  test('native onError cancels the watchdog (no double fire)', () {
    fakeAsync((async) {
      final controller = makeController();
      var errorCalls = 0;
      controller.onError = (_) => errorCalls++;

      controller.startPreview(scanTimeout: const Duration(seconds: 25));
      sendFromNative('onError', 'Camera frame preprocessing failed repeatedly');
      async.flushMicrotasks();
      expect(errorCalls, 1);

      async.elapse(const Duration(seconds: 30));
      expect(errorCalls, 1, reason: 'watchdog must not add a second onError');
    });
  });

  test('onParsingFailed does NOT reset the watchdog', () {
    fakeAsync((async) {
      final controller = makeController();
      var errorCalls = 0;
      var parsingFailedCalls = 0;
      controller.onError = (_) => errorCalls++;
      controller.onParsed = (_) {}; // present so handler processes onParsed
      controller.onParsingFailed = () => parsingFailedCalls++;

      controller.startPreview(scanTimeout: const Duration(seconds: 25));
      // Garbage MRZ → onParsingFailed, repeatedly, like real scanning.
      async.elapse(const Duration(seconds: 10));
      sendFromNative('onParsed', 'NOT_A_VALID_MRZ_LINE');
      async.flushMicrotasks();
      sendFromNative('onParsed', 'STILL_GARBAGE');
      async.flushMicrotasks();
      expect(parsingFailedCalls, 2);
      expect(errorCalls, 0);

      // Watchdog still fires — wall-clock based, not reset by failed parses.
      async.elapse(const Duration(seconds: 16));
      expect(errorCalls, 1);
    });
  });

  test('dispose cancels the watchdog', () {
    fakeAsync((async) {
      final controller = makeController();
      var errorCalls = 0;
      controller.onError = (_) => errorCalls++;

      controller.startPreview(scanTimeout: const Duration(seconds: 25));
      controller.dispose();
      async.elapse(const Duration(seconds: 30));
      expect(errorCalls, 0);
    });
  });

  test('stopPreview cancels the watchdog', () {
    fakeAsync((async) {
      final controller = makeController();
      var errorCalls = 0;
      controller.onError = (_) => errorCalls++;

      controller.startPreview(scanTimeout: const Duration(seconds: 25));
      controller.stopPreview();
      async.elapse(const Duration(seconds: 30));
      expect(errorCalls, 0);
    });
  });

  test('Duration.zero opts out of the watchdog', () {
    fakeAsync((async) {
      final controller = makeController();
      var errorCalls = 0;
      controller.onError = (_) => errorCalls++;

      controller.startPreview(scanTimeout: Duration.zero);
      async.elapse(const Duration(minutes: 5));
      expect(errorCalls, 0);
    });
  });

  test('startPreview twice cancels the first watchdog (fires once)', () {
    fakeAsync((async) {
      final controller = makeController();
      var errorCalls = 0;
      controller.onError = (_) => errorCalls++;

      controller.startPreview(scanTimeout: const Duration(seconds: 25));
      controller.startPreview(scanTimeout: const Duration(seconds: 10));
      async.elapse(const Duration(seconds: 11)); // past 2nd, before 1st(25s)
      expect(errorCalls, 1);
      async.elapse(const Duration(seconds: 20)); // past the original 25s mark
      expect(errorCalls, 1, reason: 'first timer must have been cancelled');
    });
  });

  test('watchdog with null onError fires without throwing', () {
    fakeAsync((async) {
      final controller = makeController();
      // onError deliberately left unset — the timer must not throw; it falls
      // back to a debugPrint. A thrown error would fail the fakeAsync zone.
      controller.startPreview(scanTimeout: const Duration(seconds: 25));
      async.elapse(const Duration(seconds: 26));
    });
  });
}

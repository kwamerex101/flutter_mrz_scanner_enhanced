import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mrz_scanner_enhanced/flutter_mrz_scanner_enhanced.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mrzscanner_static');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('scanImage targets mrzscanner_static / scanImage with bytes arg',
      () async {
    MethodCall? captured;
    messenger.setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return null; // OCR found nothing
    });
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final result = await MRZScanner.scanImage(bytes);
    expect(result, isNull);
    expect(captured!.method, 'scanImage');
    final args = captured!.arguments as Map;
    expect(args['bytes'], bytes);
  });

  test('scanImage returns null when OCR text fails MRZ parse', () async {
    messenger.setMockMethodCallHandler(
        channel, (_) async => 'GARBAGE_TEXT_NOT_AN_MRZ');
    final result = await MRZScanner.scanImage(Uint8List(0));
    expect(result, isNull);
  });

  test('scanImage returns MRZFullResult on a valid TD3 MRZ string', () async {
    // Canonical TD3 sample (passport).
    const td3 =
        'P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<\n'
        'L898902C36UTO7408122F1204159ZE184226B<<<<<10';
    messenger.setMockMethodCallHandler(channel, (_) async => td3);
    final result = await MRZScanner.scanImage(Uint8List(0));
    expect(result, isNotNull);
    expect(result!.mrz, td3);
    expect(result.mrzResult.documentNumber, 'L898902C3');
  });

  test(
      'scanImage forwards multi-line OCR output through mrz_parser without '
      'throwing, even when non-MRZ noise leaks through native filtering',
      () async {
    // Phase 3: modern OCR engines (iOS Vision, Android MLKit) recognize
    // whole-image text and may return non-MRZ lines mixed with the MRZ
    // band. The native side filters MRZ-shape candidates before forwarding,
    // but if some noise leaks through, the Dart side MUST handle it
    // gracefully — never throwing — and return null when mrz_parser
    // cannot parse the candidate set.
    const noisyMrz =
        'REPUBLIC OF UTOPIA\n'
        'P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<\n'
        'PASSPORT\n'
        'L898902C36UTO7408122F1204159ZE184226B<<<<<10\n'
        'See page 2';
    messenger.setMockMethodCallHandler(channel, (_) async => noisyMrz);

    // Must not throw — this is the channel contract guard. Whether the
    // parser recovers or returns null is mrz_parser's call; the channel
    // forwarding just has to be robust.
    final result = await MRZScanner.scanImage(Uint8List(0));
    expect(result, anyOf(isNull, isA<MRZFullResult>()),
        reason: 'forwarding must not throw on multi-line noisy input');
  });
}

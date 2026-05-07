import 'package:flutter/material.dart';
import 'package:flutter_mrz_scanner_enhanced_example/camera_page.dart';
import 'package:flutter_mrz_scanner_enhanced_example/image_scan_page.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Future<void> _openCamera(BuildContext context) async {
    final status = await Permission.camera.request();
    if (!context.mounted) return;
    if (status == PermissionStatus.granted) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => CameraPage()),
      );
    } else if (status == PermissionStatus.permanentlyDenied) {
      openAppSettings();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Camera permission: $status')),
      );
    }
  }

  void _openImageScan(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ImageScanPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MRZ Scanner Example')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: () => _openCamera(context),
              child: const Text('Live camera scan'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _openImageScan(context),
              child: const Text('Pick image from gallery'),
            ),
          ],
        ),
      ),
    );
  }
}

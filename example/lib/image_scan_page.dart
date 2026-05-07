import 'package:flutter/material.dart';
import 'package:flutter_mrz_scanner_enhanced/flutter_mrz_scanner_enhanced.dart';
import 'package:image_picker/image_picker.dart';

class ImageScanPage extends StatefulWidget {
  const ImageScanPage({super.key});

  @override
  State<ImageScanPage> createState() => _ImageScanPageState();
}

class _ImageScanPageState extends State<ImageScanPage> {
  String? _result;
  bool _busy = false;

  Future<void> _pickAndScan() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) {
        setState(() => _busy = false);
        return;
      }
      final bytes = await picked.readAsBytes();
      final r = await MRZScanner.scanImage(bytes);
      setState(() => _result = r?.mrz ?? '(no MRZ)');
    } catch (e) {
      setState(() => _result = 'Error: $e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Image scan')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: _busy ? null : _pickAndScan,
              child: Text(_busy ? 'Scanning...' : 'Pick image from gallery'),
            ),
            const SizedBox(height: 16),
            if (_result != null) SelectableText(_result!),
          ],
        ),
      ),
    );
  }
}

import 'dart:io';
import 'package:http/http.dart' as http;

class ApiClient {
  // Point this to your FastAPI later, e.g. http://10.0.2.2:8000 for Android emulator
  final String baseUrl;
  ApiClient({required this.baseUrl});

  Future<void> uploadSegment(File file) async {
    final uri = Uri.parse('$baseUrl/upload');
    final req = http.MultipartRequest('POST', uri)
      ..files.add(await http.MultipartFile.fromPath('file', file.path));
    final resp = await req.send();
    if (resp.statusCode >= 400) {
      throw Exception('Upload failed: ${resp.statusCode}');
    }
  }
}

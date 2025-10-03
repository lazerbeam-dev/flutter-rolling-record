import 'dart:io';
import 'package:path_provider/path_provider.dart';

class RecordingRepository {
  static const String folderName = 'segments';
  // Optional cap to keep it “rolling” (delete oldest beyond this count):
  static const int maxSegments = 120; // last hour if 30s each

  Future<Directory> _ensureDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final recDir = Directory('${dir.path}/$folderName');
    if (!await recDir.exists()) {
      await recDir.create(recursive: true);
    }
    return recDir;
    // NOTE: On Android you could switch to external storage if preferred.
  }

  Future<String> nextFilePath() async {
    final dir = await _ensureDir();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    return '${dir.path}/seg_$ts.m4a';
  }

  Future<List<FileSystemEntity>> listSegments() async {
    final dir = await _ensureDir();
    final items = await dir.list().toList();
    items.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified)); // newest first
    return items.whereType<File>().toList();
  }

  Future<void> enforceCap() async {
    final files = await listSegments();
    if (files.length <= maxSegments) return;
    final toDelete = files.skip(maxSegments).toList(); // delete oldest beyond cap
    for (final f in toDelete) {
      try { await f.delete(); } catch (_) {}
    }
  }
}

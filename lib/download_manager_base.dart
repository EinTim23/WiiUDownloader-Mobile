import 'package:flutter/foundation.dart';
import 'ffi.dart';

enum DownloadStatus { queued, downloading, decrypting, done, error, cancelled }

class DownloadEntry {
  final String titleId;
  final String name;
  final String outputPath;
  final int category;
  final bool decrypt;
  final int version;
  DownloadStatus status;
  int totalSize;
  int downloaded;
  double decryptionProgress;
  String currentFile;
  String? error;
  DownloadTask? task;
  double speed; // bytes per second
  DateTime? _lastSpeedUpdate;
  int _lastSpeedBytes;

  String get typeName => categoryName(category);

  DownloadEntry({
    required this.titleId,
    required this.name,
    required this.outputPath,
    required this.category,
    this.decrypt = true,
    this.version = -1,
    this.status = DownloadStatus.queued,
    this.totalSize = 0,
    this.downloaded = 0,
    this.decryptionProgress = 0,
    this.currentFile = '',
    this.error,
    this.speed = 0,
  }) : _lastSpeedBytes = 0;

  void updateSpeed(int currentDownloaded) {
    final now = DateTime.now();
    if (_lastSpeedUpdate == null) {
      _lastSpeedUpdate = now;
      _lastSpeedBytes = currentDownloaded;
      return;
    }
    final elapsed = now.difference(_lastSpeedUpdate!).inMilliseconds;
    if (elapsed >= 1000) {
      final delta = currentDownloaded - _lastSpeedBytes;
      speed = delta / (elapsed / 1000.0);
      _lastSpeedUpdate = now;
      _lastSpeedBytes = currentDownloaded;
    }
  }
}

abstract class BaseDownloadManager extends ChangeNotifier {
  List<DownloadEntry> get entries;

  Future<void> init();

  Future<void> startDownload(
    String titleId,
    String name,
    String outputPath,
    int category, {
    bool decrypt = true,
    int version = -1,
  });

  void cancelDownload(DownloadEntry entry);

  void removeEntry(DownloadEntry entry);
}

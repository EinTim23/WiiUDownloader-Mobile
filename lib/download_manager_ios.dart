import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'ffi.dart';
import 'download_manager_base.dart';
import 'ios_bookmark.dart';

export 'download_manager_base.dart';

class DownloadManagerIOS extends BaseDownloadManager {
  static final DownloadManagerIOS instance = DownloadManagerIOS._();
  DownloadManagerIOS._();

  @override
  final List<DownloadEntry> entries = [];
  bool _isRunning = false;
  DateTime? _lastProgressUpdate;

  @override
  Future<void> init() async {
    // No notification setup needed on iOS as we can't do background downloads
  }

  Future<void> _enableWakelockIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('keep_screen_on') ?? false) {
      await WakelockPlus.enable();
    }
  }

  Future<void> _disableWakelock() async {
    if (await WakelockPlus.enabled) {
      await WakelockPlus.disable();
    }
  }

  bool _hasActiveDownloads() {
    return entries.any(
      (e) =>
          e.status == DownloadStatus.downloading ||
          e.status == DownloadStatus.decrypting ||
          e.status == DownloadStatus.queued,
    );
  }

  @override
  Future<void> startDownload(
    String titleId,
    String name,
    String outputPath,
    int category, {
    bool decrypt = true,
    int version = -1,
  }) async {
    await _enableWakelockIfNeeded();

    final entry = DownloadEntry(
      titleId: titleId,
      name: name,
      outputPath: outputPath,
      category: category,
      decrypt: decrypt,
      version: version,
    );
    entries.add(entry);
    notifyListeners();

    _processQueue();
  }

  void _processQueue() {
    if (_isRunning) return;

    final next = entries.cast<DownloadEntry?>().firstWhere(
      (e) => e!.status == DownloadStatus.queued,
      orElse: () => null,
    );
    if (next == null) return;

    _isRunning = true;
    _startEntryAsync(next);
  }

  Future<void> _startEntryAsync(DownloadEntry entry) async {
    if (Platform.isIOS) {
      await IOSBookmark.startAccessingBookmark();
    }
    _startEntry(entry);
  }

  void _startEntry(DownloadEntry entry) {
    final id = entry.titleId.replaceAll('0x', '');
    final outputPath = entry.outputPath;

    entry.task = DownloadTask(
      onGameTitle: (title) {
        if (entry.status == DownloadStatus.cancelled) return;
        entry.status = DownloadStatus.downloading;
        notifyListeners();
      },
      onDownloadSize: (size) {
        entry.totalSize = size;
        notifyListeners();
      },
      onProgress: (downloaded, filename) {
        if (entry.status == DownloadStatus.cancelled) return;
        entry.downloaded = downloaded;
        entry.currentFile = filename;
        entry.status = DownloadStatus.downloading;
        entry.updateSpeed(downloaded);

        final now = DateTime.now();
        if (_lastProgressUpdate != null &&
            now.difference(_lastProgressUpdate!).inMilliseconds < 100) {
          return;
        }
        _lastProgressUpdate = now;

        notifyListeners();
      },
      onDecryptionProgress: (progress) {
        if (entry.status == DownloadStatus.cancelled) return;
        entry.decryptionProgress = progress;
        entry.status = DownloadStatus.decrypting;
        notifyListeners();
      },
      onDone: (error) {
        if (entry.status == DownloadStatus.cancelled) {
          // Already cancelled, don't overwrite status
        } else if (error != null) {
          entry.status = DownloadStatus.error;
          entry.error = error;
        } else {
          entry.status = DownloadStatus.done;
        }
        entry.task = null;
        _isRunning = false;
        _lastProgressUpdate = null;
        notifyListeners();

        if (_hasActiveDownloads()) {
          _processQueue();
        } else {
          _disableWakelock();
          IOSBookmark.stopAccessingBookmark();
        }
      },
    );

    entry.task!.start(
      id,
      outputPath,
      decrypt: entry.decrypt,
      version: entry.version,
    );
  }

  @override
  void cancelDownload(DownloadEntry entry) {
    entry.task?.cancel();
    entry.status = DownloadStatus.cancelled;
    notifyListeners();
    if (!_hasActiveDownloads()) {
      _disableWakelock();
      IOSBookmark.stopAccessingBookmark();
    }
  }

  @override
  void removeEntry(DownloadEntry entry) {
    if (entry.status == DownloadStatus.downloading ||
        entry.status == DownloadStatus.decrypting) {
      cancelDownload(entry);
    }
    entries.remove(entry);
    notifyListeners();
  }
}

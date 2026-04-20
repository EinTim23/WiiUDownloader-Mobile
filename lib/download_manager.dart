import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'ffi.dart';

enum DownloadStatus { queued, downloading, decrypting, done, error, cancelled }

class DownloadEntry {
  final String titleId;
  final String name;
  final String outputPath;
  final int category;
  final bool decrypt;
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

class DownloadManager extends ChangeNotifier {
  static final DownloadManager instance = DownloadManager._();
  DownloadManager._();

  final List<DownloadEntry> entries = [];
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _notificationsReady = false;
  bool _foregroundStarted = false;
  DateTime? _lastProgressUpdate;

  Future<void> init() async {
    await _notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_wiiudownloader'),
      ),
    );
    _notificationsReady = true;
  }

  Future<bool> _ensureNotificationPermission() async {
    final status = await Permission.notification.request();
    return status.isGranted;
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

  Future<void> _startForegroundService() async {
    if (_foregroundStarted) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'download_channel',
        channelName: 'Downloads',
        channelDescription: 'Wii U title downloads',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    await FlutterForegroundTask.startService(
      notificationTitle: 'Wii U Downloader',
      notificationText: 'Downloads in progress',
      notificationIcon: const NotificationIcon(
        metaDataName: 'dev.eintim.wiiudownloader.NOTIFICATION_ICON',
      ),
    );
    _foregroundStarted = true;
    await _enableWakelockIfNeeded();
  }

  Future<void> _stopForegroundService() async {
    if (!_foregroundStarted) return;
    await FlutterForegroundTask.stopService();
    _foregroundStarted = false;
    await _disableWakelock();
  }

  void _updateNotification(DownloadEntry entry) {
    if (!_notificationsReady) return;
    final pct =
        entry.totalSize > 0 ? (entry.downloaded * 100 ~/ entry.totalSize) : 0;

    String body;
    if (entry.status == DownloadStatus.decrypting) {
      body = 'Decrypting... ${(entry.decryptionProgress * 100).toInt()}%';
    } else {
      body = '${entry.currentFile} — $pct% — ${_formatSpeed(entry.speed)}';
    }

    _notifications.show(
      id: entry.hashCode,
      title: '${entry.typeName}: ${entry.name}',
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'download_progress',
          'Download Progress',
          channelDescription: 'Shows download progress',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          onlyAlertOnce: true,
          showProgress: true,
          ongoing: true,
          maxProgress: 100,
          progress: entry.status == DownloadStatus.decrypting
              ? (entry.decryptionProgress * 100).toInt()
              : pct,
        ),
      ),
    );
  }

  void _clearNotification(DownloadEntry entry) {
    _notifications.cancel(id: entry.hashCode);
  }

  static String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toInt()} B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  void _showCompletionNotification(DownloadEntry entry) {
    if (!_notificationsReady) return;
    _notifications.show(
      id: entry.hashCode,
      title: '${entry.typeName}: ${entry.name}',
      body: entry.status == DownloadStatus.done
          ? 'Download complete'
          : entry.status == DownloadStatus.error
              ? 'Download failed: ${entry.error}'
              : 'Download cancelled',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'download_complete',
          'Download Complete',
          channelDescription: 'Download completion notifications',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          icon: '@drawable/ic_stat_wiiudownloader',
        ),
      ),
    );
  }

  bool _isRunning = false;

  bool _hasActiveDownloads() {
    return entries.any((e) =>
        e.status == DownloadStatus.downloading ||
        e.status == DownloadStatus.decrypting ||
        e.status == DownloadStatus.queued);
  }

  Future<void> startDownload(
      String titleId, String name, String outputPath, int category, {bool decrypt = true}) async {
    await _ensureNotificationPermission();
    await _startForegroundService();

    final entry = DownloadEntry(titleId: titleId, name: name, outputPath: outputPath, category: category, decrypt: decrypt);
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
    _startEntry(next);
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
        _updateNotification(entry);
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
        _updateNotification(entry);
      },
      onDecryptionProgress: (progress) {
        if (entry.status == DownloadStatus.cancelled) return;
        entry.decryptionProgress = progress;
        entry.status = DownloadStatus.decrypting;
        notifyListeners();
        _updateNotification(entry);
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
        _clearNotification(entry);
        _showCompletionNotification(entry);
        _isRunning = false;
        _lastProgressUpdate = null;
        notifyListeners();

        if (_hasActiveDownloads()) {
          _processQueue();
        } else {
          _stopForegroundService();
        }
      },
    );

    entry.task!.start(id, outputPath, decrypt: entry.decrypt);
    _updateNotification(entry);
  }

  void cancelDownload(DownloadEntry entry) {
    entry.task?.cancel();
    entry.status = DownloadStatus.cancelled;
    _clearNotification(entry);
    notifyListeners();
    if (!_hasActiveDownloads()) {
      _stopForegroundService();
    }
  }

  void removeEntry(DownloadEntry entry) {
    if (entry.status == DownloadStatus.downloading ||
        entry.status == DownloadStatus.decrypting) {
      cancelDownload(entry);
    }
    entries.remove(entry);
    notifyListeners();
  }
}

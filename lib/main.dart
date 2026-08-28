import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'ffi.dart';
import 'download_manager.dart';
import 'download_manager_ios.dart';
import 'ios_bookmark.dart';

BaseDownloadManager get downloadManager =>
    Platform.isIOS ? DownloadManagerIOS.instance : DownloadManager.instance;

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setTempDir(Directory.systemTemp.path);
  await downloadManager.init();
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WiiUDownloader',
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  static const List<Widget> _pages = [
    SearchTab(),
    DownloadsTab(),
    SettingsTab(),
  ];

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
    );
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: [SystemUiOverlay.top],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(icon: Icon(Icons.download), label: 'Downloads'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

class SearchTab extends StatefulWidget {
  const SearchTab({super.key});

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final TextEditingController _searchController = TextEditingController();
  List<TitleEntryData> _results = [];
  int _selectedCategory = 4; // TITLE_CATEGORY_ALL
  int _selectedRegion = 0; // 0 = all regions
  final Map<String, Future<int>> _titleSizeFutures = {};
  static const _titleDatabaseUrl = 'https://wiiubrew.org/wiki/Title_database';

  static const _categories = {
    4: 'All',
    0: 'Game',
    1: 'Update',
    2: 'DLC',
    3: 'Demo',
  };

  static const _regions = {
    0: 'All',
    0x02: 'USA',
    0x04: 'Europe',
    0x01: 'Japan',
    0x10: 'China',
    0x20: 'Korea',
    0x40: 'Taiwan',
  };

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _results = search_title(
        _searchController.text,
        _selectedCategory,
        _selectedRegion,
      );
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _regionName(int region) {
    final parts = <String>[];
    if (region & 0x02 != 0) parts.add('USA');
    if (region & 0x04 != 0) parts.add('EUR');
    if (region & 0x01 != 0) parts.add('JPN');
    if (region & 0x10 != 0) parts.add('CHN');
    if (region & 0x20 != 0) parts.add('KOR');
    if (region & 0x40 != 0) parts.add('TWN');
    if (parts.isEmpty) return 'Unknown';
    if (parts.length >= 3) return 'All';
    return parts.join('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Search Titles')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: SearchBar(
              controller: _searchController,
              hintText: 'Search titles...',
              leading: const Icon(Icons.search),
              onChanged: (_) => _refresh(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: _selectedCategory,
                    decoration: const InputDecoration(
                      labelText: 'Type',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    items: _categories.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      _selectedCategory = value!;
                      _refresh();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: _selectedRegion,
                    decoration: const InputDecoration(
                      labelText: 'Region',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    items: _regions.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      _selectedRegion = value!;
                      _refresh();
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _results.isEmpty
                ? const Center(child: Text('No titles found'))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final entry = _results[index];
                      return ListTile(
                        title: Text(entry.name),
                        subtitle: Text(
                          '${categoryName(entry.category)} · ${_regionName(entry.region)} · ${entry.titleId.toRadixString(16).toUpperCase().padLeft(16, '0')}',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.download_outlined),
                          onPressed: () => _showDownloadPreview(entry),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<int> _getTitleSize(TitleEntryData entry, int version) {
    final titleId = entry.titleId;
    final cacheKey = '$titleId:$version';
    return _titleSizeFutures.putIfAbsent(
      cacheKey,
      () => Isolate.run(() => fetchTMDSize(titleId, version: version)),
    );
  }

  Future<void> _showDownloadPreview(TitleEntryData entry) async {
    final downloadPrefs = await _getDownloadPreferences();
    if (downloadPrefs == null) return;

    if (!mounted) return;
    final versionController = TextEditingController();
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          var useLatestVersion = true;
          Future<int>? sizeFuture = _getTitleSize(entry, -1);
          final titleHex = entry.titleId
              .toRadixString(16)
              .toUpperCase()
              .padLeft(16, '0');

          int? selectedVersion() {
            if (useLatestVersion) return -1;
            if (versionController.text.isEmpty) return null;
            final version = int.tryParse(versionController.text);
            if (version == null || version > 0x7FFFFFFF) return null;
            return version;
          }

          void updateSizeFuture() {
            final version = selectedVersion();
            sizeFuture = version == null ? null : _getTitleSize(entry, version);
          }

          return StatefulBuilder(
            builder: (context, setDialogState) {
              final version = selectedVersion();
              return AlertDialog(
                title: Text(entry.name),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Type: ${categoryName(entry.category)}'),
                      Text('Region: ${_regionName(entry.region)}'),
                      Text('Title ID: $titleHex'),
                      const SizedBox(height: 16),
                      const Text('Version'),
                      const SizedBox(height: 8),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: true, label: Text('Latest')),
                          ButtonSegment(value: false, label: Text('Specific')),
                        ],
                        selected: {useLatestVersion},
                        onSelectionChanged: (selection) {
                          setDialogState(() {
                            useLatestVersion = selection.single;
                            updateSizeFuture();
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      if (!useLatestVersion)
                        TextField(
                          controller: versionController,
                          decoration: InputDecoration(
                            labelText: 'Version code',
                            hintText: 'Numbers only',
                            errorText:
                                versionController.text.isNotEmpty &&
                                    version == null
                                ? 'Enter a valid version code'
                                : null,
                          ),
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          onChanged: (_) {
                            setDialogState(updateSizeFuture);
                          },
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        children: [
                          const Text('Version codes can be found '),
                          InkWell(
                            onTap: _openTitleDatabase,
                            child: Text(
                              'here',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                          const Text('.'),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (sizeFuture == null)
                        const Text('Enter a version code to fetch file size.')
                      else
                        FutureBuilder<int>(
                          future: sizeFuture,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState !=
                                ConnectionState.done) {
                              return const Row(
                                children: [
                                  SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  SizedBox(width: 12),
                                  Text('Fetching file size...'),
                                ],
                              );
                            }

                            if (snapshot.hasError) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Could not fetch file size.'),
                                  const SizedBox(height: 8),
                                  TextButton.icon(
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('Retry'),
                                    onPressed: () {
                                      final version = selectedVersion();
                                      if (version == null) return;
                                      _titleSizeFutures.remove(
                                        '${entry.titleId}:$version',
                                      );
                                      setDialogState(() {
                                        sizeFuture = _getTitleSize(
                                          entry,
                                          version,
                                        );
                                      });
                                    },
                                  ),
                                ],
                              );
                            }

                            return Text(
                              'File size: ${_formatBytes(snapshot.data!)}',
                            );
                          },
                        ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Cancel'),
                  ),
                  if (sizeFuture == null)
                    FilledButton.icon(
                      icon: const Icon(Icons.download),
                      label: const Text('Add to queue'),
                      onPressed: null,
                    )
                  else
                    FutureBuilder<int>(
                      future: sizeFuture,
                      builder: (context, snapshot) {
                        return FilledButton.icon(
                          icon: const Icon(Icons.download),
                          label: const Text('Add to queue'),
                          onPressed: snapshot.hasData && version != null
                              ? () {
                                  Navigator.of(dialogContext).pop();
                                  _startDownload(entry, version, downloadPrefs);
                                }
                              : null,
                        );
                      },
                    ),
                ],
              );
            },
          );
        },
      );
    } finally {
      versionController.dispose();
    }
  }

  Future<void> _openTitleDatabase() async {
    final opened = await launchUrl(
      Uri.parse(_titleDatabaseUrl),
      mode: LaunchMode.externalApplication,
    );
    if (opened || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open title database')),
    );
  }

  Future<({SharedPreferences prefs, String directory})?>
  _getDownloadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = prefs.getString('download_directory');
    if (dir != null && dir.isNotEmpty) {
      return (prefs: prefs, directory: dir);
    }

    if (!mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Set a download directory in Settings first'),
      ),
    );
    return null;
  }

  Future<void> _startDownload(
    TitleEntryData entry,
    int version,
    ({SharedPreferences prefs, String directory}) downloadPrefs,
  ) async {
    final prefs = downloadPrefs.prefs;
    final titleHex = entry.titleId
        .toRadixString(16)
        .toUpperCase()
        .padLeft(16, '0');
    final decrypt = prefs.getBool('decrypt_on_download') ?? true;
    await downloadManager.startDownload(
      titleHex,
      entry.name,
      downloadPrefs.directory,
      entry.category,
      decrypt: decrypt,
      version: version,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Started download: ${entry.name}')));
  }
}

class DownloadsTab extends StatefulWidget {
  const DownloadsTab({super.key});

  @override
  State<DownloadsTab> createState() => _DownloadsTabState();
}

class _DownloadsTabState extends State<DownloadsTab> {
  final _manager = downloadManager;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onChanged);
  }

  @override
  void dispose() {
    _manager.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toInt()} B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  @override
  Widget build(BuildContext context) {
    final entries = _manager.entries;
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: entries.isEmpty
          ? const Center(child: Text('No downloads'))
          : ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return _buildDownloadTile(entry);
              },
            ),
    );
  }

  Widget _buildDownloadTile(DownloadEntry entry) {
    final pct = entry.totalSize > 0 ? entry.downloaded / entry.totalSize : 0.0;

    String subtitle;
    switch (entry.status) {
      case DownloadStatus.queued:
        subtitle = 'Queued';
      case DownloadStatus.downloading:
        subtitle =
            '${_formatBytes(entry.downloaded)} / ${_formatBytes(entry.totalSize)} — ${_formatSpeed(entry.speed)}\n${entry.currentFile}';
      case DownloadStatus.decrypting:
        subtitle = 'Decrypting... ${(entry.decryptionProgress * 100).toInt()}%';
      case DownloadStatus.done:
        subtitle = 'Complete';
      case DownloadStatus.error:
        subtitle = 'Error: ${entry.error}';
      case DownloadStatus.cancelled:
        subtitle = 'Cancelled';
    }

    final isActive =
        entry.status == DownloadStatus.downloading ||
        entry.status == DownloadStatus.decrypting ||
        entry.status == DownloadStatus.queued;

    return Dismissible(
      key: ObjectKey(entry),
      direction: isActive ? DismissDirection.none : DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => _manager.removeEntry(entry),
      child: Column(
        children: [
          ListTile(
            title: Text(entry.name),
            subtitle: Text('${entry.typeName} · $subtitle'),
            trailing: isActive
                ? IconButton(
                    icon: const Icon(Icons.cancel),
                    onPressed: () => _manager.cancelDownload(entry),
                  )
                : entry.status == DownloadStatus.done
                ? const Icon(Icons.check_circle, color: Colors.green)
                : const Icon(Icons.error, color: Colors.red),
          ),
          if (entry.status == DownloadStatus.downloading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(value: pct),
            ),
          if (entry.status == DownloadStatus.decrypting)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(value: entry.decryptionProgress),
            ),
          if (entry.status == DownloadStatus.queued)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  static const _prefKey = 'download_directory';
  static const _decryptKey = 'decrypt_on_download';
  static const _keepScreenOnKey = 'keep_screen_on';
  String? _downloadDir;
  bool _decrypt = true;
  bool _keepScreenOn = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _downloadDir = prefs.getString(_prefKey);
      _decrypt = prefs.getBool(_decryptKey) ?? true;
      _keepScreenOn = prefs.getBool(_keepScreenOnKey) ?? false;
      _loading = false;
    });
  }

  Future<bool> _ensureStoragePermission() async {
    if (Platform.isIOS) {
      return true;
    }

    // Android 10 and below use READ/WRITE storage runtime permission
    PermissionStatus status = await Permission.storage.status;
    if (status.isGranted) return true;

    status = await Permission.storage.request();
    if (status.isGranted) return true;

    // Newer versions use the manageExternalStorage permission
    status = await Permission.manageExternalStorage.status;
    if (status.isGranted) return true;

    status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;

    if (!mounted) return false;
    final shouldOpenSettings = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Permission Required'),
        content: const Text(
          'Storage access is required to set a download directory. '
          'Please grant it in app settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
    if (shouldOpenSettings == true) {
      await openAppSettings();
    }
    return false;
  }

  Future<void> _pickDirectory() async {
    if (Platform.isIOS) {
      await _pickDirectoryIOS();
      return;
    }

    final hasPermission = await _ensureStoragePermission();
    if (!hasPermission) return;

    final result = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select Download Directory',
    );
    if (result == null) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, result);
    setState(() => _downloadDir = result);
  }

  Future<void> _pickDirectoryIOS() async {
    final path = await IOSBookmark.pickAndBookmarkFolder();
    if (path == null) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, path);
    setState(() => _downloadDir = path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.folder),
                  title: const Text('Download Directory'),
                  subtitle: Text(_downloadDir ?? 'Not set'),
                  trailing: const Icon(Icons.edit),
                  onTap: _pickDirectory,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.lock_open),
                  title: const Text('Decrypt after download'),
                  subtitle: const Text(
                    'Decrypt downloaded content for emulators',
                  ),
                  value: _decrypt,
                  onChanged: (value) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool(_decryptKey, value);
                    setState(() => _decrypt = value);
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.screen_lock_portrait),
                  title: const Text('Keep screen on'),
                  subtitle: const Text(
                    'Prevent sleep while downloads are active',
                  ),
                  value: _keepScreenOn,
                  onChanged: (value) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool(_keepScreenOnKey, value);
                    setState(() => _keepScreenOn = value);
                  },
                ),
              ],
            ),
    );
  }
}

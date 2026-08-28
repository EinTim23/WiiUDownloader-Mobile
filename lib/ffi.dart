import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'dart:io';

final class TitleEntry extends Struct {
  external Pointer<Utf8> name;

  @Uint64()
  external int title_id;

  @Uint8()
  external int region;

  @Uint8()
  external int key;

  @Uint8()
  external int category;
}

final class TitleEntryArray extends Struct {
  external Pointer<TitleEntry> data;

  @Int32()
  external int length;
}

typedef search_native = TitleEntryArray Function(Pointer<Utf8>, Uint8, Uint8);

typedef search_dart = TitleEntryArray Function(Pointer<Utf8>, int, int);

typedef free_native = Void Function(TitleEntryArray);

typedef free_dart = void Function(TitleEntryArray);

// DownloadTitle callback types
typedef OnGameTitleNative = Void Function(Pointer<Utf8>);
typedef OnProgressNative = Void Function(Int64, Pointer<Utf8>);
typedef OnDecryptionNative = Void Function(Double);
typedef OnSizeNative = Void Function(Int64);
typedef OnDoneNative = Void Function(Pointer<Utf8>);

typedef _DownloadTitleNative =
    Void Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<NativeFunction<OnGameTitleNative>>,
      Pointer<NativeFunction<OnProgressNative>>,
      Pointer<NativeFunction<OnDecryptionNative>>,
      Pointer<NativeFunction<OnSizeNative>>,
      Pointer<Int32>,
      Pointer<NativeFunction<OnDoneNative>>,
      Int32,
      Int32,
    );

typedef _DownloadTitleDart =
    void Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<NativeFunction<OnGameTitleNative>>,
      Pointer<NativeFunction<OnProgressNative>>,
      Pointer<NativeFunction<OnDecryptionNative>>,
      Pointer<NativeFunction<OnSizeNative>>,
      Pointer<Int32>,
      Pointer<NativeFunction<OnDoneNative>>,
      int,
      int,
    );

final DynamicLibrary wiiudownloader = () {
  if (Platform.isAndroid) {
    return DynamicLibrary.open("libwiiudownloader.so");
  } else if (Platform.isIOS) {
    return DynamicLibrary.process();
  } else {
    throw UnsupportedError("Unsupported platform");
  }
}();

final search = wiiudownloader
    .lookup<NativeFunction<search_native>>('Search')
    .asFunction<search_dart>();

final freeTitleEntries = wiiudownloader
    .lookup<NativeFunction<free_native>>('FreeTitleEntries')
    .asFunction<free_dart>();

final _downloadTitle = wiiudownloader
    .lookup<NativeFunction<_DownloadTitleNative>>('DownloadTitle')
    .asFunction<_DownloadTitleDart>();

final _setTempDir = wiiudownloader
    .lookup<NativeFunction<Void Function(Pointer<Utf8>)>>('SetTempDir')
    .asFunction<void Function(Pointer<Utf8>)>();

final _fetchTMDSize = wiiudownloader
    .lookup<NativeFunction<Int64 Function(Uint64, Int32)>>('FetchTMDSize')
    .asFunction<int Function(int, int)>();

void setTempDir(String dir) {
  final ptr = dir.toNativeUtf8();
  _setTempDir(ptr);
  calloc.free(ptr);
}

int fetchTMDSize(int titleId, {int version = -1}) {
  final size = _fetchTMDSize(titleId, version);
  if (size < 0) {
    final versionText = version < 0 ? 'latest version' : 'version $version';
    throw Exception(
      'Failed to fetch size for title '
      '${titleId.toRadixString(16).toUpperCase().padLeft(16, '0')} '
      '($versionText)',
    );
  }
  return size;
}

class TitleEntryData {
  final String name;
  final int titleId;
  final int region;
  final int key;
  final int category;

  TitleEntryData({
    required this.name,
    required this.titleId,
    required this.region,
    required this.key,
    required this.category,
  });
}

List<TitleEntryData> search_title(String query, int category, int region) {
  final queryPtr = query.toNativeUtf8();

  final result = search(queryPtr, category, region);

  calloc.free(queryPtr);

  final list = <TitleEntryData>[];

  final ptr = result.data;

  for (int i = 0; i < result.length; i++) {
    final entry = (ptr + i).ref;

    list.add(
      TitleEntryData(
        name: entry.name.toDartString(),
        titleId: entry.title_id,
        region: entry.region,
        key: entry.key,
        category: entry.category,
      ),
    );
  }

  freeTitleEntries(result);

  return list;
}

/// Manages a single download with progress callbacks from Go.
///
/// Go runs the download in a goroutine and reports progress via C function
/// pointer callbacks. Strings passed to callbacks are allocated by Go (C.CString)
/// and freed on the Dart side after reading.
class DownloadTask {
  final void Function(String title)? onGameTitle;
  final void Function(int downloaded, String filename)? onProgress;
  final void Function(double progress)? onDecryptionProgress;
  final void Function(int size)? onDownloadSize;
  final void Function(String? error)? onDone;

  late final Pointer<Int32> _cancelledFlag;
  late final NativeCallable<OnGameTitleNative> _gameTitleCb;
  late final NativeCallable<OnProgressNative> _progressCb;
  late final NativeCallable<OnDecryptionNative> _decryptionCb;
  late final NativeCallable<OnSizeNative> _sizeCb;
  late final NativeCallable<OnDoneNative> _doneCb;
  bool _disposed = false;

  DownloadTask({
    this.onGameTitle,
    this.onProgress,
    this.onDecryptionProgress,
    this.onDownloadSize,
    this.onDone,
  }) {
    _cancelledFlag = calloc<Int32>();

    _gameTitleCb = NativeCallable<OnGameTitleNative>.listener((
      Pointer<Utf8> ptr,
    ) {
      onGameTitle?.call(ptr.toDartString());
      malloc.free(ptr);
    });

    _progressCb = NativeCallable<OnProgressNative>.listener((
      int downloaded,
      Pointer<Utf8> ptr,
    ) {
      onProgress?.call(downloaded, ptr.toDartString());
      malloc.free(ptr);
    });

    _decryptionCb = NativeCallable<OnDecryptionNative>.listener((
      double progress,
    ) {
      onDecryptionProgress?.call(progress);
    });

    _sizeCb = NativeCallable<OnSizeNative>.listener((int size) {
      onDownloadSize?.call(size);
    });

    _doneCb = NativeCallable<OnDoneNative>.listener((Pointer<Utf8> ptr) {
      final error = ptr.address == 0 ? null : ptr.toDartString();
      if (ptr.address != 0) malloc.free(ptr);
      onDone?.call(error);
      dispose();
    });
  }

  void start(
    String titleId,
    String outputPath, {
    bool decrypt = true,
    int version = -1,
  }) {
    final tidPtr = titleId.toNativeUtf8();
    final outPtr = outputPath.toNativeUtf8();

    _downloadTitle(
      tidPtr,
      outPtr,
      _gameTitleCb.nativeFunction,
      _progressCb.nativeFunction,
      _decryptionCb.nativeFunction,
      _sizeCb.nativeFunction,
      _cancelledFlag,
      _doneCb.nativeFunction,
      version,
      decrypt ? 1 : 0,
    );

    calloc.free(tidPtr);
    calloc.free(outPtr);
  }

  void cancel() {
    _cancelledFlag.value = 1;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _gameTitleCb.close();
    _progressCb.close();
    _decryptionCb.close();
    _sizeCb.close();
    _doneCb.close();
    calloc.free(_cancelledFlag);
  }
}

String categoryName(int category) {
  switch (category) {
    case 0:
      return 'Game';
    case 1:
      return 'Update';
    case 2:
      return 'DLC';
    case 3:
      return 'Demo';
    case 4:
      return 'All';
    default:
      return 'Other';
  }
}

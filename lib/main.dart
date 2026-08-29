import 'package:emotion_cord/dccon_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:io';
import 'dart:convert';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SideCord',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

enum FolderType { images, texts }

const String recentFolderName = '최근 사용';
const int recentFolderLimit = 100;

class _DcconFolderUpdate {
  const _DcconFolderUpdate({
    required this.folderName,
    required this.detail,
    required this.status,
  });

  final String folderName;
  final DcconPackageDetail detail;
  final DcconInstallStatus status;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final ImagePicker _imagePicker = ImagePicker();
  final DcconClient _dcconUpdateClient = DcconClient();
  final DcconInstallStore _dcconInstallStore = DcconInstallStore();
  Map<String, List<String>> _imageFolders = {};
  Map<String, List<String>> _textFolders = {};
  List<String> _imageFolderOrder = [];
  List<String> _textFolderOrder = [];
  String _currentImageFolder = recentFolderName;
  String _currentTextFolder = recentFolderName;
  Timer? _dcconSyncTimer;
  int _dcconCompletionVersion = 0;
  final Map<String, _DcconFolderUpdate> _dcconFolderUpdates = {};
  final Set<String> _updatingDcconFolders = {};
  bool _checkingDcconUpdates = false;
  static const platform = MethodChannel('com.yourapp/overlay');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _loadFolderData().then((_) {
      if (mounted) {
        _initializeOverlay();
        _refreshDcconFolderUpdates();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dcconSyncTimer?.cancel();
    _dcconUpdateClient.close();
    _stopMonitoring();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reloadAfterResume();
    }
  }

  Future<void> _reloadAfterResume() async {
    await _loadFolderData();
    _startDcconSyncPolling();
    await _refreshDcconFolderUpdates();
  }

  Future<void> _initializeOverlay() async {
    if (kIsWeb) return;
    try {
      await _startMonitoring();
    } catch (e) {
      // Silently handle errors
    }
  }

  Future<void> _stopMonitoring() async {
    if (kIsWeb) return;
    try {
      await platform.invokeMethod('stopMonitoring');
    } catch (e) {
      // Silently handle errors
    }
  }

  Future<void> _startMonitoring() async {
    if (kIsWeb) return;
    try {
      await platform.invokeMethod('startMonitoring');
    } catch (e) {
      // Silently handle errors
    }
  }

  Future<Directory?> _getAppStorageDirectory() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (e) {
      return null;
    }
  }

  Future<Directory?> _getImagesDirectory() async {
    final baseDir = await _getAppStorageDirectory();
    if (baseDir == null) return null;
    final dir = Directory('${baseDir.path}/stored_images');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory?> _getIconsDirectory() async {
    final baseDir = await _getAppStorageDirectory();
    if (baseDir == null) return null;
    final dir = Directory('${baseDir.path}/overlay_icons');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _loadFolderData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final imageJson = prefs.getString('image_folders');
      final textJson = prefs.getString('text_folders');
      final imageOrderJson = prefs.getString('image_folder_order');
      final textOrderJson = prefs.getString('text_folder_order');

      _imageFolders = _decodeFolderMap(imageJson);
      _textFolders = _decodeFolderMap(textJson);
      _imageFolderOrder = _decodeFolderOrder(imageOrderJson);
      _textFolderOrder = _decodeFolderOrder(textOrderJson);

      if (_imageFolders.isEmpty) {
        final legacy = prefs.getStringList('saved_images') ?? [];
        if (legacy.isNotEmpty) {
          _imageFolders[recentFolderName] = List<String>.from(legacy);
        }
      }

      if (_textFolders.isEmpty) {
        final legacy = prefs.getStringList('saved_texts') ?? [];
        if (legacy.isNotEmpty) {
          _textFolders[recentFolderName] = List<String>.from(legacy);
        }
      }

      _ensureDefaultFolders();
      _normalizeFolderOrder();

      _currentImageFolder =
          prefs.getString('current_image_folder') ?? recentFolderName;
      _currentTextFolder =
          prefs.getString('current_text_folder') ?? recentFolderName;
      if (!_imageFolders.containsKey(_currentImageFolder)) {
        _currentImageFolder = recentFolderName;
      }
      if (!_textFolders.containsKey(_currentTextFolder)) {
        _currentTextFolder = recentFolderName;
      }

      if (mounted) {
        setState(() {});
      }

      await _saveImageFolders();
      await _saveTextFolders();
      await _saveFolderOrders();
    } catch (e) {
      // Silently handle errors
    }
  }

  void _ensureDefaultFolders() {
    _migrateDefaultFolder(_imageFolders);
    _migrateDefaultFolder(_textFolders);
    _imageFolders.putIfAbsent(recentFolderName, () => []);
    _textFolders.putIfAbsent(recentFolderName, () => []);
  }

  void _migrateDefaultFolder(Map<String, List<String>> folders) {
    final legacy = folders.remove('기본');
    if (legacy == null || legacy.isEmpty) return;
    final recent = folders.putIfAbsent(recentFolderName, () => []);
    for (final item in legacy) {
      if (!recent.contains(item)) {
        recent.add(item);
      }
    }
  }

  void _normalizeFolderOrder() {
    if (_imageFolderOrder.isEmpty) {
      _imageFolderOrder = _imageFolders.keys.toList();
    }
    if (_textFolderOrder.isEmpty) {
      _textFolderOrder = _textFolders.keys.toList();
    }
    _imageFolderOrder.remove('기본');
    _textFolderOrder.remove('기본');
    _imageFolderOrder.remove(recentFolderName);
    _textFolderOrder.remove(recentFolderName);
    _imageFolderOrder.insert(0, recentFolderName);
    _textFolderOrder.insert(0, recentFolderName);
    _imageFolderOrder = _imageFolderOrder
        .where((name) => _imageFolders.containsKey(name))
        .toList();
    _textFolderOrder = _textFolderOrder
        .where((name) => _textFolders.containsKey(name))
        .toList();
    for (final name in _imageFolders.keys) {
      if (!_imageFolderOrder.contains(name)) {
        _imageFolderOrder.add(name);
      }
    }
    for (final name in _textFolders.keys) {
      if (!_textFolderOrder.contains(name)) {
        _textFolderOrder.add(name);
      }
    }
  }

  bool _isProtectedFolder(String name) =>
      name == recentFolderName || name == '기본';

  Map<String, List<String>> _decodeFolderMap(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return {};
    try {
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final result = <String, List<String>>{};
      decoded.forEach((key, value) {
        if (value is List) {
          result[key] = value.map((e) => e.toString()).toList();
        }
      });
      return result;
    } catch (e) {
      return {};
    }
  }

  List<String> _decodeFolderOrder(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return [];
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  Future<void> _saveImageFolders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode(_imageFolders);
      await prefs.setString('image_folders', jsonStr);
      if (!kIsWeb) {
        await platform.invokeMethod('setImageFolders', {'data': jsonStr});
        await platform.invokeMethod('setCurrentImageFolder', {
          'name': _currentImageFolder,
        });
      }
    } catch (e) {
      // Silently handle errors
    }
  }

  Future<void> _saveTextFolders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode(_textFolders);
      await prefs.setString('text_folders', jsonStr);
      if (!kIsWeb) {
        await platform.invokeMethod('setTextFolders', {'data': jsonStr});
        await platform.invokeMethod('setCurrentTextFolder', {
          'name': _currentTextFolder,
        });
      }
    } catch (e) {
      // Silently handle errors
    }
  }

  Future<void> _saveFolderOrders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'image_folder_order',
        jsonEncode(_imageFolderOrder),
      );
      await prefs.setString('text_folder_order', jsonEncode(_textFolderOrder));
      if (!kIsWeb) {
        await platform.invokeMethod('setImageFolderOrder', {
          'data': jsonEncode(_imageFolderOrder),
        });
        await platform.invokeMethod('setTextFolderOrder', {
          'data': jsonEncode(_textFolderOrder),
        });
      }
    } catch (e) {
      // Silently handle errors
    }
  }

  Future<void> _createFolder(FolderType type, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    if (_isProtectedFolder(trimmed)) return;
    setState(() {
      if (type == FolderType.images) {
        _imageFolders.putIfAbsent(trimmed, () => []);
        if (!_imageFolderOrder.contains(trimmed)) {
          _imageFolderOrder.add(trimmed);
        }
      } else {
        _textFolders.putIfAbsent(trimmed, () => []);
        if (!_textFolderOrder.contains(trimmed)) {
          _textFolderOrder.add(trimmed);
        }
      }
    });
    if (type == FolderType.images) {
      await _saveImageFolders();
    } else {
      await _saveTextFolders();
    }
    await _saveFolderOrders();
  }

  Future<void> _renameFolder(
    FolderType type,
    String oldName,
    String newName,
  ) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == oldName) return;
    if (_isProtectedFolder(oldName) || _isProtectedFolder(trimmed)) return;
    setState(() {
      if (type == FolderType.images) {
        final items = _imageFolders.remove(oldName) ?? [];
        _imageFolders[trimmed] = items;
        if (_currentImageFolder == oldName) {
          _currentImageFolder = trimmed;
        }
        final index = _imageFolderOrder.indexOf(oldName);
        if (index >= 0) {
          _imageFolderOrder[index] = trimmed;
        }
      } else {
        final items = _textFolders.remove(oldName) ?? [];
        _textFolders[trimmed] = items;
        if (_currentTextFolder == oldName) {
          _currentTextFolder = trimmed;
        }
        final index = _textFolderOrder.indexOf(oldName);
        if (index >= 0) {
          _textFolderOrder[index] = trimmed;
        }
      }
    });
    if (type == FolderType.images) {
      await _saveImageFolders();
      await _dcconInstallStore.renameFolder(oldName, trimmed);
      if (mounted) {
        setState(() {
          final update = _dcconFolderUpdates.remove(oldName);
          if (update != null) {
            _dcconFolderUpdates[trimmed] = _DcconFolderUpdate(
              folderName: trimmed,
              detail: update.detail,
              status: update.status,
            );
          }
        });
      }
    } else {
      await _saveTextFolders();
    }
    await _saveFolderOrders();
  }

  Future<void> _deleteFolder(FolderType type, String name) async {
    if (_isProtectedFolder(name)) return;
    setState(() {
      if (type == FolderType.images) {
        _imageFolders.remove(name);
        _imageFolders.putIfAbsent(recentFolderName, () => []);
        if (_currentImageFolder == name) {
          _currentImageFolder = recentFolderName;
        }
        _imageFolderOrder.remove(name);
        if (!_imageFolderOrder.contains(recentFolderName)) {
          _imageFolderOrder.insert(0, recentFolderName);
        }
      } else {
        _textFolders.remove(name);
        _textFolders.putIfAbsent(recentFolderName, () => []);
        if (_currentTextFolder == name) {
          _currentTextFolder = recentFolderName;
        }
        _textFolderOrder.remove(name);
        if (!_textFolderOrder.contains(recentFolderName)) {
          _textFolderOrder.insert(0, recentFolderName);
        }
      }
    });
    if (type == FolderType.images) {
      await _saveImageFolders();
      await _dcconInstallStore.removeFolder(name);
      if (mounted) {
        setState(() => _dcconFolderUpdates.remove(name));
      }
    } else {
      await _saveTextFolders();
    }
    await _saveFolderOrders();
  }

  Future<void> _addImagesToFolder(String folderName) async {
    if (kIsWeb) return;
    if (_isProtectedFolder(folderName)) return;
    try {
      final List<XFile> images = await _imagePicker.pickMultiImage();
      if (images.isEmpty) return;
      final imagesDir = await _getImagesDirectory();
      if (imagesDir == null) return;

      final list = _imageFolders[folderName] ?? [];
      for (final image in images) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final extension = _inferImageExtension(image);
        final savedPath = _buildUniqueImagePath(
          imagesDir.path,
          timestamp,
          extension,
        );
        final file = File(image.path);
        await file.copy(savedPath);
        list.add(savedPath);
      }
      _imageFolders[folderName] = list;
      await _saveImageFolders();
      if (mounted) setState(() {});
    } catch (e) {
      // Silently handle errors
    }
  }

  Future<void> _openDcconBrowser() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DcconBrowserPage(onImport: _importDcconIcons),
      ),
    );
    await _loadFolderData();
    await _refreshDcconFolderUpdates();
  }

  Future<void> _refreshDcconFolderUpdates() async {
    if (_checkingDcconUpdates) return;
    _checkingDcconUpdates = true;
    if (mounted) {
      setState(() => _dcconFolderUpdates.clear());
    }

    try {
      final installed = await _dcconInstallStore.installedPackages();
      final mappedFolders = installed.map((item) => item.folderName).toSet();
      for (final item in installed) {
        await _checkDcconPackageUpdate(item);
      }

      final legacyFolders = _imageFolderOrder.where(
        (name) =>
            !_isProtectedFolder(name) &&
            (_imageFolders[name]?.isNotEmpty ?? false) &&
            !mappedFolders.contains(name),
      );
      for (final folderName in legacyFolders) {
        try {
          final results = await _dcconUpdateClient.search(folderName);
          final normalizedFolder = _normalizeDcconTitle(folderName);
          final package = results.cast<DcconPackage?>().firstWhere(
            (item) =>
                item != null &&
                _normalizeDcconTitle(item.title) == normalizedFolder,
            orElse: () => null,
          );
          if (package == null) continue;
          final detail = await _dcconUpdateClient.loadDetail(package);
          final status = await _dcconInstallStore.statusFor(
            detail.package,
            detail.icons,
          );
          await _dcconInstallStore.recordImport(
            detail.package,
            const [],
            catalogIcons: detail.icons,
            existingIcons: status.installedIcons,
          );
          _setDcconFolderUpdate(folderName, detail, status);
        } catch (_) {
          // Manually created folders do not need to match a dccon package.
        }
      }
    } finally {
      _checkingDcconUpdates = false;
    }
  }

  Future<void> _checkDcconPackageUpdate(DcconInstalledPackage installed) async {
    try {
      final detail = await _dcconUpdateClient.loadDetail(installed.package);
      final status = await _dcconInstallStore.statusFor(
        detail.package,
        detail.icons,
      );
      _setDcconFolderUpdate(installed.folderName, detail, status);
    } catch (_) {
      // Keep the folder list usable when an update check fails.
    }
  }

  void _setDcconFolderUpdate(
    String folderName,
    DcconPackageDetail detail,
    DcconInstallStatus status,
  ) {
    if (!mounted) return;
    if (!_imageFolders.containsKey(folderName)) return;
    setState(() {
      if (status.missingIcons.isEmpty) {
        _dcconFolderUpdates.remove(folderName);
      } else {
        _dcconFolderUpdates[folderName] = _DcconFolderUpdate(
          folderName: folderName,
          detail: detail,
          status: status,
        );
      }
    });
  }

  String _normalizeDcconTitle(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  Future<void> _updateDcconFolder(_DcconFolderUpdate update) async {
    if (_updatingDcconFolders.contains(update.folderName)) return;
    setState(() => _updatingDcconFolders.add(update.folderName));
    try {
      final package = DcconPackage(
        id: update.detail.package.id,
        title: update.folderName,
        seller: update.detail.package.seller,
        thumbnailUrl: update.detail.package.thumbnailUrl,
      );
      final count = await _importDcconIcons(
        package,
        update.status.missingIcons,
        catalogIcons: update.detail.icons,
        existingIcons: update.status.installedIcons,
      );
      if (!mounted) return;
      setState(() => _dcconFolderUpdates.remove(update.folderName));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$count개 추가 디시콘 다운로드를 시작했습니다.')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('디시콘 업데이트를 시작하지 못했습니다.')));
    } finally {
      if (mounted) {
        setState(() => _updatingDcconFolders.remove(update.folderName));
      }
    }
  }

  Future<int> _importDcconIcons(
    DcconPackage package,
    List<DcconIcon> icons, {
    DcconImportProgressCallback? onProgress,
    List<DcconIcon>? catalogIcons,
    List<DcconIcon>? existingIcons,
  }) async {
    if (icons.isEmpty) return 0;

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final folderName = _dcconFolderName(package);
      final queued = await platform.invokeMethod<bool>('startDcconDownload', {
        'data': jsonEncode({
          'packageId': package.id,
          'title': package.title,
          'folderName': folderName,
          'icons': [
            for (final icon in icons)
              {
                'title': icon.title,
                'url': icon.imageUrl,
                'extension': icon.extension,
              },
          ],
          'catalogUrls': [
            for (final icon in catalogIcons ?? const <DcconIcon>[])
              icon.imageUrl,
          ],
          'existingUrls': [
            for (final icon in existingIcons ?? const <DcconIcon>[])
              icon.imageUrl,
          ],
        }),
      });
      if (queued != true) {
        throw Exception('Cannot start background download.');
      }
      _startDcconSyncPolling();
      return icons.length;
    }

    final imagesDir = await _getImagesDirectory();
    if (imagesDir == null) {
      throw Exception('Cannot open image storage directory.');
    }

    final folderName = _dcconFolderName(package);
    final list = List<String>.from(_imageFolders[folderName] ?? const []);
    var imported = 0;
    final importedIcons = <DcconIcon>[];
    final client = http.Client();
    onProgress?.call(
      DcconImportProgress(
        total: icons.length,
        completed: 0,
        saved: 0,
        currentTitle: '다운로드 준비 중',
      ),
    );

    try {
      for (var i = 0; i < icons.length; i += 1) {
        final icon = icons[i];
        final savedPath = await _downloadDcconIcon(
          client: client,
          imagesDir: imagesDir,
          icon: icon,
          index: i,
        );
        if (savedPath != null) {
          list.add(savedPath);
          importedIcons.add(icon);
          imported += 1;
        }
        onProgress?.call(
          DcconImportProgress(
            total: icons.length,
            completed: i + 1,
            saved: imported,
            currentTitle: _dcconIconProgressLabel(icon, i),
          ),
        );
      }
    } finally {
      client.close();
    }

    if (imported == 0) return 0;

    _imageFolders[folderName] = list;
    if (!_imageFolderOrder.contains(folderName)) {
      _imageFolderOrder.add(folderName);
    }
    _currentImageFolder = folderName;
    if (mounted) setState(() {});
    await _saveImageFolders();
    await _saveFolderOrders();
    await DcconInstallStore().recordImport(
      package,
      importedIcons,
      catalogIcons: catalogIcons,
      existingIcons: existingIcons,
    );
    return imported;
  }

  void _startDcconSyncPolling() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _dcconSyncTimer?.cancel();
    _dcconSyncTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final status = await platform.invokeMapMethod<String, dynamic>(
          'getDcconDownloadStatus',
        );
        if (status == null) return;
        final active = (status['active'] as num?)?.toInt() ?? 0;
        final version = (status['completedVersion'] as num?)?.toInt() ?? 0;
        if (version != _dcconCompletionVersion) {
          _dcconCompletionVersion = version;
          await _loadFolderData();
          await _refreshDcconFolderUpdates();
        }
        if (active <= 0) {
          _dcconSyncTimer?.cancel();
          _dcconSyncTimer = null;
        }
      } catch (_) {
        _dcconSyncTimer?.cancel();
        _dcconSyncTimer = null;
      }
    });
  }

  String _dcconIconProgressLabel(DcconIcon icon, int index) {
    final title = icon.title.trim();
    if (title.isNotEmpty) return title;
    return '${index + 1}번 콘';
  }

  Future<String?> _downloadDcconIcon({
    required http.Client client,
    required Directory imagesDir,
    required DcconIcon icon,
    required int index,
  }) async {
    try {
      final response = await client.get(
        Uri.parse(icon.imageUrl),
        headers: DcconClient.imageHeaders,
      );
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.bodyBytes.isEmpty) {
        return null;
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch + index;
      final extension = _normalizeDcconExtension(icon.extension, response);
      final savedPath = _buildUniqueImagePath(
        imagesDir.path,
        timestamp,
        extension,
      );
      await File(savedPath).writeAsBytes(response.bodyBytes, flush: true);
      return savedPath;
    } catch (_) {
      return null;
    }
  }

  String _dcconFolderName(DcconPackage package) {
    final title = DcconInstallStore.folderName(package);
    if (title.isNotEmpty && !_isProtectedFolder(title)) return title;
    return '디시콘 ${package.id}';
  }

  String _normalizeDcconExtension(String extension, http.Response response) {
    final clean = extension
        .replaceAll('.', '')
        .split('?')
        .first
        .trim()
        .toLowerCase();
    if (clean == 'gif' ||
        clean == 'png' ||
        clean == 'jpg' ||
        clean == 'jpeg' ||
        clean == 'webp') {
      return '.$clean';
    }

    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    if (contentType.contains('gif')) return '.gif';
    if (contentType.contains('webp')) return '.webp';
    if (contentType.contains('jpeg') || contentType.contains('jpg')) {
      return '.jpg';
    }
    return '.png';
  }

  String _buildUniqueImagePath(
    String dirPath,
    int timestamp,
    String extension,
  ) {
    var candidate = '$dirPath/img_$timestamp$extension';
    var suffix = 1;
    while (File(candidate).existsSync()) {
      candidate = '$dirPath/img_${timestamp}_$suffix$extension';
      suffix += 1;
    }
    return candidate;
  }

  String _inferImageExtension(XFile image) {
    final fromName = _extractExtension(image.name);
    if (fromName.isNotEmpty) return fromName.toLowerCase();
    final fromPath = _extractExtension(image.path);
    if (fromPath.isNotEmpty) return fromPath.toLowerCase();
    return '.jpg';
  }

  String _extractExtension(String path) {
    final dot = path.lastIndexOf('.');
    if (dot <= 0 || dot >= path.length - 1) return '';
    return path.substring(dot);
  }

  Future<void> _addTextToFolder(String folderName, String text) async {
    if (_isProtectedFolder(folderName)) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final list = _textFolders[folderName] ?? [];
    list.insert(0, trimmed);
    _textFolders[folderName] = list;
    await _saveTextFolders();
    if (mounted) setState(() {});
  }

  Future<void> _openFolder(FolderType type, String name) async {
    setState(() {
      if (type == FolderType.images) {
        _currentImageFolder = name;
        _imageFolders.putIfAbsent(name, () => []);
      } else {
        _currentTextFolder = name;
        _textFolders.putIfAbsent(name, () => []);
      }
    });
    if (type == FolderType.images) {
      await _saveImageFolders();
    } else {
      await _saveTextFolders();
    }
    if (!mounted) return;
    final imagePaths = _imageFolders[name] ?? [];
    final texts = _textFolders[name] ?? [];
    final readOnly = _isProtectedFolder(name);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FolderDetailPage(
          type: type,
          folderName: name,
          imagePaths: imagePaths,
          texts: texts,
          readOnly: readOnly,
          onAddImages: () => _addImagesToFolder(name),
          onAddText: (text) => _addTextToFolder(name, text),
          onDeleteImages: (paths) => _deleteImagesFromFolder(name, paths),
          onReorderImages: (paths) => _updateImageOrder(name, paths),
          onReorderTexts: (items) => _updateTextOrder(name, items),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _updateImageOrder(String folderName, List<String> paths) async {
    _imageFolders[folderName] = List<String>.from(paths);
    await _saveImageFolders();
    if (mounted) setState(() {});
  }

  Future<void> _updateTextOrder(String folderName, List<String> items) async {
    _textFolders[folderName] = List<String>.from(items);
    await _saveTextFolders();
    if (mounted) setState(() {});
  }

  Future<void> _deleteImagesFromFolder(
    String folderName,
    List<String> paths,
  ) async {
    if (_isProtectedFolder(folderName)) return;
    if (paths.isEmpty) return;
    final list = _imageFolders[folderName] ?? [];
    list.removeWhere(paths.contains);
    _imageFolders[folderName] = list;
    for (final path in paths) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          await file.delete();
        }
      } catch (e) {
        // Silently handle errors
      }
    }
    await _saveImageFolders();
    if (mounted) setState(() {});
  }

  Future<void> _showOverlaySettingsDialog() async {
    if (kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    double sizeDp = prefs.getDouble('overlay_size_dp') ?? 72.0;
    String? iconPath = prefs.getString('overlay_icon_path');
    double borderDp = prefs.getDouble('overlay_border_dp') ?? 10.0;
    double thumbDp = prefs.getDouble('overlay_thumb_dp') ?? 64.0;
    bool overlayButtonEnabled = prefs.getBool('overlay_button_enabled') ?? true;

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('오버레이 설정'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: () {
                      final hasIcon =
                          iconPath != null && File(iconPath!).existsSync();
                      if (hasIcon) {
                        final image = Image.file(
                          File(iconPath!),
                          fit: BoxFit.cover,
                        );
                        return ClipOval(child: image);
                      }
                      final icon = const Icon(Icons.photo, size: 48);
                      return ClipOval(
                        child: Container(
                          alignment: Alignment.center,
                          child: icon,
                        ),
                      );
                    }(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: overlayButtonEnabled,
                          onChanged: (value) {
                            setDialogState(() {
                              overlayButtonEnabled = value;
                            });
                          },
                          title: const Text('옆 오버레이 버튼'),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const SizedBox(width: 44, child: Text('크기')),
                      Expanded(
                        child: Slider(
                          value: sizeDp,
                          min: 48,
                          max: 120,
                          divisions: 12,
                          label: sizeDp.round().toString(),
                          onChanged: (value) {
                            setDialogState(() {
                              sizeDp = value;
                            });
                          },
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(sizeDp.round().toString()),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const SizedBox(width: 44, child: Text('테두리')),
                      Expanded(
                        child: Slider(
                          value: borderDp,
                          min: 0,
                          max: 16,
                          divisions: 16,
                          label: borderDp.round().toString(),
                          onChanged: (value) {
                            setDialogState(() {
                              borderDp = value;
                            });
                          },
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(borderDp.round().toString()),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const SizedBox(width: 44, child: Text('갤러리 해상도')),
                      Expanded(
                        child: Slider(
                          value: thumbDp,
                          min: 8,
                          max: 96,
                          divisions: 22,
                          label: thumbDp.round().toString(),
                          onChanged: (value) {
                            setDialogState(() {
                              thumbDp = value;
                            });
                          },
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(thumbDp.round().toString()),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () async {
                          final image = await _imagePicker.pickImage(
                            source: ImageSource.gallery,
                          );
                          if (image == null) return;
                          final iconsDir = await _getIconsDirectory();
                          if (iconsDir == null) return;
                          final fileName =
                              'overlay_icon_${DateTime.now().millisecondsSinceEpoch}_${image.name}';
                          final savedPath = '${iconsDir.path}/$fileName';
                          await File(image.path).copy(savedPath);
                          setDialogState(() {
                            iconPath = savedPath;
                          });
                        },
                        child: const Text('아이콘 변경'),
                      ),
                      TextButton(
                        onPressed: () {
                          setDialogState(() {
                            iconPath = null;
                          });
                        },
                        child: const Text('기본 아이콘'),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('취소'),
                ),
                TextButton(
                  onPressed: () async {
                    await prefs.setDouble('overlay_size_dp', sizeDp);
                    await prefs.setDouble('overlay_border_dp', borderDp);
                    await prefs.setDouble('overlay_thumb_dp', thumbDp);
                    await prefs.setBool(
                      'overlay_button_enabled',
                      overlayButtonEnabled,
                    );
                    if (iconPath == null) {
                      await prefs.remove('overlay_icon_path');
                    } else {
                      await prefs.setString('overlay_icon_path', iconPath!);
                    }
                    if (!kIsWeb) {
                      await platform.invokeMethod('setOverlaySettings', {
                        'sizeDp': sizeDp,
                        'iconPath': iconPath,
                        'borderDp': borderDp,
                        'thumbDp': thumbDp,
                        'buttonEnabled': overlayButtonEnabled,
                      });
                    }
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                  child: const Text('저장'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('SideCord'),
          centerTitle: true,
          elevation: 0,
          bottom: const TabBar(
            tabs: [
              Tab(text: '사진 폴더'),
              Tab(text: '텍스트 폴더'),
            ],
          ),
          actions: [
            IconButton(
              onPressed: _openDcconBrowser,
              icon: const Icon(Icons.emoji_emotions_outlined),
              tooltip: '디시콘',
            ),
            IconButton(
              onPressed: _showOverlaySettingsDialog,
              icon: const Icon(Icons.tune),
              tooltip: '오버레이 설정',
            ),
          ],
        ),
        body: TabBarView(
          children: [
            _buildFolderList(FolderType.images),
            _buildFolderList(FolderType.texts),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderList(FolderType type) {
    final folders = type == FolderType.images ? _imageFolders : _textFolders;
    final names = type == FolderType.images
        ? List<String>.from(_imageFolderOrder)
        : List<String>.from(_textFolderOrder);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  type == FolderType.images ? '사진 폴더' : '텍스트 폴더',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => _showCreateFolderDialog(type),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('새 폴더'),
              ),
            ],
          ),
        ),
        Expanded(
          child: names.isEmpty
              ? Center(
                  child: Text(
                    '폴더가 없습니다',
                    style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                  ),
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: names.length,
                  onReorder: (oldIndex, newIndex) {
                    final draggedName = names[oldIndex];
                    if (_isProtectedFolder(draggedName)) return;
                    setState(() {
                      if (newIndex > oldIndex) {
                        newIndex -= 1;
                      }
                      final name = names.removeAt(oldIndex);
                      names.insert(newIndex, name);
                      if (type == FolderType.images) {
                        _imageFolderOrder = List<String>.from(names);
                      } else {
                        _textFolderOrder = List<String>.from(names);
                      }
                      _normalizeFolderOrder();
                    });
                    _saveFolderOrders();
                  },
                  itemBuilder: (context, index) {
                    final name = names[index];
                    final items = folders[name] ?? const <String>[];
                    final count = items.length;
                    final isProtected = _isProtectedFolder(name);
                    final dcconUpdate = type == FolderType.images
                        ? _dcconFolderUpdates[name]
                        : null;
                    final isUpdating = _updatingDcconFolders.contains(name);
                    return ListTile(
                      key: ValueKey(name),
                      leading: _FolderPreview(type: type, items: items),
                      title: Text(name),
                      subtitle: dcconUpdate == null
                          ? Text('항목 $count')
                          : Row(
                              children: [
                                Text('항목 $count'),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: TextButton.icon(
                                    onPressed: isUpdating
                                        ? null
                                        : () => _updateDcconFolder(dcconUpdate),
                                    icon: isUpdating
                                        ? const SizedBox.square(
                                            dimension: 14,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.system_update_alt,
                                            size: 17,
                                          ),
                                    label: Text(
                                      '업데이트 +${dcconUpdate.status.missingIcons.length}',
                                    ),
                                    style: TextButton.styleFrom(
                                      minimumSize: const Size(0, 32),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                      onTap: () => _openFolder(type, name),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!isProtected)
                            PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'rename') {
                                  _showRenameFolderDialog(type, name);
                                } else if (value == 'delete') {
                                  _showDeleteFolderDialog(type, name);
                                }
                              },
                              itemBuilder: (context) => [
                                const PopupMenuItem(
                                  value: 'rename',
                                  child: Text('이름 변경'),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('삭제'),
                                ),
                              ],
                            ),
                          if (!isProtected)
                            ReorderableDragStartListener(
                              index: index,
                              child: const Padding(
                                padding: EdgeInsets.all(8),
                                child: Icon(Icons.drag_handle),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showCreateFolderDialog(FolderType type) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('폴더 추가'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: '폴더 이름',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _createFolder(type, controller.text);
              },
              child: const Text('추가'),
            ),
          ],
        );
      },
    );
  }

  void _showRenameFolderDialog(FolderType type, String name) {
    final controller = TextEditingController(text: name);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('폴더 이름 변경'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: '폴더 이름',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _renameFolder(type, name, controller.text);
              },
              child: const Text('변경'),
            ),
          ],
        );
      },
    );
  }

  void _showDeleteFolderDialog(FolderType type, String name) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('폴더 삭제'),
          content: Text('"$name" 폴더를 삭제하시겠습니까?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _deleteFolder(type, name);
              },
              child: const Text('삭제'),
            ),
          ],
        );
      },
    );
  }
}

class _FolderPreview extends StatelessWidget {
  const _FolderPreview({required this.type, required this.items});

  final FolderType type;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final firstImage = type == FolderType.images ? _firstExistingImage() : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: 48,
        child: firstImage == null
            ? ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  type == FolderType.images
                      ? Icons.photo_library_outlined
                      : Icons.notes_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : Image.file(File(firstImage), fit: BoxFit.cover),
      ),
    );
  }

  String? _firstExistingImage() {
    for (final path in items) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }
}

class FolderDetailPage extends StatefulWidget {
  const FolderDetailPage({
    super.key,
    required this.type,
    required this.folderName,
    required this.imagePaths,
    required this.texts,
    required this.readOnly,
    required this.onAddImages,
    required this.onAddText,
    required this.onDeleteImages,
    required this.onReorderImages,
    required this.onReorderTexts,
  });

  final FolderType type;
  final String folderName;
  final List<String> imagePaths;
  final List<String> texts;
  final bool readOnly;
  final Future<void> Function() onAddImages;
  final Future<void> Function(String text) onAddText;
  final Future<void> Function(List<String> paths) onDeleteImages;
  final Future<void> Function(List<String> paths) onReorderImages;
  final Future<void> Function(List<String> items) onReorderTexts;

  @override
  State<FolderDetailPage> createState() => _FolderDetailPageState();
}

class _FolderDetailPageState extends State<FolderDetailPage> {
  final TextEditingController _textController = TextEditingController();
  final Set<String> _selectedImages = {};
  final ScrollController _imageScrollController = ScrollController();
  final GlobalKey _imageGridKey = GlobalKey();

  @override
  void dispose() {
    _textController.dispose();
    _imageScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isImages = widget.type == FolderType.images;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectedImages.isEmpty
              ? widget.folderName
              : '${_selectedImages.length} 선택됨',
        ),
        actions: [
          if (isImages && _selectedImages.isNotEmpty && !widget.readOnly)
            IconButton(
              onPressed: _confirmDeleteSelected,
              icon: const Icon(Icons.delete),
              tooltip: '삭제',
            ),
        ],
      ),
      body: isImages ? _buildImageGrid() : _buildTextList(),
      floatingActionButton: widget.readOnly
          ? null
          : FloatingActionButton(
              onPressed: () async {
                if (isImages) {
                  await widget.onAddImages();
                  if (mounted) setState(() {});
                } else {
                  final text = _textController.text.trim();
                  if (text.isNotEmpty) {
                    await widget.onAddText(text);
                    _textController.clear();
                    if (mounted) setState(() {});
                  }
                }
              },
              tooltip: '추가',
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildImageGrid() {
    if (widget.imagePaths.isEmpty) {
      return Center(
        child: Text(
          '이미지가 없습니다',
          style: TextStyle(fontSize: 16, color: Colors.grey[600]),
        ),
      );
    }
    return GridView.builder(
      key: _imageGridKey,
      controller: _imageScrollController,
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: widget.imagePaths.length,
      itemBuilder: (context, index) {
        final path = widget.imagePaths[index];
        final selected = _selectedImages.contains(path);
        return DragTarget<String>(
          onWillAcceptWithDetails: (details) =>
              !widget.readOnly && details.data != path,
          onAcceptWithDetails: (details) async {
            if (widget.readOnly) return;
            final data = details.data;
            final fromIndex = widget.imagePaths.indexOf(data);
            if (fromIndex == -1) return;
            setState(() {
              widget.imagePaths.removeAt(fromIndex);
              widget.imagePaths.insert(index, data);
            });
            await widget.onReorderImages(widget.imagePaths);
          },
          builder: (context, candidateData, rejectedData) {
            final isTarget = candidateData.isNotEmpty;
            final screenWidth = MediaQuery.of(context).size.width;
            final tileSize = ((screenWidth - 16 - (8 * 2)) / 3).clamp(
              56.0,
              140.0,
            );
            return LongPressDraggable<String>(
              data: path,
              maxSimultaneousDrags: widget.readOnly ? 0 : 1,
              onDragUpdate: _handleImageDragUpdate,
              feedback: Material(
                color: Colors.transparent,
                elevation: 6,
                borderRadius: BorderRadius.circular(8),
                child: SizedBox.square(
                  dimension: tileSize,
                  child: Transform.scale(
                    scale: 0.9,
                    child: Opacity(
                      opacity: 0.92,
                      child: _buildImageTile(path, selected, isDragging: true),
                    ),
                  ),
                ),
              ),
              childWhenDragging: Opacity(
                opacity: 0.3,
                child: _buildImageTile(path, selected),
              ),
              child: GestureDetector(
                onTap: () {
                  if (widget.readOnly) return;
                  setState(() {
                    if (selected) {
                      _selectedImages.remove(path);
                    } else {
                      _selectedImages.add(path);
                    }
                  });
                },
                child: _buildImageTile(path, selected, isTarget: isTarget),
              ),
            );
          },
        );
      },
    );
  }

  void _handleImageDragUpdate(DragUpdateDetails details) {
    if (!_imageScrollController.hasClients) return;
    final box = _imageGridKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final local = box.globalToLocal(details.globalPosition);
    final size = box.size;
    const edgeThreshold = 72.0;
    const scrollStep = 18.0;

    final position = _imageScrollController.position;
    var target = position.pixels;
    if (local.dy < edgeThreshold) {
      target = (target - scrollStep).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
    } else if (local.dy > size.height - edgeThreshold) {
      target = (target + scrollStep).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
    } else {
      return;
    }
    if (target != position.pixels) {
      _imageScrollController.jumpTo(target);
    }
  }

  Widget _buildImageTile(
    String path,
    bool selected, {
    bool isTarget = false,
    bool isDragging = false,
  }) {
    final scale = isDragging
        ? 1.06
        : isTarget
        ? 1.02
        : 1.0;
    return AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isTarget
                ? Colors.lightBlueAccent
                : selected
                ? Colors.blue
                : Colors.grey[300] ?? Colors.grey,
            width: selected || isTarget ? 2 : 1,
          ),
          boxShadow: isDragging
              ? [
                  const BoxShadow(
                    color: Colors.black26,
                    blurRadius: 10,
                    offset: Offset(0, 4),
                  ),
                ]
              : null,
          image: DecorationImage(
            image: FileImage(File(path)),
            fit: BoxFit.cover,
            colorFilter: isDragging
                ? const ColorFilter.mode(Colors.black26, BlendMode.darken)
                : null,
          ),
        ),
        child: selected
            ? Align(
                alignment: Alignment.topRight,
                child: Container(
                  margin: const EdgeInsets.all(6),
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: Colors.blue,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, size: 14, color: Colors.white),
                ),
              )
            : null,
      ),
    );
  }

  Future<void> _confirmDeleteSelected() async {
    if (_selectedImages.isEmpty) return;
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('이미지 삭제'),
          content: Text('${_selectedImages.length}개 이미지를 삭제할까요?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('삭제'),
            ),
          ],
        );
      },
    );
    if (shouldDelete != true) return;
    final toDelete = _selectedImages.toList();
    await widget.onDeleteImages(toDelete);
    widget.imagePaths.removeWhere(_selectedImages.contains);
    if (mounted) {
      setState(() {
        _selectedImages.clear();
      });
    }
  }

  Widget _buildTextList() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: widget.readOnly
              ? const SizedBox.shrink()
              : TextField(
                  controller: _textController,
                  decoration: const InputDecoration(
                    hintText: '텍스트 입력',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  minLines: 1,
                  maxLines: 4,
                ),
        ),
        if (!widget.readOnly) const SizedBox(height: 0),
        Expanded(
          child: widget.texts.isEmpty
              ? Center(
                  child: Text(
                    '텍스트가 없습니다',
                    style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                  ),
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: !widget.readOnly,
                  itemCount: widget.texts.length,
                  onReorder: (oldIndex, newIndex) {
                    if (widget.readOnly) return;
                    setState(() {
                      if (newIndex > oldIndex) {
                        newIndex -= 1;
                      }
                      final item = widget.texts.removeAt(oldIndex);
                      widget.texts.insert(newIndex, item);
                    });
                    widget.onReorderTexts(widget.texts);
                  },
                  itemBuilder: (context, index) {
                    final text = widget.texts[index];
                    return ListTile(
                      key: ValueKey('text_${index}_${text.hashCode}'),
                      title: Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: widget.readOnly
                          ? null
                          : const Icon(Icons.drag_handle),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

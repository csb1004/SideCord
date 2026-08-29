import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum DcconListMode {
  latest('latest', '신규 디시콘', ''),
  daily(
    'daily',
    '일간 인기 디시콘',
    'https://json2.dcinside.com/json1/dccon_day_top100.php',
  ),
  weekly(
    'weekly',
    '주간 인기 디시콘',
    'https://json2.dcinside.com/json1/dccon_week_top100.php',
  ),
  monthly(
    'monthly',
    '월간 인기 디시콘',
    'https://json2.dcinside.com/json1/dccon_month_top100.php',
  );

  const DcconListMode(this.storageValue, this.label, this.popularUrl);

  final String storageValue;
  final String label;
  final String popularUrl;

  bool get isPopular => popularUrl.isNotEmpty;

  static DcconListMode fromStorage(String? value) {
    for (final mode in values) {
      if (mode.storageValue == value) return mode;
    }
    return DcconListMode.daily;
  }
}

class DcconPackage {
  const DcconPackage({
    required this.id,
    required this.title,
    required this.seller,
    required this.thumbnailUrl,
  });

  final String id;
  final String title;
  final String seller;
  final String thumbnailUrl;
}

class DcconIcon {
  const DcconIcon({
    required this.title,
    required this.imageUrl,
    required this.extension,
  });

  final String title;
  final String imageUrl;
  final String extension;
}

class DcconPackageDetail {
  const DcconPackageDetail({
    required this.package,
    required this.description,
    required this.icons,
  });

  final DcconPackage package;
  final String description;
  final List<DcconIcon> icons;
}

class DcconImportProgress {
  const DcconImportProgress({
    required this.total,
    required this.completed,
    required this.saved,
    required this.currentTitle,
  });

  final int total;
  final int completed;
  final int saved;
  final String currentTitle;

  double get fraction {
    if (total <= 0) return 0;
    return completed / total;
  }
}

typedef DcconImportProgressCallback =
    void Function(DcconImportProgress progress);

typedef DcconImportCallback =
    Future<int> Function(
      DcconPackage package,
      List<DcconIcon> icons, {
      DcconImportProgressCallback? onProgress,
      List<DcconIcon>? catalogIcons,
      List<DcconIcon>? existingIcons,
    });

class DcconInstallStatus {
  const DcconInstallStatus({
    required this.installed,
    required this.installedIcons,
    required this.missingIcons,
  });

  final bool installed;
  final List<DcconIcon> installedIcons;
  final List<DcconIcon> missingIcons;
}

class DcconInstalledPackage {
  const DcconInstalledPackage({
    required this.package,
    required this.folderName,
  });

  final DcconPackage package;
  final String folderName;
}

class DcconInstallStore {
  DcconInstallStore({http.Client? verificationClient})
    : _verificationClient = verificationClient;

  static const String packagesPrefKey = 'dccon_packages';
  static const String imageFoldersPrefKey = 'image_folders';
  static const int identityVersion = 2;

  final http.Client? _verificationClient;

  Future<Set<String>> findInstalledPackageIds(
    List<DcconPackage> packages,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final records = _decodeRecords(prefs.getString(packagesPrefKey));
    final folders = _decodeFolders(prefs.getString(imageFoldersPrefKey));
    return {
      for (final package in packages)
        if (records.containsKey(package.id) ||
            (folders[folderName(package)]?.isNotEmpty ?? false))
          package.id,
    };
  }

  Future<List<DcconInstalledPackage>> installedPackages() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final records = _decodeRecords(prefs.getString(packagesPrefKey));
    final folders = _decodeFolders(prefs.getString(imageFoldersPrefKey));
    final result = <DcconInstalledPackage>[];
    for (final entry in records.entries) {
      final folder = entry.value['folderName']?.toString() ?? '';
      final title = entry.value['title']?.toString() ?? folder;
      if (entry.key.isEmpty || folder.isEmpty) continue;
      if (!(folders[folder]?.isNotEmpty ?? false)) continue;
      result.add(
        DcconInstalledPackage(
          package: DcconPackage(
            id: entry.key,
            title: title.isEmpty ? folder : title,
            seller: '',
            thumbnailUrl: '',
          ),
          folderName: folder,
        ),
      );
    }
    return result;
  }

  Future<DcconInstallStatus> statusFor(
    DcconPackage package,
    List<DcconIcon> remoteIcons,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final records = _decodeRecords(prefs.getString(packagesPrefKey));
    final folders = _decodeFolders(prefs.getString(imageFoldersPrefKey));
    final record = records[package.id];
    final folder = record?['folderName']?.toString() ?? folderName(package);
    final localPaths = folders[folder] ?? const <String>[];
    final recordedUrls = _stringList(record?['importedUrls']);

    final hasVerifiedIdentity =
        (record?['identityVersion'] as num?)?.toInt() == identityVersion;
    if (!hasVerifiedIdentity && localPaths.isNotEmpty) {
      final reconciled = await _reconcileByContent(
        prefs: prefs,
        records: records,
        folders: folders,
        package: package,
        folder: folder,
        localPaths: localPaths,
        remoteIcons: remoteIcons,
      );
      if (reconciled != null) return reconciled;
    }

    List<DcconIcon> installedIcons;
    final previousCatalogUrls = _stringList(record?['catalogUrls']);
    final knownUrls = hasVerifiedIdentity
        ? recordedUrls
        : previousCatalogUrls.isNotEmpty
        ? previousCatalogUrls
        : recordedUrls;
    if (knownUrls.isNotEmpty) {
      installedIcons = [
        for (final icon in remoteIcons)
          if (knownUrls.contains(icon.imageUrl)) icon,
      ];
    } else {
      final legacyCount = localPaths.length.clamp(0, remoteIcons.length);
      installedIcons = remoteIcons.take(legacyCount).toList();
    }

    final installedUrls = installedIcons.map((icon) => icon.imageUrl).toSet();
    return DcconInstallStatus(
      installed: localPaths.isNotEmpty || recordedUrls.isNotEmpty,
      installedIcons: installedIcons,
      missingIcons: [
        for (final icon in remoteIcons)
          if (!installedUrls.contains(icon.imageUrl)) icon,
      ],
    );
  }

  Future<void> recordImport(
    DcconPackage package,
    List<DcconIcon> importedIcons, {
    List<DcconIcon>? catalogIcons,
    List<DcconIcon>? existingIcons,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final records = _decodeRecords(prefs.getString(packagesPrefKey));
    final previous = records[package.id] ?? <String, dynamic>{};
    final importedUrls = <String>{
      ..._stringList(previous['importedUrls']),
      ...?existingIcons?.map((icon) => icon.imageUrl),
      ...importedIcons.map((icon) => icon.imageUrl),
    };
    records[package.id] = {
      'title': package.title,
      'folderName': folderName(package),
      'importedUrls': importedUrls.toList(),
      'catalogUrls': (catalogIcons ?? const <DcconIcon>[])
          .map((icon) => icon.imageUrl)
          .toList(),
      'identityVersion': identityVersion,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    await prefs.setString(packagesPrefKey, jsonEncode(records));
  }

  Future<void> renameFolder(String oldName, String newName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final records = _decodeRecords(prefs.getString(packagesPrefKey));
    var changed = false;
    for (final record in records.values) {
      if (record['folderName']?.toString() == oldName) {
        record['folderName'] = newName;
        changed = true;
      }
    }
    if (changed) {
      await prefs.setString(packagesPrefKey, jsonEncode(records));
    }
  }

  Future<void> removeFolder(String folderName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final records = _decodeRecords(prefs.getString(packagesPrefKey));
    records.removeWhere(
      (_, record) => record['folderName']?.toString() == folderName,
    );
    await prefs.setString(packagesPrefKey, jsonEncode(records));
  }

  static String folderName(DcconPackage package) {
    final title = package.title.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (title.isEmpty || title == '최근 사용' || title == '기본') {
      return '디시콘 ${package.id}';
    }
    return title;
  }

  Map<String, Map<String, dynamic>> _decodeRecords(String? value) {
    if (value == null || value.isEmpty) return {};
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is Map)
            entry.key.toString(): Map<String, dynamic>.from(entry.value as Map),
      };
    } catch (_) {
      return {};
    }
  }

  Map<String, List<String>> _decodeFolders(String? value) {
    if (value == null || value.isEmpty) return {};
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is List)
            entry.key.toString(): _stringList(entry.value),
      };
    } catch (_) {
      return {};
    }
  }

  List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return value.map((item) => item.toString()).toList();
  }

  Future<DcconInstallStatus?> _reconcileByContent({
    required SharedPreferences prefs,
    required Map<String, Map<String, dynamic>> records,
    required Map<String, List<String>> folders,
    required DcconPackage package,
    required String folder,
    required List<String> localPaths,
    required List<DcconIcon> remoteIcons,
  }) async {
    final existingFiles = [
      for (final path in localPaths)
        if (File(path).existsSync()) File(path),
    ];
    if (existingFiles.isEmpty || remoteIcons.isEmpty) return null;

    try {
      final localDigests = await Future.wait(
        existingFiles.map((file) async {
          final digest = sha256.convert(await file.readAsBytes()).toString();
          return (path: file.path, digest: digest);
        }),
      );

      final client = _verificationClient ?? http.Client();
      final ownsClient = _verificationClient == null;
      final remoteDigests = <String, String>{};
      try {
        const batchSize = 8;
        for (var start = 0; start < remoteIcons.length; start += batchSize) {
          final batch = remoteIcons.skip(start).take(batchSize);
          final results = await Future.wait(
            batch.map((icon) async {
              final response = await client.get(
                Uri.parse(icon.imageUrl),
                headers: DcconClient.imageHeaders,
              );
              if (response.statusCode < 200 ||
                  response.statusCode >= 300 ||
                  response.bodyBytes.isEmpty) {
                throw HttpException('Cannot verify ${icon.imageUrl}');
              }
              return (
                url: icon.imageUrl,
                digest: sha256.convert(response.bodyBytes).toString(),
              );
            }),
          );
          for (final result in results) {
            remoteDigests[result.url] = result.digest;
          }
        }
      } finally {
        if (ownsClient) client.close();
      }

      final availableCounts = <String, int>{};
      for (final item in localDigests) {
        availableCounts.update(
          item.digest,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
      final usedCounts = <String, int>{};
      final installedIcons = <DcconIcon>[];
      for (final icon in remoteIcons) {
        final digest = remoteDigests[icon.imageUrl]!;
        final used = usedCounts[digest] ?? 0;
        if (used < (availableCounts[digest] ?? 0)) {
          installedIcons.add(icon);
          usedCounts[digest] = used + 1;
        }
      }

      final remoteCounts = <String, int>{};
      for (final digest in remoteDigests.values) {
        remoteCounts.update(digest, (count) => count + 1, ifAbsent: () => 1);
      }
      final retainedCounts = <String, int>{};
      final retainedPaths = <String>[];
      for (final item in localDigests) {
        final remoteCount = remoteCounts[item.digest] ?? 0;
        final retained = retainedCounts[item.digest] ?? 0;
        if (remoteCount == 0 || retained < remoteCount) {
          retainedPaths.add(item.path);
          retainedCounts[item.digest] = retained + 1;
        }
      }
      final installedUrls = installedIcons.map((icon) => icon.imageUrl).toSet();
      folders[folder] = retainedPaths;
      records[package.id] = {
        'title': package.title,
        'folderName': folder,
        'importedUrls': installedUrls.toList(),
        'catalogUrls': remoteIcons.map((icon) => icon.imageUrl).toList(),
        'identityVersion': identityVersion,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };
      await prefs.setString(imageFoldersPrefKey, jsonEncode(folders));
      await prefs.setString(packagesPrefKey, jsonEncode(records));
      return DcconInstallStatus(
        installed: installedIcons.isNotEmpty,
        installedIcons: installedIcons,
        missingIcons: [
          for (final icon in remoteIcons)
            if (!installedUrls.contains(icon.imageUrl)) icon,
        ],
      );
    } catch (_) {
      return null;
    }
  }
}

class DcconClient {
  DcconClient({http.Client? client}) : _client = client ?? http.Client();

  static final Uri _origin = Uri.parse('https://dccon.dcinside.com');
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';
  static const Map<String, String> imageHeaders = {
    'User-Agent': userAgent,
    'Referer': 'https://dccon.dcinside.com/',
    'Accept':
        'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
  };

  final http.Client _client;
  final Map<String, String> _cookies = {};

  Future<List<DcconPackage>> loadPackages(DcconListMode mode) async {
    if (mode.isPopular) {
      return loadPopular(mode);
    }
    return loadLatest();
  }

  Future<List<DcconPackage>> loadLatest() async {
    final response = await _get('/new/1');
    return _parsePackages(_decodeBody(response));
  }

  Future<List<DcconPackage>> loadPopular(DcconListMode mode) async {
    if (!mode.isPopular) return loadLatest();
    final response = await _client.get(
      Uri.parse(mode.popularUrl),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('인기 디시콘 목록을 불러오지 못했습니다.');
    }
    return _parsePopularPackages(_decodeBody(response));
  }

  Future<List<DcconPackage>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return loadPackages(DcconListMode.daily);
    }

    final encoded = Uri.encodeComponent(trimmed);
    final response = await _get('/hot/1/title/$encoded');
    return _parsePackages(_decodeBody(response));
  }

  Future<DcconPackageDetail> loadDetail(DcconPackage package) async {
    await _ensureSession();
    final response = await _client.post(
      _origin.resolve('/index/package_detail'),
      headers: _headers(ajax: true),
      body: {
        'ci_t': _cookies['ci_c'] ?? '',
        'package_idx': package.id,
        'code': '',
        'inspection_state': '',
      },
    );
    _storeCookies(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('디시콘 상세 정보를 불러오지 못했습니다.');
    }

    final decoded = jsonDecode(_decodeBody(response));
    if (decoded is! Map<String, dynamic>) {
      throw Exception('디시콘 응답 형식이 올바르지 않습니다.');
    }

    final info = decoded['info'];
    final detail = decoded['detail'];
    final infoMap = info is Map<String, dynamic> ? info : <String, dynamic>{};
    final mainImagePath = infoMap['main_img_path']?.toString() ?? '';
    final title = _cleanText(infoMap['title']?.toString() ?? package.title);
    final seller = _cleanText(
      infoMap['seller_name']?.toString() ?? package.seller,
    );
    final description = _cleanText(infoMap['description']?.toString() ?? '');

    final icons = <DcconIcon>[];
    if (detail is List) {
      for (final item in detail) {
        if (item is! Map<String, dynamic>) continue;
        final path = item['path']?.toString() ?? '';
        if (path.isEmpty) continue;
        final extension = item['ext']?.toString().toLowerCase() ?? '';
        final iconTitle = _cleanText(item['title']?.toString() ?? '');
        icons.add(
          DcconIcon(
            title: iconTitle,
            imageUrl: _dcconImageUrl(path),
            extension: extension,
          ),
        );
      }
    }

    final resolvedPackage = DcconPackage(
      id: package.id,
      title: title.isEmpty ? package.title : title,
      seller: seller,
      thumbnailUrl: mainImagePath.isEmpty
          ? package.thumbnailUrl
          : _dcconImageUrl(mainImagePath),
    );

    return DcconPackageDetail(
      package: resolvedPackage,
      description: description,
      icons: icons,
    );
  }

  void close() {
    _client.close();
  }

  Future<void> _ensureSession() async {
    if (_cookies.containsKey('ci_c')) return;
    final response = await _get('/new/1');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('디시콘 세션을 열 수 없습니다.');
    }
  }

  Future<http.Response> _get(String path) async {
    final response = await _client.get(
      _origin.resolve(path),
      headers: _headers(),
    );
    _storeCookies(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('디시콘 목록을 불러오지 못했습니다.');
    }
    return response;
  }

  List<DcconPackage> _parsePackages(String body) {
    final document = html_parser.parse(body);
    final packages = <DcconPackage>[];
    final seenIds = <String>{};

    for (final item in document.querySelectorAll('li.div_package')) {
      final id = item.attributes['package_idx']?.trim() ?? '';
      if (id.isEmpty || !seenIds.add(id)) continue;

      final title = _cleanText(item.querySelector('.dcon_name')?.text ?? '');
      final seller = _cleanText(item.querySelector('.dcon_seller')?.text ?? '');
      final thumbnail = _absoluteUrl(
        item.querySelector('img.thumb_img')?.attributes['src'] ?? '',
      );

      if (title.isEmpty && thumbnail.isEmpty) continue;
      packages.add(
        DcconPackage(
          id: id,
          title: title.isEmpty ? '디시콘 $id' : title,
          seller: seller,
          thumbnailUrl: thumbnail,
        ),
      );
    }

    return packages;
  }

  List<DcconPackage> _parsePopularPackages(String body) {
    final decoded = jsonDecode(_stripJsonp(body));
    if (decoded is! List) return const [];

    final packages = <DcconPackage>[];
    final seenIds = <String>{};
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final id = item['package_idx']?.toString().trim() ?? '';
      if (id.isEmpty || !seenIds.add(id)) continue;

      final title = _cleanText(item['title']?.toString() ?? '');
      final seller = _cleanText(
        item['nick_name']?.toString() ?? item['seller_name']?.toString() ?? '',
      );
      final thumbnail = _absoluteUrl(item['img']?.toString() ?? '');
      if (title.isEmpty && thumbnail.isEmpty) continue;

      packages.add(
        DcconPackage(
          id: id,
          title: title.isEmpty ? '디시콘 $id' : title,
          seller: seller,
          thumbnailUrl: thumbnail,
        ),
      );
    }

    return packages;
  }

  String _stripJsonp(String body) {
    final trimmed = body.trim();
    final start = trimmed.indexOf('(');
    final end = trimmed.lastIndexOf(')');
    if (start >= 0 && end > start) {
      return trimmed.substring(start + 1, end);
    }
    return trimmed;
  }

  Map<String, String> _headers({bool ajax = false}) {
    final headers = <String, String>{
      'User-Agent': userAgent,
      'Accept': ajax
          ? 'application/json, text/javascript, */*; q=0.01'
          : 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Referer': 'https://dccon.dcinside.com/new/1',
      'Origin': 'https://dccon.dcinside.com',
    };
    final cookieHeader = _cookieHeader();
    if (cookieHeader.isNotEmpty) {
      headers['Cookie'] = cookieHeader;
    }
    if (ajax) {
      headers['X-Requested-With'] = 'XMLHttpRequest';
      headers['Content-Type'] =
          'application/x-www-form-urlencoded; charset=UTF-8';
    }
    return headers;
  }

  String _cookieHeader() {
    return _cookies.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }

  void _storeCookies(http.Response response) {
    final raw = response.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;

    final cookieParts = raw.split(RegExp(r',\s*(?=[^;, ]+=)'));
    for (final part in cookieParts) {
      final firstPair = part.split(';').first.trim();
      final separator = firstPair.indexOf('=');
      if (separator <= 0) continue;

      final name = firstPair.substring(0, separator).trim();
      final value = firstPair.substring(separator + 1).trim();
      if (name.isEmpty ||
          value.isEmpty ||
          name.toLowerCase() == 'expires' ||
          name.toLowerCase() == 'max-age') {
        continue;
      }
      _cookies[name] = value;
    }
  }

  String _decodeBody(http.Response response) {
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  static String _cleanText(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _absoluteUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    if (trimmed.startsWith('//')) {
      return 'https:$trimmed';
    }
    return _origin.resolve(trimmed).toString();
  }

  static String _dcconImageUrl(String path) {
    return 'https://dcimg5.dcinside.com/dccon.php?no=$path';
  }
}

class DcconBrowserPage extends StatefulWidget {
  const DcconBrowserPage({super.key, required this.onImport});

  final DcconImportCallback onImport;

  @override
  State<DcconBrowserPage> createState() => _DcconBrowserPageState();
}

class _DcconBrowserPageState extends State<DcconBrowserPage> {
  static const String _modePrefKey = 'dccon_list_mode';

  final DcconClient _client = DcconClient();
  final DcconInstallStore _installStore = DcconInstallStore();
  final TextEditingController _searchController = TextEditingController();
  late Future<List<DcconPackage>> _packagesFuture;
  final Map<String, int> _updateCounts = {};
  final Set<String> _updatingPackageIds = {};
  String _activeQuery = '';
  DcconListMode _selectedMode = DcconListMode.daily;

  @override
  void initState() {
    super.initState();
    _packagesFuture = _loadInitialPackages();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _client.close();
    super.dispose();
  }

  void _runSearch([String? value]) {
    final query = (value ?? _searchController.text).trim();
    FocusScope.of(context).unfocus();
    setState(() {
      _activeQuery = query;
      _packagesFuture = query.isEmpty
          ? _loadPackages(_selectedMode)
          : _searchPackages(query);
    });
  }

  Future<List<DcconPackage>> _loadInitialPackages() async {
    final prefs = await SharedPreferences.getInstance();
    _selectedMode = DcconListMode.fromStorage(prefs.getString(_modePrefKey));
    return _loadPackages(_selectedMode);
  }

  Future<List<DcconPackage>> _loadPackages(DcconListMode mode) async {
    final packages = await _client.loadPackages(mode);
    unawaited(_refreshUpdateCounts(packages));
    return packages;
  }

  Future<List<DcconPackage>> _searchPackages(String query) async {
    final packages = await _client.search(query);
    unawaited(_refreshUpdateCounts(packages));
    return packages;
  }

  Future<void> _refreshUpdateCounts(List<DcconPackage> packages) async {
    final installedIds = await _installStore.findInstalledPackageIds(packages);
    final counts = <String, int>{};
    for (final package in packages) {
      if (!installedIds.contains(package.id)) continue;
      try {
        final detail = await _client.loadDetail(package);
        final status = await _installStore.statusFor(
          detail.package,
          detail.icons,
        );
        if (status.missingIcons.isNotEmpty) {
          counts[package.id] = status.missingIcons.length;
        }
      } catch (_) {
        // A failed update check should not hide the package list.
      }
    }
    if (!mounted) return;
    setState(() {
      _updateCounts
        ..clear()
        ..addAll(counts);
    });
  }

  Future<void> _updatePackage(DcconPackage package) async {
    if (_updatingPackageIds.contains(package.id)) return;
    setState(() => _updatingPackageIds.add(package.id));
    try {
      final detail = await _client.loadDetail(package);
      final status = await _installStore.statusFor(
        detail.package,
        detail.icons,
      );
      if (status.missingIcons.isEmpty) {
        if (mounted) {
          setState(() => _updateCounts.remove(package.id));
        }
        return;
      }
      final queued = await widget.onImport(
        detail.package,
        status.missingIcons,
        catalogIcons: detail.icons,
        existingIcons: status.installedIcons,
      );
      if (!mounted) return;
      setState(() => _updateCounts.remove(package.id));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$queued개 추가 디시콘 다운로드를 시작했습니다.')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('디시콘 업데이트를 시작하지 못했습니다.')));
    } finally {
      if (mounted) {
        setState(() => _updatingPackageIds.remove(package.id));
      }
    }
  }

  Future<void> _selectMode(DcconListMode mode) async {
    if (_selectedMode == mode && _activeQuery.isEmpty) return;
    _searchController.clear();
    FocusScope.of(context).unfocus();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modePrefKey, mode.storageValue);
    if (!mounted) return;
    setState(() {
      _selectedMode = mode;
      _activeQuery = '';
      _packagesFuture = _loadPackages(mode);
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _runSearch('');
  }

  void _openPackage(DcconPackage package) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DcconPackageDetailPage(
          client: _client,
          package: package,
          onImport: widget.onImport,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _activeQuery.isEmpty
        ? _selectedMode.label
        : '"$_activeQuery" 검색 결과';
    return Scaffold(
      appBar: AppBar(
        title: const Text('디시콘'),
        actions: [
          IconButton(
            onPressed: () => _runSearch(_activeQuery),
            icon: const Icon(Icons.refresh),
            tooltip: '새로고침',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onSubmitted: _runSearch,
              decoration: InputDecoration(
                hintText: '디시콘 이름 검색',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: _clearSearch,
                        icon: const Icon(Icons.close),
                        tooltip: '검색어 지우기',
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_activeQuery.isEmpty)
                  PopupMenuButton<DcconListMode>(
                    tooltip: '목록 변경',
                    icon: const Icon(Icons.format_list_bulleted),
                    initialValue: _selectedMode,
                    onSelected: _selectMode,
                    itemBuilder: (context) => [
                      for (final mode in DcconListMode.values)
                        PopupMenuItem(value: mode, child: Text(mode.label)),
                    ],
                  ),
                const SizedBox(width: 4),
                FilledButton.tonalIcon(
                  onPressed: _runSearch,
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('검색'),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<DcconPackage>>(
              future: _packagesFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return _DcconMessage(
                    icon: Icons.cloud_off_outlined,
                    title: '디시콘을 불러오지 못했습니다',
                    message: '네트워크 상태를 확인한 뒤 다시 시도해 주세요.',
                    action: FilledButton.icon(
                      onPressed: () => _runSearch(_activeQuery),
                      icon: const Icon(Icons.refresh),
                      label: const Text('다시 시도'),
                    ),
                  );
                }

                final packages = snapshot.data ?? const <DcconPackage>[];
                if (packages.isEmpty) {
                  return const _DcconMessage(
                    icon: Icons.search_off,
                    title: '검색 결과가 없습니다',
                    message: '다른 이름으로 검색해 보세요.',
                  );
                }

                return LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 840
                        ? 5
                        : constraints.maxWidth >= 640
                        ? 4
                        : constraints.maxWidth >= 420
                        ? 3
                        : 2;
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 0.68,
                      ),
                      itemCount: packages.length,
                      itemBuilder: (context, index) {
                        final package = packages[index];
                        return _DcconPackageTile(
                          package: package,
                          onTap: () => _openPackage(package),
                          updateCount: _updateCounts[package.id] ?? 0,
                          updating: _updatingPackageIds.contains(package.id),
                          onUpdate: () => _updatePackage(package),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class DcconPackageDetailPage extends StatefulWidget {
  const DcconPackageDetailPage({
    super.key,
    required this.client,
    required this.package,
    required this.onImport,
  });

  final DcconClient client;
  final DcconPackage package;
  final DcconImportCallback onImport;

  @override
  State<DcconPackageDetailPage> createState() => _DcconPackageDetailPageState();
}

class _DcconPackageDetailPageState extends State<DcconPackageDetailPage> {
  late Future<DcconPackageDetail> _detailFuture;
  final DcconInstallStore _installStore = DcconInstallStore();
  final Set<int> _selectedIndexes = {};
  bool _isImporting = false;
  DcconImportProgress? _progress;

  @override
  void initState() {
    super.initState();
    _detailFuture = widget.client.loadDetail(widget.package);
  }

  Future<void> _importIcons(
    DcconPackageDetail detail,
    List<DcconIcon> icons,
  ) async {
    if (_isImporting || icons.isEmpty) return;

    setState(() {
      _isImporting = true;
      _progress = DcconImportProgress(
        total: icons.length,
        completed: 0,
        saved: 0,
        currentTitle: '준비 중',
      );
    });

    try {
      final isFullPackage = icons.length == detail.icons.length;
      final installStatus = await _installStore.statusFor(
        detail.package,
        detail.icons,
      );
      final installedUrls = installStatus.installedIcons
          .map((icon) => icon.imageUrl)
          .toSet();
      final iconsToImport = isFullPackage
          ? installStatus.missingIcons
          : [
              for (final icon in icons)
                if (!installedUrls.contains(icon.imageUrl)) icon,
            ];
      if (iconsToImport.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('이미 최신 상태입니다.')));
        }
        return;
      }
      final count = await widget.onImport(
        detail.package,
        iconsToImport,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _progress = progress;
          });
        },
        catalogIcons: isFullPackage ? detail.icons : null,
        existingIcons: installStatus.installedIcons,
      );
      if (!mounted) return;
      if (count == 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('저장된 디시콘이 없습니다.')));
        return;
      }

      setState(() {
        _selectedIndexes.clear();
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$count개 디시콘 다운로드를 시작했습니다.')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('디시콘을 저장하지 못했습니다.')));
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
          _progress = null;
        });
      }
    }
  }

  List<DcconIcon> _selectedIcons(DcconPackageDetail detail) {
    final sorted = _selectedIndexes.toList()..sort();
    return [
      for (final index in sorted)
        if (index >= 0 && index < detail.icons.length) detail.icons[index],
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectedIndexes.isEmpty
              ? widget.package.title
              : '${_selectedIndexes.length}개 선택',
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: FutureBuilder<DcconPackageDetail>(
        future: _detailFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _DcconMessage(
              icon: Icons.cloud_off_outlined,
              title: '상세 정보를 불러오지 못했습니다',
              message: '잠시 뒤 다시 시도해 주세요.',
              action: FilledButton.icon(
                onPressed: () {
                  setState(() {
                    _detailFuture = widget.client.loadDetail(widget.package);
                  });
                },
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도'),
              ),
            );
          }

          final detail = snapshot.data;
          if (detail == null || detail.icons.isEmpty) {
            return const _DcconMessage(
              icon: Icons.image_not_supported_outlined,
              title: '가져올 콘이 없습니다',
              message: '다른 디시콘을 선택해 주세요.',
            );
          }

          return Column(
            children: [
              _DcconDetailHeader(detail: detail),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 720
                        ? 5
                        : constraints.maxWidth >= 520
                        ? 4
                        : 3;
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                      ),
                      itemCount: detail.icons.length,
                      itemBuilder: (context, index) {
                        final icon = detail.icons[index];
                        final selected = _selectedIndexes.contains(index);
                        return _DcconIconTile(
                          icon: icon,
                          selected: selected,
                          importing: _isImporting,
                          onTap: () {
                            setState(() {
                              if (selected) {
                                _selectedIndexes.remove(index);
                              } else {
                                _selectedIndexes.add(index);
                              }
                            });
                          },
                          onImport: () => _importIcons(detail, [icon]),
                        );
                      },
                    );
                  },
                ),
              ),
              if (_progress != null)
                _DcconImportProgressPanel(progress: _progress!),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _selectedIndexes.isEmpty || _isImporting
                              ? null
                              : () => _importIcons(
                                  detail,
                                  _selectedIcons(detail),
                                ),
                          icon: const Icon(Icons.download_done),
                          label: Text('선택 가져오기 (${_selectedIndexes.length})'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _isImporting
                              ? null
                              : () => _importIcons(detail, detail.icons),
                          icon: _isImporting
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.download),
                          label: Text('전체 가져오기 (${detail.icons.length})'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DcconImportProgressPanel extends StatelessWidget {
  const _DcconImportProgressPanel({required this.progress});

  final DcconImportProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = progress.fraction.clamp(0.0, 1.0);
    final label = progress.currentTitle.isEmpty
        ? '다운로드 중'
        : progress.currentTitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: fraction),
          const SizedBox(height: 6),
          Text(
            '다운로드 ${progress.completed}/${progress.total} · 저장 ${progress.saved}개 · $label',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _DcconPackageTile extends StatelessWidget {
  const _DcconPackageTile({
    required this.package,
    required this.onTap,
    required this.updateCount,
    required this.updating,
    required this.onUpdate,
  });

  final DcconPackage package;
  final VoidCallback onTap;
  final int updateCount;
  final bool updating;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: _DcconNetworkImage(url: package.thumbnailUrl),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                package.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.18,
                ),
              ),
              if (package.seller.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  package.seller,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (updateCount > 0) ...[
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  height: 34,
                  child: FilledButton.tonalIcon(
                    onPressed: updating ? null : onUpdate,
                    icon: updating
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.system_update_alt, size: 17),
                    label: Text('업데이트 +$updateCount'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      textStyle: theme.textTheme.labelSmall,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DcconDetailHeader extends StatelessWidget {
  const _DcconDetailHeader({required this.detail});

  final DcconPackageDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox.square(
              dimension: 72,
              child: _DcconNetworkImage(url: detail.package.thumbnailUrl),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  detail.package.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (detail.package.seller.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail.package.seller,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (detail.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    detail.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '${detail.icons.length}개 콘',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DcconIconTile extends StatelessWidget {
  const _DcconIconTile({
    required this.icon,
    required this.selected,
    required this.importing,
    required this.onTap,
    required this.onImport,
  });

  final DcconIcon icon;
  final bool selected;
  final bool importing;
  final VoidCallback onTap;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.36),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: _DcconNetworkImage(url: icon.imageUrl),
            ),
            if (selected)
              Align(
                alignment: Alignment.topRight,
                child: Container(
                  margin: const EdgeInsets.all(6),
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.check,
                    color: theme.colorScheme.onPrimary,
                    size: 16,
                  ),
                ),
              ),
            Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: IconButton.filledTonal(
                  onPressed: importing ? null : onImport,
                  icon: const Icon(Icons.download, size: 18),
                  tooltip: '이 콘 가져오기',
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DcconNetworkImage extends StatelessWidget {
  const _DcconNetworkImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return const ColoredBox(
        color: Color(0xFFE5E7EB),
        child: Center(child: Icon(Icons.image_not_supported_outlined)),
      );
    }

    return Image.network(
      url,
      fit: BoxFit.contain,
      headers: DcconClient.imageHeaders,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return const Center(
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return const ColoredBox(
          color: Color(0xFFE5E7EB),
          child: Center(child: Icon(Icons.broken_image_outlined)),
        );
      },
    );
  }
}

class _DcconMessage extends StatelessWidget {
  const _DcconMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

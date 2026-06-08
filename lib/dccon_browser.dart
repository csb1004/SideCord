import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

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
    });

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

  Future<List<DcconPackage>> loadLatest() async {
    final response = await _get('/new/1');
    return _parsePackages(_decodeBody(response));
  }

  Future<List<DcconPackage>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return loadLatest();
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
  final DcconClient _client = DcconClient();
  final TextEditingController _searchController = TextEditingController();
  late Future<List<DcconPackage>> _packagesFuture;
  String _activeQuery = '';

  @override
  void initState() {
    super.initState();
    _packagesFuture = _client.loadLatest();
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
          ? _client.loadLatest()
          : _client.search(query);
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
                    _activeQuery.isEmpty ? '신규 디시콘' : '"$_activeQuery" 검색 결과',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
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
                        childAspectRatio: 0.74,
                      ),
                      itemCount: packages.length,
                      itemBuilder: (context, index) {
                        final package = packages[index];
                        return _DcconPackageTile(
                          package: package,
                          onTap: () => _openPackage(package),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${icons.length}개 디시콘 다운로드를 시작했습니다.')),
      );
      final count = await widget.onImport(
        detail.package,
        icons,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _progress = progress;
          });
        },
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
      ).showSnackBar(SnackBar(content: Text('$count개 디시콘을 가져왔습니다.')));
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
  const _DcconPackageTile({required this.package, required this.onTap});

  final DcconPackage package;
  final VoidCallback onTap;

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

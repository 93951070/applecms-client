import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单条离线缓存任务/记录。
class OfflineDownload {
  final String id;
  final String title;
  final String cover;
  final String sourceUrl;
  final String filePath;
  final String status; // downloading | done | failed
  final double progress;
  final int createdAt;

  const OfflineDownload({
    required this.id,
    required this.title,
    required this.cover,
    required this.sourceUrl,
    required this.filePath,
    required this.status,
    required this.progress,
    required this.createdAt,
  });

  bool get isDone => status == 'done';

  OfflineDownload copyWith({
    String? status,
    double? progress,
    String? filePath,
  }) {
    return OfflineDownload(
      id: id,
      title: title,
      cover: cover,
      sourceUrl: sourceUrl,
      filePath: filePath ?? this.filePath,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'cover': cover,
        'source_url': sourceUrl,
        'file_path': filePath,
        'status': status,
        'progress': progress,
        'created_at': createdAt,
      };

  factory OfflineDownload.fromJson(Map<String, dynamic> json) {
    return OfflineDownload(
      id: (json['id'] ?? '').toString(),
      title: json['title'] ?? '',
      cover: json['cover'] ?? '',
      sourceUrl: json['source_url'] ?? '',
      filePath: json['file_path'] ?? '',
      status: json['status'] ?? 'done',
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }
}

final downloadsProvider =
    NotifierProvider<DownloadsNotifier, List<OfflineDownload>>(
        DownloadsNotifier.new);

class DownloadsNotifier extends Notifier<List<OfflineDownload>> {
  static const _key = 'offline_downloads';

  @override
  List<OfflineDownload> build() {
    _load();
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    final loaded = <OfflineDownload>[];
    for (final s in raw) {
      try {
        loaded.add(OfflineDownload.fromJson(
            Map<String, dynamic>.from(jsonDecode(s) as Map)));
      } catch (_) {
        // 忽略损坏的记录
      }
    }
    // 合并而非覆盖：加载是异步的，期间用户可能已发起新的下载任务，
    // 若直接覆盖会把新任务从列表里抹掉（表现为「过一会就消失」）。
    final merged = <String, OfflineDownload>{
      for (final d in loaded) d.id: d,
      for (final d in state) d.id: d,
    };
    state = merged.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _key, state.map((e) => jsonEncode(e.toJson())).toList());
  }

  /// 开始缓存。[url] 为解析后的播放地址，返回 null 表示已加入缓存。
  Future<String?> start({
    required String title,
    required String cover,
    required String url,
  }) async {
    if (url.trim().isEmpty) return '无法获取下载地址';
    final isHls = _isHls(url);
    if (state.any((d) => d.sourceUrl == url && d.status != 'failed')) {
      return '该视频已在缓存列表中';
    }

    final dir = await getApplicationDocumentsDirectory();
    final offlineDir = Directory('${dir.path}/offline');
    if (!await offlineDir.exists()) {
      await offlineDir.create(recursive: true);
    }
    final id = DateTime.now().millisecondsSinceEpoch.toString();

    late final String filePath;
    if (isHls) {
      final target = Directory('${offlineDir.path}/$id');
      await target.create(recursive: true);
      filePath = '${target.path}/index.m3u8';
    } else {
      final clean = url.split('?').first;
      final ext = clean.contains('.') ? clean.split('.').last : 'mp4';
      filePath = '${offlineDir.path}/$id.$ext';
    }

    final item = OfflineDownload(
      id: id,
      title: title,
      cover: cover,
      sourceUrl: url,
      filePath: filePath,
      status: 'downloading',
      progress: 0,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    state = [item, ...state];
    await _persist();
    if (isHls) {
      _runHls(item);
    } else {
      _runDirect(item);
    }
    return null;
  }

  bool _isHls(String url) {
    final path = url.split('?').first.toLowerCase();
    return path.contains('.m3u8');
  }

  void _setProgress(String id, {double? progress, String? status}) {
    state = state
        .map((d) => d.id == id
            ? d.copyWith(progress: progress, status: status)
            : d)
        .toList();
  }

  Future<void> _runDirect(OfflineDownload item) async {
    try {
      await Dio().download(
        item.sourceUrl,
        item.filePath,
        onReceiveProgress: (received, total) {
          if (total <= 0) return;
          _setProgress(item.id, progress: received / total);
        },
      );
      _setProgress(item.id, status: 'done', progress: 1);
    } catch (_) {
      _setProgress(item.id, status: 'failed');
    }
    await _persist();
  }

  /// 下载 HLS（m3u8）：拉取播放列表与全部分片到本地，并生成本地播放列表。
  ///
  /// 同时处理 `#EXT-X-KEY`（AES-128 密钥）与 `#EXT-X-MAP`（初始化分片），
  /// 将其 URI 改写为本地相对路径，保证 ExoPlayer / AVPlayer 可离线播放。
  Future<void> _runHls(OfflineDownload item) async {
    final dir = File(item.filePath).parent;
    final dio = Dio();
    try {
      var playlistUrl = item.sourceUrl;
      var text = await _fetchPlaylist(dio, playlistUrl);

      // 主播放列表：选码率最高的一路，再拉取其媒体播放列表。
      if (text.contains('#EXT-X-STREAM-INF')) {
        final variant = _pickBestVariant(text, playlistUrl);
        if (variant == null) throw Exception('无法解析清晰度列表');
        playlistUrl = variant;
        text = await _fetchPlaylist(dio, playlistUrl);
      }

      final base = _baseUri(playlistUrl);
      final lines = const LineSplitter().convert(text);
      final segmentUrls = <String>[];
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        segmentUrls.add(_resolve(base, line));
      }
      final total = segmentUrls.length;
      if (total == 0) throw Exception('播放列表为空');

      final out = <String>[];
      final keyMap = <String, String>{};
      final mapAssets = <String, String>{};
      var segIndex = 0;

      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty) {
          out.add(raw);
          continue;
        }
        if (line.startsWith('#EXT-X-KEY')) {
          out.add(await _rewriteUriTag(
              dio, dir, line, base, 'key', keyMap));
          continue;
        }
        if (line.startsWith('#EXT-X-MAP')) {
          out.add(await _rewriteUriTag(
              dio, dir, line, base, 'init', mapAssets));
          continue;
        }
        if (line.startsWith('#')) {
          out.add(raw);
          continue;
        }
        final url = _resolve(base, line);
        final clean = url.split('?').first;
        final ext = clean.contains('.') ? clean.split('.').last : 'ts';
        final name = 'seg_${segIndex.toString().padLeft(5, '0')}.$ext';
        await dio.download(url, '${dir.path}/$name');
        out.add(name);
        segIndex++;
        _setProgress(item.id, progress: segIndex / total);
      }

      await File(item.filePath).writeAsString(out.join('\n'));
      _setProgress(item.id, status: 'done', progress: 1);
    } catch (_) {
      _setProgress(item.id, status: 'failed');
    }
    await _persist();
  }

  Future<String> _fetchPlaylist(Dio dio, String url) async {
    final resp = await dio.get<String>(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    final body = resp.data ?? '';
    if (!body.contains('#EXTM3U')) {
      throw Exception('无效的 m3u8 播放列表');
    }
    return body;
  }

  /// 选取带宽最高（其次分辨率最大）的一路。
  String? _pickBestVariant(String text, String playlistUrl) {
    final base = _baseUri(playlistUrl);
    final lines = const LineSplitter().convert(text);
    var bestScore = -1;
    String? best;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      final bandwidth =
          int.tryParse(RegExp(r'BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ??
              '') ??
              0;
      final resolution = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(line);
      final pixels = resolution == null
          ? 0
          : (int.tryParse(resolution.group(1)!) ?? 0) *
              (int.tryParse(resolution.group(2)!) ?? 0);
      final next = i + 1 < lines.length ? lines[i + 1].trim() : '';
      if (next.isEmpty || next.startsWith('#')) continue;
      final score = bandwidth * 1000000 + pixels;
      if (score > bestScore) {
        bestScore = score;
        best = _resolve(base, next);
      }
    }
    return best;
  }

  /// 将标签中的 `URI="..."` 下载到本地并改写为相对文件名。
  Future<String> _rewriteUriTag(
    Dio dio,
    Directory dir,
    String line,
    String base,
    String prefix,
    Map<String, String> cache,
  ) async {
    final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
    if (match == null) return line;
    final remote = _resolve(base, match.group(1)!);
    var local = cache[remote];
    if (local == null) {
      final ext = remote.split('?').first.contains('.')
          ? remote.split('?').first.split('.').last
          : (prefix == 'key' ? 'key' : 'mp4');
      local = '${prefix}_${cache.length}.$ext';
      await dio.download(remote, '${dir.path}/$local');
      cache[remote] = local;
    }
    return line.replaceRange(match.start, match.end, 'URI="$local"');
  }

  String _baseUri(String url) {
    final uri = Uri.parse(url);
    final path = uri.path;
    final slash = path.lastIndexOf('/');
    final dirPath = slash >= 0 ? path.substring(0, slash + 1) : '/';
    return uri.replace(path: dirPath, query: '', fragment: '').toString();
  }

  String _resolve(String base, String relative) {
    if (relative.startsWith('http://') || relative.startsWith('https://')) {
      return relative;
    }
    return Uri.parse(base).resolve(relative).toString();
  }

  Future<void> remove(String id) async {
    final targets = state.where((d) => d.id == id).toList();
    state = state.where((d) => d.id != id).toList();
    await _persist();
    for (final d in targets) {
      try {
        final file = File(d.filePath);
        if (await file.exists()) await file.delete();
        // HLS 缓存：整集内容都在 index.m3u8 所在目录内。
        if (d.filePath.endsWith('index.m3u8')) {
          final parent = file.parent;
          if (await parent.exists()) await parent.delete(recursive: true);
        }
      } catch (_) {
        // 删除失败时忽略，仅移除记录
      }
    }
  }
}

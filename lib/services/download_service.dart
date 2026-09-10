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
    final list = <OfflineDownload>[];
    for (final s in raw) {
      try {
        list.add(OfflineDownload.fromJson(
            Map<String, dynamic>.from(jsonDecode(s) as Map)));
      } catch (_) {
        // 忽略损坏的记录
      }
    }
    state = list;
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
    if (url.toLowerCase().contains('.m3u8')) {
      return '暂不支持 m3u8 流媒体的离线缓存';
    }
    if (state.any((d) => d.sourceUrl == url && d.status != 'failed')) {
      return '该视频已在缓存列表中';
    }

    final dir = await getApplicationDocumentsDirectory();
    final offlineDir = Directory('${dir.path}/offline');
    if (!await offlineDir.exists()) {
      await offlineDir.create(recursive: true);
    }
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final clean = url.split('?').first;
    final ext = clean.contains('.') ? clean.split('.').last : 'mp4';
    final item = OfflineDownload(
      id: id,
      title: title,
      cover: cover,
      sourceUrl: url,
      filePath: '${offlineDir.path}/$id.$ext',
      status: 'downloading',
      progress: 0,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    state = [item, ...state];
    await _persist();
    _run(item);
    return null;
  }

  Future<void> _run(OfflineDownload item) async {
    try {
      await Dio().download(
        item.sourceUrl,
        item.filePath,
        onReceiveProgress: (received, total) {
          if (total <= 0) return;
          final p = received / total;
          state = state
              .map((d) => d.id == item.id ? d.copyWith(progress: p) : d)
              .toList();
        },
      );
      state = state
          .map((d) => d.id == item.id
              ? d.copyWith(status: 'done', progress: 1)
              : d)
          .toList();
    } catch (_) {
      state = state
          .map((d) => d.id == item.id ? d.copyWith(status: 'failed') : d)
          .toList();
    }
    await _persist();
  }

  Future<void> remove(String id) async {
    final targets = state.where((d) => d.id == id).toList();
    state = state.where((d) => d.id != id).toList();
    await _persist();
    for (final d in targets) {
      try {
        final file = File(d.filePath);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 删除失败时忽略，仅移除记录
      }
    }
  }
}

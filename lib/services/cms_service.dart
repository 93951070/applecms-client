import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/comment.dart';
import '../models/site.dart';
import '../models/system_message.dart';
import '../models/user.dart';
import 'app_api_service.dart';
import 'config_service.dart';

final cmsServiceProvider = Provider((ref) => CmsService(ref));

/// CMS 分类节点（type_id / type_name / type_pid）
class CmsCategory {
  final int typeId;
  final String typeName;
  final int typePid;

  const CmsCategory({
    required this.typeId,
    required this.typeName,
    this.typePid = 0,
  });
}

/// 主分类及其子分类
class CmsCategoryGroup {
  final CmsCategory category;
  final List<CmsCategory> subCategories;

  const CmsCategoryGroup({
    required this.category,
    this.subCategories = const [],
  });
}

/// 无法取得站点分类树时的兜底分类（与后端默认数据一致）
const defaultCategoryGroups = <CmsCategoryGroup>[
  CmsCategoryGroup(category: CmsCategory(typeId: 1, typeName: '电影')),
  CmsCategoryGroup(category: CmsCategory(typeId: 2, typeName: '连续剧')),
  CmsCategoryGroup(category: CmsCategory(typeId: 3, typeName: '动漫')),
  CmsCategoryGroup(category: CmsCategory(typeId: 4, typeName: '综艺')),
  CmsCategoryGroup(category: CmsCategory(typeId: 31, typeName: '短剧')),
];

/// 站点数据服务。
///
/// 所有请求均通过 App 加密网关 `/api/app/v1` 完成，不再直接访问明文
/// 的 `/api/provide/vod`。直连播放地址仅在调用 `/play` 时由服务端下发。
class CmsService {
  final Ref _ref;

  CmsService(this._ref);

  Future<String> _base() => _ref.read(configServiceProvider).getApiBaseUrl();

  AppApiService get _api => _ref.read(appApiServiceProvider);

  Future<List<VideoDetail>> search(SiteConfig site, String query,
      {int page = 1}) async {
    try {
      final data = await _api.listVideos(
        await _base(),
        page: page,
        keyword: query,
        limit: 20,
      );
      return _listFromItems(data['items'], site);
    } catch (_) {
      return [];
    }
  }

  /// 按分类拉取列表（顶级分类由服务端聚合子分类）
  Future<List<VideoDetail>> getCategoryList(
    SiteConfig site,
    int typeId, {
    int page = 1,
    int pageSize = 20,
    String? sort,
  }) async {
    try {
      final data = await _api.listVideos(
        await _base(),
        page: page,
        limit: pageSize,
        typeId: '$typeId',
        sort: sort,
      );
      return _listFromItems(data['items'], site);
    } catch (_) {
      return [];
    }
  }

  /// 获取站点分类树（主分类 + 子分类），经加密网关返回。
  Future<List<CmsCategoryGroup>> getCategoryTree(SiteConfig site) async {
    try {
      final hierarchy = await _api.categories(await _base());
      final groups = <CmsCategoryGroup>[];
      for (final entry in hierarchy) {
        final rawCategory = entry['category'];
        if (rawCategory is! Map) continue;
        final subs = <CmsCategory>[];
        final rawSubs = entry['sub_categories'];
        if (rawSubs is List) {
          for (final s in rawSubs) {
            if (s is Map) {
              subs.add(_categoryFromJson(Map<String, dynamic>.from(s)));
            }
          }
        }
        groups.add(CmsCategoryGroup(
          category: _categoryFromJson(Map<String, dynamic>.from(rawCategory)),
          subCategories: subs,
        ));
      }
      groups.sort((a, b) => a.category.typeId.compareTo(b.category.typeId));
      return groups;
    } catch (_) {
      return [];
    }
  }

  Future<VideoDetail?> getDetail(SiteConfig site, String id) async {
    final key = id.trim();
    if (key.isEmpty) return null;

    // 1) 内存缓存命中：立即返回，后台静默刷新
    final mem = _detailMemCache[key];
    if (mem != null) {
      unawaited(_fetchAndCache(site, key));
      return mem;
    }

    // 2) 磁盘缓存命中：切后台/杀进程后再次进入仍可秒开
    final cached = await _loadCachedDetail(key, site);
    if (cached != null) {
      unawaited(_fetchAndCache(site, key));
      return cached;
    }

    // 3) 无缓存：走网关取一次
    return _fetchAndCache(site, key);
  }

  /// 内存中的详情缓存，避免页面重建时重复请求。
  static final Map<String, VideoDetail> _detailMemCache = {};

  /// 读取内存缓存（同步），用于页面首帧立即渲染。
  VideoDetail? cachedDetail(String id) => _detailMemCache[id.trim()];

  Future<VideoDetail?> _loadCachedDetail(String key, SiteConfig site) async {
    try {
      final raw =
          await _ref.read(configServiceProvider).getCachedVideoDetail(key);
      if (raw == null) return null;
      final detail = _detailFromGateway(raw, site);
      if (detail.playGroups.isEmpty) return null;
      _detailMemCache[key] = detail;
      return detail;
    } catch (_) {
      return null;
    }
  }

  Future<VideoDetail?> _fetchAndCache(SiteConfig site, String key) async {
    try {
      final data = await _api.videoDetail(await _base(), key);
      final detail = _detailFromGateway(data, site);
      if (detail.playGroups.isEmpty) return null;
      _detailMemCache[key] = detail;
      unawaited(_ref.read(configServiceProvider).cacheVideoDetail(key, data));
      return detail;
    } catch (_) {
      return null;
    }
  }

  List<VideoDetail> _listFromItems(dynamic items, SiteConfig site) {
    if (items is! List) return [];
    final results = <VideoDetail>[];
    for (final item in items) {
      if (item is! Map) continue;
      results.add(_listEntryToDetail(Map<String, dynamic>.from(item), site));
    }
    return results;
  }

  VideoDetail _listEntryToDetail(Map<String, dynamic> item, SiteConfig site) {
    return VideoDetail(
      id: (item['vod_id'] ?? '').toString(),
      title: (item['vod_name'] ?? '').toString().trim(),
      poster: (item['vod_pic'] ?? '').toString(),
      playGroups: const [],
      source: site.key,
      sourceName: site.name,
      year: item['vod_year']?.toString(),
      desc: (item['vod_blurb'] ?? '').toString().trim(),
      typeName: item['type_name']?.toString(),
      typeId: _asInt(item['type_id']),
    );
  }

  VideoDetail _detailFromGateway(Map<String, dynamic> data, SiteConfig site) {
    final sources = data['play_sources'];
    final groups = <PlayGroup>[];
    if (sources is List) {
      for (final s in sources) {
        if (s is! Map) continue;
        final titles = <String>[];
        final eps = s['episodes'];
        if (eps is List) {
          for (final e in eps) {
            if (e is Map) titles.add((e['name'] ?? '').toString());
          }
        }
        if (titles.isEmpty) continue;
        groups.add(PlayGroup(
          name: (s['source_name'] ?? '').toString(),
          // 直连地址由网关在取流时逐集下发，此处仅占位保持集数索引
          urls: List<String>.filled(titles.length, ''),
          titles: titles,
        ));
      }
    }
    return VideoDetail(
      id: (data['vod_id'] ?? '').toString(),
      title: (data['vod_name'] ?? '').toString().trim(),
      poster: (data['vod_pic'] ?? '').toString(),
      playGroups: groups,
      source: site.key,
      sourceName: site.name,
      year: data['vod_year']?.toString(),
      desc: (data['vod_content'] ?? '')
          .toString()
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim(),
      typeName: data['type_name']?.toString(),
      typeId: _asInt(data['type_id']),
    );
  }

  CmsCategory _categoryFromJson(Map<String, dynamic> json) {
    return CmsCategory(
      typeId: _asInt(json['type_id']),
      typeName: (json['type_name'] ?? '').toString().trim(),
      typePid: _asInt(json['type_pid']),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// 评论列表（分页）。
  Future<CommentPage> getComments(
    String vodId, {
    int page = 1,
    int limit = 20,
  }) async {
    final base = await _base();
    final data = await _api.fetchComments(
      base,
      vodId,
      page: page,
      limit: limit,
    );
    final items = <VideoComment>[];
    final raw = data['items'];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          items.add(VideoComment.fromJson(
            Map<String, dynamic>.from(e),
            base: base,
          ));
        }
      }
    }
    return CommentPage(
      total: _asInt(data['total']),
      page: _asInt(data['page']),
      items: items,
    );
  }

  /// 发表评论，返回结果（失败时抛出 [AppApiException]）。
  Future<PostCommentResult> postComment(String vodId, String content) async {
    final token = await _ref.read(configServiceProvider).getAuthToken();
    final data = await _api.postComment(
      await _base(),
      vodId,
      content,
      token: token,
    );
    if (data['success'] != true) return const PostCommentResult();
    return PostCommentResult(
      pending: data['pending'] == true,
      comment: VideoComment(
        id: (data['comment_id'] ?? '').toString(),
        userName: '我',
        content: content.trim(),
        createdAt: _asInt(data['created_at']),
      ),
    );
  }

  /// 拉取某一集弹幕。
  Future<List<DanmakuItem>> getDanmaku(String vodId, {int episode = 0}) async {
    final items = await _api.fetchDanmaku(
      await _base(),
      vodId,
      episode: episode,
    );
    return items.map(DanmakuItem.fromJson).toList();
  }

  /// 发送弹幕，返回结果。
  Future<PostDanmakuResult> postDanmaku(
    String vodId, {
    required int episode,
    required int timeMs,
    required String content,
    String color = '#FFFFFF',
    int mode = 0,
  }) async {
    final token = await _ref.read(configServiceProvider).getAuthToken();
    final data = await _api.postDanmaku(
      await _base(),
      vodId,
      episode: episode,
      timeMs: timeMs,
      content: content,
      color: color,
      mode: mode,
      token: token,
    );
    return PostDanmakuResult(
      ok: data['success'] == true,
      pending: data['pending'] == true,
    );
  }

  /// 提交意见反馈，登录可选。
  Future<bool> postFeedback(String content, {String contact = ''}) async {
    final token = await _ref.read(configServiceProvider).getAuthToken();
    final data = await _api.postFeedback(
      await _base(),
      content: content,
      contact: contact,
      token: token,
    );
    return data['success'] == true;
  }

  /// 系统消息列表。
  Future<MessagePage> getMessages({int page = 1, int limit = 20}) async {
    final token = await _ref.read(configServiceProvider).getAuthToken();
    if (token == null || token.isEmpty) return const MessagePage();
    final data = await _api.fetchMessages(
      await _base(),
      page: page,
      limit: limit,
      token: token,
    );
    final items = <SystemMessage>[];
    final raw = data['items'];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          items.add(SystemMessage.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    return MessagePage(unread: _asInt(data['unread']), items: items);
  }

  /// 标记单条消息已读。
  Future<void> markMessageRead(String messageId) async {
    final token = await _ref.read(configServiceProvider).getAuthToken();
    if (token == null || token.isEmpty) return;
    await _api.markMessageRead(await _base(), messageId, token: token);
  }

  /// 全部标记已读。
  Future<void> markAllMessagesRead() async {
    final token = await _ref.read(configServiceProvider).getAuthToken();
    if (token == null || token.isEmpty) return;
    await _api.markAllMessagesRead(await _base(), token: token);
  }

  /// 账号播放记录（仅登录后可用）。
  Future<List<PlayRecord>> fetchServerHistory() async {
    final token = await _ref.read(configServiceProvider).getAuthToken();
    if (token == null || token.isEmpty) return const [];
    final data = await _api.fetchHistory(await _base(), token: token);
    final raw = data['items'];
    final items = <PlayRecord>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          items.add(_historyToRecord(Map<String, dynamic>.from(e)));
        }
      }
    }
    return items;
  }

  /// 上报一条播放进度到账号。
  Future<void> pushServerHistory(PlayRecord record) async {
    final token = await _ref.read(configServiceProvider).getAuthToken();
    final vodId = record.doubanId ?? '';
    if (token == null || token.isEmpty || vodId.isEmpty) return;
    await _api.saveHistory(
      await _base(),
      videoId: vodId,
      episode: record.index,
      playSource: 0,
      positionMs: record.playTime * 1000,
      totalMs: record.totalTime * 1000,
      title: record.title,
      cover: record.cover,
      token: token,
    );
  }

  /// 清除账号播放记录；`videoId` 为空时清空全部。
  Future<void> clearServerHistory({String? videoId}) async {
    final token = await _ref.read(configServiceProvider).getAuthToken();
    if (token == null || token.isEmpty) return;
    await _api.clearHistory(await _base(), videoId: videoId, token: token);
  }

  /// 更新账号资料（昵称/头像），返回更新后的用户。
  Future<AppUser?> updateProfile({String? nickname, String? avatar}) async {
    final token = await _ref.read(configServiceProvider).getAuthToken();
    if (token == null || token.isEmpty) {
      throw const AppApiException('请先登录');
    }
    final data = await _api.updateProfile(
      await _base(),
      nickname: nickname,
      avatar: avatar,
      token: token,
    );
    final user = data['user'];
    if (user is Map) return AppUser.fromJson(Map<String, dynamic>.from(user));
    return null;
  }

  PlayRecord _historyToRecord(Map<String, dynamic> json) {
    final title = (json['title'] ?? '').toString();
    return PlayRecord(
      title: title,
      sourceName: '',
      cover: (json['cover'] ?? '').toString(),
      year: '',
      index: _asInt(json['episode']),
      totalEpisodes: 0,
      playTime: _asInt(json['position_ms']) ~/ 1000,
      totalTime: _asInt(json['total_ms']) ~/ 1000,
      saveTime: _asInt(json['updated_at']) ~/ 1000,
      searchTitle: title,
      doubanId: (json['video_id'] ?? '').toString(),
    );
  }
}

/// 发表评论结果。
class PostCommentResult {
  final VideoComment? comment;
  final bool pending;

  const PostCommentResult({this.comment, this.pending = false});
}

/// 发送弹幕结果。
class PostDanmakuResult {
  final bool ok;
  final bool pending;

  const PostDanmakuResult({this.ok = false, this.pending = false});
}

/// 评论分页结果。
class CommentPage {
  final int total;
  final int page;
  final List<VideoComment> items;

  const CommentPage({
    this.total = 0,
    this.page = 1,
    this.items = const [],
  });
}

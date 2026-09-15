import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/comment.dart';
import '../models/douban_media.dart';
import '../models/site.dart';
import '../models/system_message.dart';
import '../models/user.dart';
import '../core/content_kind.dart';
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

/// 首页聚合的单个栏目
class HomeSection {
  final int typeId;
  final String title;
  final List<VideoDetail> items;

  const HomeSection({
    required this.typeId,
    required this.title,
    this.items = const [],
  });
}

/// 首页聚合数据：幻灯片 + 各栏目（栏目间已跨栏去重）
class HomeFeed {
  final List<VideoDetail> hero;
  final List<HomeSection> sections;

  const HomeFeed({this.hero = const [], this.sections = const []});
}

/// 分页搜索结果
class SearchPageResult {
  final List<VideoDetail> items;
  final int total;
  final bool hasMore;

  const SearchPageResult({
    this.items = const [],
    this.total = 0,
    this.hasMore = false,
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

  /// 按分类拉取列表（顶级分类由服务端聚合子分类）。
  ///
  /// 先返回本地缓存（内存/磁盘）实现秒开，超过新鲜期再后台静默刷新。
  Future<List<VideoDetail>> getCategoryList(
    SiteConfig site,
    int typeId, {
    int page = 1,
    int pageSize = 20,
    String? sort,
  }) async {
    final key = 'cat:$typeId:$page:$pageSize:${sort ?? ''}';
    final cached = await _readListCache(key, site);
    if (cached != null) {
      if (DateTime.now().millisecondsSinceEpoch - cached.$2 > _listFreshMs) {
        unawaited(_refreshList(key, site, typeId, page, pageSize, sort));
      }
      return cached.$1;
    }
    return await _refreshList(key, site, typeId, page, pageSize, sort) ?? [];
  }

  /// 获取站点分类树（主分类 + 子分类），经加密网关返回。
  ///
  /// 分类树变化极少，本地缓存 24 小时内直接复用，过期后后台刷新。
  Future<List<CmsCategoryGroup>> getCategoryTree(SiteConfig site) async {
    const key = 'tree';
    final mem = _treeMemCache[key];
    if (mem != null) {
      if (DateTime.now().millisecondsSinceEpoch - mem.$2 > _treeFreshMs) {
        unawaited(_refreshTree(key, site));
      }
      return mem.$1;
    }
    try {
      final raw = await _ref.read(configServiceProvider).getCachedList(key);
      if (raw != null) {
        final at = _asInt(raw['at']);
        if (at > 0 &&
            DateTime.now().millisecondsSinceEpoch - at <= _listDiskFreshMs) {
          final groups = _groupsFromHierarchy(raw['items']);
          _treeMemCache[key] = (groups, at);
          unawaited(_refreshTree(key, site));
          return groups;
        }
      }
    } catch (_) {
      // 忽略缓存读取异常，走网络。
    }
    return await _refreshTree(key, site) ?? [];
  }

  /// 首屏聚合：一次拉取幻灯片与各栏目。先返回缓存，后台刷新。
  Future<HomeFeed?> getHomeFeed(
    SiteConfig site,
    List<int> typeIds, {
    int limit = 18,
    int heroLimit = 6,
  }) async {
    final key = 'home:${typeIds.join(',')}:$limit:$heroLimit';
    final cached = await _readHomeCache(key, site);
    if (cached != null) {
      if (DateTime.now().millisecondsSinceEpoch - cached.$2 > _listFreshMs) {
        unawaited(_refreshHome(key, site, typeIds, limit, heroLimit));
      }
      return cached.$1;
    }
    return await _refreshHome(key, site, typeIds, limit, heroLimit);
  }

  Future<List<CmsCategoryGroup>?> _refreshTree(String key, SiteConfig site) async {
    try {
      final hierarchy = await _api.categories(await _base());
      final groups = _groupsFromHierarchy(hierarchy);
      final at = DateTime.now().millisecondsSinceEpoch;
      _treeMemCache[key] = (groups, at);
      unawaited(_ref.read(configServiceProvider).cacheList(key, {
        'items': hierarchy,
        'at': at,
      }));
      _listUpdates.add(key);
      return groups;
    } catch (_) {
      return null;
    }
  }

  List<CmsCategoryGroup> _groupsFromHierarchy(dynamic hierarchyRaw) {
    final groups = <CmsCategoryGroup>[];
    if (hierarchyRaw is! List) return groups;
    for (final entry in hierarchyRaw) {
      if (entry is! Map) continue;
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
  }

  Future<(List<VideoDetail>, int)?> _readListCache(
    String key,
    SiteConfig site,
  ) async {
    final mem = _listMemCache[key];
    if (mem != null) return mem;
    try {
      final raw = await _ref.read(configServiceProvider).getCachedList(key);
      if (raw == null) return null;
      final at = _asInt(raw['at']);
      if (at <= 0) return null;
      if (DateTime.now().millisecondsSinceEpoch - at > _listDiskFreshMs) {
        return null;
      }
      final list = _listFromItems(raw['items'], site);
      _listMemCache[key] = (list, at);
      return (list, at);
    } catch (_) {
      return null;
    }
  }

  Future<List<VideoDetail>?> _refreshList(
    String key,
    SiteConfig site,
    int typeId,
    int page,
    int pageSize,
    String? sort,
  ) async {
    try {
      final data = await _api.listVideos(
        await _base(),
        page: page,
        limit: pageSize,
        typeId: '$typeId',
        sort: sort,
      );
      final items = data['items'];
      final list = _listFromItems(items, site);
      final at = DateTime.now().millisecondsSinceEpoch;
      _listMemCache[key] = (list, at);
      unawaited(_ref
          .read(configServiceProvider)
          .cacheList(key, {'items': items, 'at': at}));
      _listUpdates.add(key);
      return list;
    } catch (_) {
      return null;
    }
  }

  Future<(HomeFeed, int)?> _readHomeCache(String key, SiteConfig site) async {
    final mem = _homeMemCache[key];
    if (mem != null) return mem;
    try {
      final raw = await _ref.read(configServiceProvider).getCachedList(key);
      if (raw == null) return null;
      final at = _asInt(raw['at']);
      if (at <= 0) return null;
      if (DateTime.now().millisecondsSinceEpoch - at > _listDiskFreshMs) {
        return null;
      }
      final feed = _homeFeedFromRaw(raw, site);
      _homeMemCache[key] = (feed, at);
      return (feed, at);
    } catch (_) {
      return null;
    }
  }

  Future<HomeFeed?> _refreshHome(
    String key,
    SiteConfig site,
    List<int> typeIds,
    int limit,
    int heroLimit,
  ) async {
    try {
      final data = await _api.home(
        await _base(),
        typeIds: typeIds,
        limit: limit,
        heroLimit: heroLimit,
      );
      final feed = _homeFeedFromRaw(data, site);
      final at = DateTime.now().millisecondsSinceEpoch;
      _homeMemCache[key] = (feed, at);
      unawaited(_ref.read(configServiceProvider).cacheList(key, {
        'hero': data['hero'],
        'sections': data['sections'],
        'at': at,
      }));
      _listUpdates.add(key);
      return feed;
    } catch (_) {
      return null;
    }
  }

  HomeFeed _homeFeedFromRaw(dynamic raw, SiteConfig site) {
    // 短剧是竖屏 Feed 形态，不进横版幻灯片与首页栏目。
    final hero = _listFromItems(raw['hero'], site)
        .where((v) => !isFeedCategory(typeId: v.typeId, typeName: v.typeName))
        .toList();
    final sections = <HomeSection>[];
    final rawSections = raw['sections'];
    if (rawSections is List) {
      for (final s in rawSections) {
        if (s is! Map) continue;
        final typeId = _asInt(s['type_id']);
        final title = (s['title'] ?? '').toString();
        if (isFeedCategory(typeId: typeId, typeName: title)) continue;
        sections.add(HomeSection(
          typeId: typeId,
          title: title,
          items: _listFromItems(s['items'], site),
        ));
      }
    }
    return HomeFeed(hero: hero, sections: sections);
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

  /// 后台静默刷新完成后的通知流，载荷为 vod_id；
  /// 页面据此用最新详情重建选集锁等会员状态。
  final StreamController<String> _detailUpdates =
      StreamController<String>.broadcast();

  Stream<String> get detailUpdates => _detailUpdates.stream;

  /// 读取内存缓存（同步），用于页面首帧立即渲染。
  VideoDetail? cachedDetail(String id) => _detailMemCache[id.trim()];

  // ==================== 列表 / 分类树 / 首页聚合缓存 ====================

  /// 列表缓存新鲜期：超过后先返回旧数据再后台刷新。
  static const int _listFreshMs = 5 * 60 * 1000;

  /// 分类树新鲜期。
  static const int _treeFreshMs = 24 * 60 * 60 * 1000;

  /// 磁盘缓存最长可用时长，超过则不再使用。
  static const int _listDiskFreshMs = 6 * 60 * 60 * 1000;

  static final Map<String, (List<VideoDetail>, int)> _listMemCache = {};
  static final Map<String, (List<CmsCategoryGroup>, int)> _treeMemCache = {};
  static final Map<String, (HomeFeed, int)> _homeMemCache = {};

  /// 后台刷新完成后的通知流，载荷为缓存 key；页面据此重建。
  final StreamController<String> _listUpdates =
      StreamController<String>.broadcast();

  Stream<String> get listUpdates => _listUpdates.stream;

  /// 分页搜索：返回当页结果、总数与是否还有更多。
  Future<SearchPageResult> searchPaged(
    SiteConfig site,
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async {
    try {
      final data = await _api.listVideos(
        await _base(),
        page: page,
        limit: pageSize,
        keyword: query,
      );
      final items = _listFromItems(data['items'], site);
      final total = _asInt(data['total']);
      final hasMore = data['has_more'] == true || (page * pageSize) < total;
      final at = DateTime.now().millisecondsSinceEpoch;
      _listMemCache['search:${query.trim()}:$page:$pageSize'] = (items, at);
      return SearchPageResult(items: items, total: total, hasMore: hasMore);
    } catch (_) {
      return const SearchPageResult();
    }
  }

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
      _detailUpdates.add(key);
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
      heroImage: (item['vod_pic_slide'] ?? '').toString().trim().isEmpty
          ? null
          : item['vod_pic_slide'].toString(),
      playGroups: const [],
      source: site.key,
      sourceName: site.name,
      year: sanitizeYear(item['vod_year']),
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
        final needVip = <int>[];
        final eps = s['episodes'];
        if (eps is List) {
          for (final e in eps) {
            if (e is Map) {
              titles.add((e['name'] ?? '').toString());
              needVip.add(_asInt(e['need_vip']));
            }
          }
        }
        if (titles.isEmpty) continue;
        groups.add(PlayGroup(
          name: (s['source_name'] ?? '').toString(),
          // 直连地址由网关在取流时逐集下发，此处仅占位保持集数索引
          urls: List<String>.filled(titles.length, ''),
          titles: titles,
          needVip: needVip,
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
      year: sanitizeYear(data['vod_year']),
      desc: (data['vod_content'] ?? '')
          .toString()
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim(),
      typeName: data['type_name']?.toString(),
      actors: (data['vod_actor'] ?? '').toString().trim(),
      directors: (data['vod_director'] ?? '').toString().trim(),
      typeId: _asInt(data['type_id']),
      vipMode: _asInt(data['vip_mode']),
      freeEpisodes: _asInt(data['free_episodes']),
    );
  }

  /// 按需拉取豆瓣评分、简介、演职员与横版剧照（后台未开启或未匹配时返回 null）。
  Future<DoubanMedia?> fetchDouban(String vodId) async {
    if (vodId.trim().isEmpty) return null;
    try {
      final data = await _api.doubanMedia(await _base(), vodId);
      final media = DoubanMedia.fromJson(data);
      if (!media.enabled || !media.matched) return null;
      return media;
    } catch (_) {
      return null;
    }
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

  /// 一键清除全部系统消息。
  Future<void> clearAllMessages() async {
    final token = await _ref.read(configServiceProvider).getAuthToken();
    if (token == null || token.isEmpty) return;
    await _api.clearMessages(await _base(), token: token);
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

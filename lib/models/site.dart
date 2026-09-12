class SiteConfig {
  final String key;
  final String name;
  final String api;
  final String? detail;
  final String from;
  final bool disabled;

  SiteConfig({
    required this.key,
    required this.name,
    required this.api,
    this.detail,
    this.from = 'custom',
    this.disabled = false,
  });

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'api': api,
    'detail': detail,
    'from': from,
    'disabled': disabled,
  };

  factory SiteConfig.fromJson(Map<String, dynamic> json) {
    return SiteConfig(
      key: json['key'] ?? '',
      name: json['name'] ?? '',
      api: json['api'] ?? '',
      detail: json['detail'],
      from: json['from'] ?? 'custom',
      disabled: json['disabled'] ?? false,
    );
  }
}

class PlayGroup {
  final String name;
  final List<String> urls;
  final List<String> titles;

  /// 与 [titles] 逐集对应的会员要求：0 免费，1 需 VIP，2 需 SVIP。
  final List<int> needVip;

  PlayGroup({
    required this.name,
    required this.urls,
    required this.titles,
    this.needVip = const [],
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'urls': urls,
        'titles': titles,
        'need_vip': needVip,
      };

  factory PlayGroup.fromJson(Map<String, dynamic> json) {
    final titles = List<String>.from((json['titles'] as List?) ?? const []);
    final urls = List<String>.from((json['urls'] as List?) ?? const []);
    final needVip = ((json['need_vip'] as List?) ?? const [])
        .map((e) => e is int ? e : int.tryParse(e.toString()) ?? 0)
        .toList();
    return PlayGroup(
      name: (json['name'] ?? '').toString(),
      urls: urls.length == titles.length
          ? urls
          : List<String>.filled(titles.length, ''),
      titles: titles,
      needVip: needVip.length == titles.length
          ? needVip
          : List<int>.filled(titles.length, 0),
    );
  }
}

class VideoDetail {
  final String id;
  final String title;
  final String poster;
  final List<PlayGroup> playGroups;
  final String source;
  final String sourceName;
  final String? year;
  final String? desc;
  final String? typeName;
  final int typeId;

  /// 会员观看模式：0 免费，1 会员。
  final int vipMode;

  /// 会员模式下每部作品免费的前 N 集。
  final int freeEpisodes;

  VideoDetail({
    required this.id,
    required this.title,
    required this.poster,
    required this.playGroups,
    required this.source,
    required this.sourceName,
    this.year,
    this.desc,
    this.typeName,
    this.typeId = 0,
    this.vipMode = 0,
    this.freeEpisodes = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'poster': poster,
        'source': source,
        'source_name': sourceName,
        'year': year,
        'desc': desc,
        'type_name': typeName,
        'type_id': typeId,
        'play_groups': playGroups.map((g) => g.toJson()).toList(),
        'vip_mode': vipMode,
        'free_episodes': freeEpisodes,
      };

  factory VideoDetail.fromJson(Map<String, dynamic> json) {
    return VideoDetail(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      poster: (json['poster'] ?? '').toString(),
      playGroups: ((json['play_groups'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => PlayGroup.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      source: (json['source'] ?? '').toString(),
      sourceName: (json['source_name'] ?? '').toString(),
      year: json['year']?.toString(),
      desc: json['desc']?.toString(),
      typeName: json['type_name']?.toString(),
      typeId: (json['type_id'] is int)
          ? json['type_id'] as int
          : int.tryParse(json['type_id']?.toString() ?? '') ?? 0,
      vipMode: (json['vip_mode'] is int)
          ? json['vip_mode'] as int
          : int.tryParse(json['vip_mode']?.toString() ?? '') ?? 0,
      freeEpisodes: (json['free_episodes'] is int)
          ? json['free_episodes'] as int
          : int.tryParse(json['free_episodes']?.toString() ?? '') ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoDetail &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          source == other.source;

  @override
  int get hashCode => id.hashCode ^ source.hashCode;
}

class PlayRecord {
  final String title;
  final String sourceName;
  final String cover;
  final String year;
  final int index;
  final int totalEpisodes;
  final int playTime;
  final int totalTime;
  final int saveTime;
  final String searchTitle;
  final String? doubanId;
  PlayRecord({required this.title, required this.sourceName, required this.cover, required this.year, required this.index, required this.totalEpisodes, required this.playTime, required this.totalTime, required this.saveTime, required this.searchTitle, this.doubanId});
  Map<String, dynamic> toJson() => {'title': title, 'source_name': sourceName, 'cover': cover, 'year': year, 'index': index, 'total_episodes': totalEpisodes, 'play_time': playTime, 'total_time': totalTime, 'save_time': saveTime, 'search_title': searchTitle, 'douban_id': doubanId};
  factory PlayRecord.fromJson(Map<String, dynamic> json) => PlayRecord(title: json['title'] ?? '', sourceName: json['source_name'] ?? '', cover: json['cover'] ?? '', year: json['year'] ?? '', index: json['index'] ?? 0, totalEpisodes: json['total_episodes'] ?? 0, playTime: json['play_time'] ?? 0, totalTime: json['total_time'] ?? 0, saveTime: json['save_time'] ?? 0, searchTitle: json['search_title'] ?? '', doubanId: json['douban_id']);
}

class SkipConfig {
  final bool enable;
  final int introTime;
  final int outroTime;

  const SkipConfig({
    this.enable = false,
    this.introTime = 0,
    this.outroTime = 0,
  });

  Map<String, dynamic> toJson() => {
    'enable': enable,
    'intro_time': introTime,
    'outro_time': outroTime,
  };

  factory SkipConfig.fromJson(Map<String, dynamic> json) => SkipConfig(
    enable: json['enable'] ?? false,
    introTime: json['intro_time'] ?? 0,
    outroTime: json['outro_time'] ?? 0,
  );
}

class Favorite {
  final String subjectId;
  final String title;
  final String sourceName;
  final String cover;
  final String year;
  final int totalEpisodes;
  final int saveTime;
  final String searchTitle;
  final String origin;
  Favorite({this.subjectId = '', required this.title, required this.sourceName, required this.cover, required this.year, required this.totalEpisodes, required this.saveTime, required this.searchTitle, this.origin = 'vod'});
  Map<String, dynamic> toJson() => {'subject_id': subjectId, 'title': title, 'source_name': sourceName, 'cover': cover, 'year': year, 'total_episodes': totalEpisodes, 'save_time': saveTime, 'search_title': searchTitle, 'origin': origin};
  factory Favorite.fromJson(Map<String, dynamic> json) => Favorite(subjectId: json['subject_id'] ?? '', title: json['title'] ?? '', sourceName: json['source_name'] ?? '', cover: json['cover'] ?? '', year: json['year'] ?? '', totalEpisodes: json['total_episodes'] ?? 0, saveTime: json['save_time'] ?? 0, searchTitle: json['search_title'] ?? '', origin: json['origin'] ?? 'vod');
}
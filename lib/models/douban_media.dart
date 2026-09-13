/// 豆瓣演职员条目。
class DoubanCredit {
  final String name;
  final String character;
  final String avatar;

  const DoubanCredit({
    required this.name,
    this.character = '',
    this.avatar = '',
  });

  factory DoubanCredit.fromJson(Map<String, dynamic> json) => DoubanCredit(
        name: (json['name'] ?? '').toString(),
        character: (json['character'] ?? '').toString(),
        avatar: (json['avatar'] ?? '').toString(),
      );
}

/// 播放页「简介」弹层所需的豆瓣聚合数据。
class DoubanMedia {
  /// 后台是否开启豆瓣信息。
  final bool enabled;

  /// 是否匹配到豆瓣条目。
  final bool matched;

  final int subjectId;
  final String title;
  final double? rating;
  final String year;
  final int? episodes;
  final String intro;
  final String poster;

  /// 横版图片（预告封面或剧照），供首页幻灯片使用。
  final String slide;

  final List<DoubanCredit> directors;
  final List<DoubanCredit> actors;

  const DoubanMedia({
    this.enabled = false,
    this.matched = false,
    this.subjectId = 0,
    this.title = '',
    this.rating,
    this.year = '',
    this.episodes,
    this.intro = '',
    this.poster = '',
    this.slide = '',
    this.directors = const [],
    this.actors = const [],
  });

  bool get hasCredits => actors.isNotEmpty || directors.isNotEmpty;

  factory DoubanMedia.fromJson(Map<String, dynamic> json) => DoubanMedia(
        enabled: json['enabled'] == true,
        matched: json['matched'] == true,
        subjectId: (json['subject_id'] as num?)?.toInt() ?? 0,
        title: (json['title'] ?? '').toString(),
        rating: (json['rating'] as num?)?.toDouble(),
        year: (json['year'] ?? '').toString(),
        episodes: (json['episodes'] as num?)?.toInt(),
        intro: (json['intro'] ?? '').toString(),
        poster: (json['poster'] ?? '').toString(),
        slide: (json['slide'] ?? '').toString(),
        directors: _credits(json['directors']),
        actors: _credits(json['actors']),
      );

  static List<DoubanCredit> _credits(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => DoubanCredit.fromJson(Map<String, dynamic>.from(e)))
        .where((c) => c.name.isNotEmpty)
        .toList();
  }
}

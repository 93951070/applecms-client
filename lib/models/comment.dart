/// 评论与弹幕模型（均来自加密网关 `/api/app/v1`）。

class VideoComment {
  final String id;
  final String userName;
  final String? userPortrait;
  final String content;
  final int likeCount;
  final int createdAt;

  const VideoComment({
    required this.id,
    required this.userName,
    this.userPortrait,
    required this.content,
    this.likeCount = 0,
    this.createdAt = 0,
  });

  factory VideoComment.fromJson(Map<String, dynamic> json) {
    return VideoComment(
      id: (json['comment_id'] ?? '').toString(),
      userName: (json['user_name'] ?? '用户').toString(),
      userPortrait: _nonEmpty(json['user_portrait']),
      content: (json['content'] ?? '').toString(),
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }

  static String? _nonEmpty(dynamic value) {
    final s = value?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }
}

class DanmakuItem {
  final int timeMs;
  final String content;
  final String color;
  final int mode;

  const DanmakuItem({
    required this.timeMs,
    required this.content,
    this.color = '#FFFFFF',
    this.mode = 0,
  });

  factory DanmakuItem.fromJson(Map<String, dynamic> json) {
    return DanmakuItem(
      timeMs: (json['time_ms'] as num?)?.toInt() ?? 0,
      content: (json['content'] ?? '').toString(),
      color: (json['color'] ?? '#FFFFFF').toString(),
      mode: (json['mode'] as num?)?.toInt() ?? 0,
    );
  }
}

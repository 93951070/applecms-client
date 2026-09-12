/// 一起看房间成员。
class WatchMemberInfo {
  final String userId;
  final String nickName;
  final bool online;
  final bool buffering;
  final bool muted;
  final bool isHost;

  const WatchMemberInfo({
    required this.userId,
    this.nickName = '',
    this.online = false,
    this.buffering = false,
    this.muted = false,
    this.isHost = false,
  });

  factory WatchMemberInfo.fromJson(Map<String, dynamic> json) {
    return WatchMemberInfo(
      userId: (json['user_id'] ?? '').toString(),
      nickName: (json['nick_name'] ?? '').toString(),
      online: json['online'] == true,
      buffering: json['buffering'] == true,
      muted: json['muted'] == true,
      isHost: json['is_host'] == true,
    );
  }
}

/// 一起看房间信息。
class WatchRoomInfo {
  final String roomId;
  final String code;
  final String hostId;
  final bool isHost;
  final bool canControl;
  final String vodId;
  final String title;
  final String cover;
  final int playSource;
  final int episode;
  final int positionMs;
  final bool paused;
  final bool isPublic;
  final int memberLimit;
  final bool allowMemberControl;
  final bool hostBuffering;
  final bool stallHold;
  final List<WatchMemberInfo> members;
  final int updatedAt;
  final int lastActiveAt;

  const WatchRoomInfo({
    required this.roomId,
    required this.code,
    this.hostId = '',
    this.isHost = false,
    this.canControl = false,
    required this.vodId,
    this.title = '',
    this.cover = '',
    this.playSource = 0,
    this.episode = 0,
    this.positionMs = 0,
    this.paused = true,
    this.isPublic = false,
    this.memberLimit = 8,
    this.allowMemberControl = false,
    this.hostBuffering = false,
    this.stallHold = false,
    this.members = const [],
    this.updatedAt = 0,
    this.lastActiveAt = 0,
  });

  factory WatchRoomInfo.fromJson(Map<String, dynamic> json) {
    final rawMembers = json['members'];
    final members = <WatchMemberInfo>[];
    if (rawMembers is List) {
      for (final e in rawMembers) {
        if (e is Map) {
          members.add(WatchMemberInfo.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    return WatchRoomInfo(
      roomId: (json['room_id'] ?? '').toString(),
      code: (json['code'] ?? '').toString(),
      hostId: (json['host_id'] ?? '').toString(),
      isHost: json['is_host'] == true,
      canControl: json['can_control'] == true,
      vodId: (json['vod_id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      cover: (json['cover'] ?? '').toString(),
      playSource: (json['play_source'] as num?)?.toInt() ?? 0,
      episode: (json['episode'] as num?)?.toInt() ?? 0,
      positionMs: (json['position_ms'] as num?)?.toInt() ?? 0,
      paused: json['paused'] == true,
      isPublic: json['is_public'] == true,
      memberLimit: (json['member_limit'] as num?)?.toInt() ?? 8,
      allowMemberControl: json['allow_member_control'] == true,
      hostBuffering: json['host_buffering'] == true,
      stallHold: json['stall_hold'] == true,
      members: members,
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      lastActiveAt: (json['last_active_at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 一起看聊天消息。
class WatchChatMessage {
  final String userId;
  final String nickName;
  final String content;
  final int createdAt;

  const WatchChatMessage({
    required this.userId,
    this.nickName = '',
    required this.content,
    this.createdAt = 0,
  });

  factory WatchChatMessage.fromJson(Map<String, dynamic> json) {
    return WatchChatMessage(
      userId: (json['user_id'] ?? '').toString(),
      nickName: (json['nick_name'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }
}

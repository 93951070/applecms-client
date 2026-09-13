/// 一起看房间成员。
class WatchMemberInfo {
  final String userId;
  final String nickName;
  final String portrait;
  final bool vip;
  final bool online;
  final bool buffering;
  final bool muted;
  final bool isHost;

  const WatchMemberInfo({
    required this.userId,
    this.nickName = '',
    this.portrait = '',
    this.vip = false,
    this.online = false,
    this.buffering = false,
    this.muted = false,
    this.isHost = false,
  });

  factory WatchMemberInfo.fromJson(Map<String, dynamic> json) {
    return WatchMemberInfo(
      userId: (json['user_id'] ?? '').toString(),
      nickName: (json['nick_name'] ?? '').toString(),
      portrait: (json['portrait'] ?? '').toString(),
      vip: json['vip'] == true,
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

/// 离开一起看房间时回传给播放页的进度快照。
///
/// 一起看结束后，把房间内最后所在集与进度同步回正常播放页，避免用户
/// 退出后还要手动拖回原来的位置。
class WatchPlaybackState {
  final String vodId;
  final int playSource;
  final int episode;
  final int positionMs;

  const WatchPlaybackState({
    required this.vodId,
    this.playSource = 0,
    this.episode = 0,
    this.positionMs = 0,
  });
}

/// 一起看聊天消息。
class WatchChatMessage {
  final String userId;
  final String nickName;
  final String portrait;
  final bool vip;
  final String content;
  final bool system;
  final int createdAt;

  const WatchChatMessage({
    required this.userId,
    this.nickName = '',
    this.portrait = '',
    this.vip = false,
    required this.content,
    this.system = false,
    this.createdAt = 0,
  });

  factory WatchChatMessage.fromJson(Map<String, dynamic> json) {
    return WatchChatMessage(
      userId: (json['user_id'] ?? '').toString(),
      nickName: (json['nick_name'] ?? '').toString(),
      portrait: (json['portrait'] ?? '').toString(),
      vip: json['vip'] == true,
      content: (json['content'] ?? '').toString(),
      system: json['system'] == true,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 大厅中的进行中房间。
class WatchHallRoom {
  final String code;
  final String title;
  final String cover;
  final String hostId;
  final String hostName;
  final String hostPortrait;
  final bool isPublic;
  final bool hasPassword;
  final bool isMember;
  final bool paused;
  final int memberCount;
  final int memberLimit;
  final int episode;
  final int lastActiveAt;

  const WatchHallRoom({
    required this.code,
    this.title = '',
    this.cover = '',
    this.hostId = '',
    this.hostName = '',
    this.hostPortrait = '',
    this.isPublic = true,
    this.hasPassword = false,
    this.isMember = false,
    this.paused = false,
    this.memberCount = 0,
    this.memberLimit = 8,
    this.episode = 0,
    this.lastActiveAt = 0,
  });

  factory WatchHallRoom.fromJson(Map<String, dynamic> json) {
    return WatchHallRoom(
      code: (json['code'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      cover: (json['cover'] ?? '').toString(),
      hostId: (json['host_id'] ?? '').toString(),
      hostName: (json['host_name'] ?? '').toString(),
      hostPortrait: (json['host_portrait'] ?? '').toString(),
      isPublic: json['is_public'] == true,
      hasPassword: json['has_password'] == true,
      isMember: json['is_member'] == true,
      paused: json['paused'] == true,
      memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      memberLimit: (json['member_limit'] as num?)?.toInt() ?? 8,
      episode: (json['episode'] as num?)?.toInt() ?? 0,
      lastActiveAt: (json['last_active_at'] as num?)?.toInt() ?? 0,
    );
  }
}

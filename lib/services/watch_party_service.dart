import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/watch_party.dart';
import 'app_api_service.dart';
import 'config_service.dart';

final watchPartyServiceProvider = Provider((ref) => WatchPartyService(ref));

/// 一起看服务：封装房间接口，自动附带登录令牌。
class WatchPartyService {
  final Ref _ref;

  WatchPartyService(this._ref);

  Future<String> _base() => _ref.read(configServiceProvider).getApiBaseUrl();

  AppApiService get _api => _ref.read(appApiServiceProvider);

  Future<String?> _token() =>
      _ref.read(configServiceProvider).getAuthToken();

  Future<List<WatchRoomInfo>> myRooms() async {
    final token = await _token();
    if (token == null || token.isEmpty) return const [];
    final data = await _api.watchMyRooms(await _base(), token: token);
    final raw = data['items'];
    final items = <WatchRoomInfo>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          items.add(WatchRoomInfo.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    return items;
  }

  Future<WatchRoomInfo> createRoom({
    required String vodId,
    int playSource = 0,
    int episode = 0,
    int positionMs = 0,
    bool isPublic = false,
    int memberLimit = 0,
    bool allowMemberControl = false,
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const AppApiException('请先登录');
    }
    final data = await _api.watchCreateRoom(
      await _base(),
      vodId: vodId,
      playSource: playSource,
      episode: episode,
      positionMs: positionMs,
      isPublic: isPublic,
      memberLimit: memberLimit,
      allowMemberControl: allowMemberControl,
      token: token,
    );
    return _roomFrom(data);
  }

  Future<WatchRoomInfo> joinRoom(String code) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const AppApiException('请先登录');
    }
    final data = await _api.watchJoinRoom(await _base(), code, token: token);
    return _roomFrom(data);
  }

  Future<WatchRoomInfo> updateTimeline(
    String code, {
    required bool paused,
    required int positionMs,
    required int episode,
    required int playSource,
    bool buffering = false,
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const AppApiException('请先登录');
    }
    final data = await _api.watchUpdateTimeline(
      await _base(),
      code,
      paused: paused,
      positionMs: positionMs,
      episode: episode,
      playSource: playSource,
      buffering: buffering,
      token: token,
    );
    return _roomFrom(data);
  }

  Future<WatchRoomInfo> heartbeat(
    String code, {
    required bool buffering,
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const AppApiException('请先登录');
    }
    final data = await _api.watchHeartbeat(
      await _base(),
      code,
      buffering: buffering,
      token: token,
    );
    return _roomFrom(data);
  }

  Future<void> leaveRoom(String code) async {
    final token = await _token();
    if (token == null || token.isEmpty) return;
    await _api.watchLeaveRoom(await _base(), code, token: token);
  }

  Future<void> closeRoom(String code) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const AppApiException('请先登录');
    }
    await _api.watchCloseRoom(await _base(), code, token: token);
  }

  Future<List<WatchChatMessage>> fetchMessages(
    String code, {
    int since = 0,
    int before = 0,
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) return const [];
    final data = await _api.watchFetchMessages(
      await _base(),
      code,
      since: since,
      before: before,
      token: token,
    );
    final raw = data['items'];
    final items = <WatchChatMessage>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          items.add(WatchChatMessage.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    return items;
  }

  Future<WatchChatMessage?> sendMessage(String code, String content) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const AppApiException('请先登录');
    }
    final data = await _api.watchSendMessage(
      await _base(),
      code,
      content: content,
      token: token,
    );
    final msg = data['message'];
    if (msg is Map) {
      return WatchChatMessage.fromJson(Map<String, dynamic>.from(msg));
    }
    return null;
  }

  /// 解析房间内某一集的直连播放地址。
  Future<AppPlayResult> resolvePlayUrl({
    required String vodId,
    required int playSource,
    required int playIndex,
  }) async {
    final token = await _token();
    return _api.play(
      await _base(),
      videoId: vodId,
      playSource: playSource,
      playIndex: playIndex,
      token: token,
    );
  }

  /// 房主移交房间。
  Future<WatchRoomInfo> transferHost(String code, String targetUserId) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const AppApiException('请先登录');
    }
    final data = await _api.watchTransferHost(
      await _base(),
      code,
      targetUserId: targetUserId,
      token: token,
    );
    return _roomFrom(data);
  }

  /// 房主移出成员。
  Future<WatchRoomInfo> kickMember(String code, String targetUserId) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const AppApiException('请先登录');
    }
    final data = await _api.watchKickMember(
      await _base(),
      code,
      targetUserId: targetUserId,
      token: token,
    );
    return _roomFrom(data);
  }

  /// 房主禁言/解除禁言成员。
  Future<WatchRoomInfo> muteMember(
    String code,
    String targetUserId, {
    required bool muted,
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const AppApiException('请先登录');
    }
    final data = await _api.watchMuteMember(
      await _base(),
      code,
      targetUserId: targetUserId,
      muted: muted,
      token: token,
    );
    return _roomFrom(data);
  }

  /// 房主修改房间设置。
  Future<WatchRoomInfo> updateSettings(
    String code, {
    bool? allowMemberControl,
    int? memberLimit,
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const AppApiException('请先登录');
    }
    final data = await _api.watchUpdateSettings(
      await _base(),
      code,
      allowMemberControl: allowMemberControl,
      memberLimit: memberLimit,
      token: token,
    );
    return _roomFrom(data);
  }

  WatchRoomInfo _roomFrom(Map<String, dynamic> data) {
    final room = data['room'];
    if (room is Map) {
      return WatchRoomInfo.fromJson(Map<String, dynamic>.from(room));
    }
    throw const AppApiException('房间数据异常');
  }
}

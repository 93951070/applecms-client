import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../models/watch_party.dart';
import '../providers/auth_provider.dart';
import '../services/watch_party_service.dart';
import '../widgets/video_player.dart';

/// 深色沉浸主题色板（对齐腾讯视频「一起看」的暗色氛围）。
class _WatchColors {
  _WatchColors._();

  static const Color bg = Color(0xFF0B0B0F);
  static const Color panel = Color(0xFF121218);
  static const Color card = Color(0xFF23232B);
  static const Color line = Color(0xFF26262F);
  static const Color text = Color(0xFFF5F5F7);
  static const Color text2 = Color(0xFFAEAEB2);
  static const Color text3 = Color(0xFF6E6E73);
}

/// 聊天时间线里的一行：真实消息或系统提示。
class _ChatLine {
  final bool system;
  final String userId;
  final String name;
  final String content;
  final int createdAt;

  const _ChatLine({
    this.system = false,
    this.userId = '',
    this.name = '',
    required this.content,
    required this.createdAt,
  });

  String get key => system
      ? 'sys|$createdAt|${content.hashCode}'
      : '$userId|$createdAt|$content';
}

/// 一起看房间页：服务器权威时间线 + 心跳纠偏。
class WatchRoomPage extends ConsumerStatefulWidget {
  final String code;
  final WatchRoomInfo? initialRoom;

  const WatchRoomPage({super.key, required this.code, this.initialRoom});

  @override
  ConsumerState<WatchRoomPage> createState() => _WatchRoomPageState();
}

class _WatchRoomPageState extends ConsumerState<WatchRoomPage> {
  static const _emojiSet = [
    '😀', '😄', '😍', '🤣', '😭', '😱', '👍', '👏',
    '🙌', '❤️', '🔥', '🎉', '🍿', '😂', '🤔', '😴',
  ];

  final GlobalKey<EchoVideoPlayerState> _playerKey =
      GlobalKey<EchoVideoPlayerState>();
  final TextEditingController _chatInput = TextEditingController();
  final ScrollController _chatScroll = ScrollController();

  WatchRoomInfo? _room;
  List<_ChatLine> _lines = [];
  final Set<String> _seenKeys = {};
  int _lastMessageAt = 0;

  Set<String> _knownMemberIds = {};
  Map<String, String> _memberNames = {};
  bool _membersInitialized = false;

  String? _playUrl;
  bool _loading = true;
  String? _error;
  bool _catchingUp = false;

  int _episode = 0;
  int _playSource = 0;
  double _initialPosition = 0;

  Timer? _timer;
  DateTime _lastSyncAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _leaving = false;
  late final WatchPartyService _service;

  @override
  void initState() {
    super.initState();
    _service = ref.read(watchPartyServiceProvider);
    _room = widget.initialRoom;
    if (_room != null) {
      _episode = _room!.episode;
      _playSource = _room!.playSource;
      _initialPosition = _room!.positionMs / 1000.0;
    }
    _bootstrap();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _chatInput.dispose();
    _chatScroll.dispose();
    _leaving = true;
    _service.leaveRoom(widget.code).ignore();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final room = await _service.joinRoom(widget.code);
      _episode = room.episode;
      _playSource = room.playSource;
      _initialPosition = room.positionMs / 1000.0;
      _updateRoom(room);
      if (room.vodId.isNotEmpty) {
        await _resolveUrl();
      }
      await _loadMessages();
      if (!mounted) return;
      setState(() => _loading = false);
      _timer = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('AppApiException: ', '');
      });
    }
  }

  Future<void> _resolveUrl() async {
    final room = _room;
    if (room == null || room.vodId.isEmpty) return;
    final result = await _service.resolvePlayUrl(
      vodId: room.vodId,
      playSource: _playSource,
      playIndex: _episode,
    );
    if (!mounted) return;
    if (result.success && result.hasAccess && (result.playUrl ?? '').isNotEmpty) {
      setState(() {
        _playUrl = result.playUrl;
        _error = null;
      });
    } else {
      setState(
        () => _error = result.message.isEmpty ? '暂时无法播放该内容' : result.message,
      );
    }
  }

  void _updateRoom(WatchRoomInfo room) {
    if (!mounted) return;
    setState(() {
      _syncMemberEvents(room);
      _room = room;
    });
  }

  /// 对比成员变化，插入「加入/离开房间」系统提示。
  void _syncMemberEvents(WatchRoomInfo room) {
    final ids = room.members.map((m) => m.userId).toSet();
    final names = <String, String>{
      for (final m in room.members)
        m.userId: m.nickName.isEmpty ? '观众' : m.nickName,
    };
    if (!_membersInitialized) {
      _knownMemberIds = ids;
      _memberNames = names;
      _membersInitialized = true;
      return;
    }
    for (final m in room.members) {
      if (!_knownMemberIds.contains(m.userId)) {
        _appendSystem('${names[m.userId]} 加入了房间');
      }
    }
    for (final id in _knownMemberIds) {
      if (!ids.contains(id)) {
        _appendSystem('${_memberNames[id] ?? '观众'} 离开了房间');
      }
    }
    _knownMemberIds = ids;
    _memberNames = names;
  }

  void _appendSystem(String content) {
    final line = _ChatLine(
      system: true,
      content: content,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (_seenKeys.add(line.key)) _lines.add(line);
  }

  void _addMessage(WatchChatMessage m) {
    final line = _ChatLine(
      userId: m.userId,
      name: m.nickName.isEmpty ? '观众' : m.nickName,
      content: m.content,
      createdAt: m.createdAt,
    );
    if (_seenKeys.add(line.key)) {
      _lines.add(line);
      if (m.createdAt > _lastMessageAt) _lastMessageAt = m.createdAt;
    }
  }

  Future<void> _loadMessages() async {
    final msgs = await _service.fetchMessages(widget.code, since: 0);
    if (!mounted) return;
    setState(() {
      _lines = [];
      _seenKeys.clear();
      _lastMessageAt = 0;
      for (final m in msgs) {
        _addMessage(m);
      }
    });
    _scrollChatToEnd();
  }

  Future<void> _refreshMessages() async {
    final since = _lastMessageAt <= 1 ? 0 : _lastMessageAt - 1;
    final msgs = await _service.fetchMessages(widget.code, since: since);
    if (msgs.isEmpty || !mounted) return;
    var changed = false;
    for (final m in msgs) {
      final before = _lines.length;
      _addMessage(m);
      if (_lines.length != before) changed = true;
    }
    if (changed) {
      setState(() {});
      _scrollChatToEnd();
    }
  }

  void _scrollChatToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(
          _chatScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _tick() async {
    final room = _room;
    if (room == null || _leaving) return;
    final player = _playerKey.currentState;
    final isControl = room.canControl;
    try {
      if (isControl && player != null) {
        final updated = await _service.updateTimeline(
          widget.code,
          paused: !player.isPlaying,
          positionMs: player.currentPosition.inMilliseconds,
          episode: _episode,
          playSource: _playSource,
        );
        _updateRoom(updated);
      } else {
        final updated =
            await _service.heartbeat(widget.code, buffering: false);
        if (!mounted) return;
        _updateRoom(updated);
        await _applyRemote(updated);
      }
      await _refreshMessages();
    } catch (_) {}
  }

  /// 成员侧按服务器时间线纠偏，偏差超过 1.5 秒才 seek。
  Future<void> _applyRemote(WatchRoomInfo room) async {
    if (room.episode != _episode) {
      _episode = room.episode;
      _playSource = room.playSource;
      _initialPosition = room.positionMs / 1000.0;
      await _resolveUrl();
      return;
    }
    final player = _playerKey.currentState;
    if (player == null || _playUrl == null) return;
    if (DateTime.now().difference(_lastSyncAt).inSeconds < 2) return;
    final target = Duration(milliseconds: room.positionMs);
    final drift = (player.currentPosition - target).inMilliseconds.abs();
    if (drift > 1500) {
      player.seekToPosition(target);
      _lastSyncAt = DateTime.now();
      _markCatchingUp();
    }
    if (room.paused && player.isPlaying) {
      player.forcePause();
    } else if (!room.paused && !player.isPlaying) {
      player.resumePlayback();
    }
  }

  void _markCatchingUp() {
    if (!mounted) return;
    setState(() => _catchingUp = true);
    Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _catchingUp = false);
    });
  }

  Future<void> _sendMessage() async {
    final content = _chatInput.text.trim();
    if (content.isEmpty) return;
    _chatInput.clear();
    try {
      final msg = await _service.sendMessage(widget.code, content);
      if (!mounted || msg == null) return;
      setState(() => _addMessage(msg));
      _scrollChatToEnd();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('AppApiException: ', '')),
          ),
        );
      }
    }
  }

  Future<void> _sendQuick(String emoji) async {
    try {
      final msg = await _service.sendMessage(widget.code, emoji);
      if (!mounted || msg == null) return;
      setState(() => _addMessage(msg));
      _scrollChatToEnd();
    } catch (_) {}
  }

  Future<void> _copyInvite(WatchRoomInfo room) async {
    await Clipboard.setData(
      ClipboardData(text: '我在一起看「${room.title}」，房间号 ${room.code}，一起来看吧'),
    );
    if (mounted) _toast('房间号 ${room.code} 已复制');
  }

  Future<void> _closeRoom() async {
    _timer?.cancel();
    _leaving = true;
    try {
      await _service.closeRoom(widget.code);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  void _showEmojiPicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
        decoration: BoxDecoration(
          color: _WatchColors.panel,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0x1FFFFFFF)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '发送表情',
              style: TextStyle(
                color: _WatchColors.text2,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _emojiSet
                  .map(
                    (e) => InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        Navigator.of(context).pop();
                        _sendQuick(e);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Text(e, style: const TextStyle(fontSize: 24)),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: _WatchColors.card,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    final myId = ref.watch(authProvider).user?.id ?? '';
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _WatchColors.bg,
        body: _loading
            ? const Center(
                child: CircularProgressIndicator(color: AppColors.pink))
            : room == null
                ? _buildError()
                : SafeArea(
                    child: Column(
                      children: [
                        _buildStage(room),
                        Expanded(child: _buildSocial(room, myId)),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_off_rounded,
              size: 42, color: _WatchColors.text3),
          const SizedBox(height: 12),
          Text(
            _error ?? '房间不存在或已结束',
            style: const TextStyle(color: _WatchColors.text2, fontSize: 14),
          ),
          const SizedBox(height: 18),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              backgroundColor: _WatchColors.card,
              padding:
                  const EdgeInsets.symmetric(horizontal: 30, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
            ),
            child: const Text(
              '返回',
              style: TextStyle(color: Colors.white, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 播放区 ====================

  Widget _buildStage(WatchRoomInfo room) {
    final width = MediaQuery.of(context).size.width;
    return SizedBox(
      width: width,
      height: width * 9 / 16,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Colors.black, child: _buildPlayer(room)),
          Positioned(top: 0, left: 0, right: 0, child: _buildTopBar(room)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildStageBottom(room),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayer(WatchRoomInfo room) {
    if (_playUrl == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error == null)
              const SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                    strokeWidth: 2.4, color: Colors.white54),
              )
            else
              const Icon(Icons.play_circle_outline_rounded,
                  size: 44, color: Colors.white38),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _error ?? '正在同步房主进度…',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }
    return EchoVideoPlayer(
      key: _playerKey,
      url: _playUrl!,
      title: room.title,
      initialPosition: _initialPosition,
      danmaku: const [],
      danmakuEnabled: false,
    );
  }

  Widget _buildTopBar(WatchRoomInfo room) {
    final online = room.members.where((m) => m.online).length;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 6, 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Colors.transparent],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _overlayIcon(
            Icons.arrow_back_ios_new_rounded,
            () => Navigator.maybePop(context),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.pink, AppColors.vipGoldDeep],
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '一起看',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        room.title.isEmpty ? '一起看' : room.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                GestureDetector(
                  onTap: () => _copyInvite(room),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '房间号 ${room.code}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.copy_rounded,
                          size: 11, color: Colors.white54),
                      const SizedBox(width: 8),
                      const Icon(Icons.circle,
                          size: 5, color: AppColors.scoreGreen),
                      const SizedBox(width: 3),
                      Text(
                        '$online 人在线',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _overlayIcon(
            Icons.person_add_alt_1_rounded,
            () => _copyInvite(room),
          ),
          if (room.isHost)
            _overlayIcon(Icons.close_rounded, _closeRoom),
        ],
      ),
    );
  }

  Widget _buildStageBottom(WatchRoomInfo room) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 22, 10, 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xB3000000), Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          _statusPill(room),
          const Spacer(),
          _miniMemberStack(room),
        ],
      ),
    );
  }

  Widget _overlayIcon(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      ),
    );
  }

  Widget _statusPill(WatchRoomInfo room) {
    final catching = _catchingUp;
    final Color color;
    final IconData icon;
    final String text;
    if (room.canControl) {
      color = AppColors.pink;
      icon = Icons.tune_rounded;
      text = room.paused ? '已暂停 · 你控制播放' : '播放中 · 你控制播放';
    } else if (catching) {
      color = AppColors.vipGold;
      icon = Icons.sync_rounded;
      text = '正在追赶房主…';
    } else if (room.paused) {
      color = Colors.white70;
      icon = Icons.pause_circle_filled_rounded;
      text = '房主已暂停播放';
    } else {
      color = AppColors.scoreGreen;
      icon = Icons.people_alt_rounded;
      text = '跟随房主播放中';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniMemberStack(WatchRoomInfo room) {
    final members = room.members.take(4).toList();
    if (members.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 28.0 + (members.length - 1) * 20,
          height: 28,
          child: Stack(
            children: [
              for (var i = 0; i < members.length; i++)
                Positioned(
                  left: i * 20.0,
                  child: _avatar(members[i], size: 28, bordered: true),
                ),
            ],
          ),
        ),
        if (room.members.length > members.length)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              '+${room.members.length - members.length}',
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
      ],
    );
  }

  // ==================== 社交区 ====================

  Widget _buildSocial(WatchRoomInfo room, String myId) {
    return Container(
      decoration: const BoxDecoration(
        color: _WatchColors.panel,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: Color(0x14FFFFFF))),
      ),
      child: Column(
        children: [
          _buildMembersStrip(room),
          const Divider(height: 1, color: _WatchColors.line),
          Expanded(child: _buildChat(myId)),
          _buildInput(),
        ],
      ),
    );
  }

  Widget _buildMembersStrip(WatchRoomInfo room) {
    final online = room.members.where((m) => m.online).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 10, 9),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: AppColors.scoreGreen,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            '一起看',
            style: TextStyle(
              color: AppColors.pink,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$online/${room.memberLimit} 人在线',
            style: const TextStyle(fontSize: 11.5, color: _WatchColors.text3),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 28,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: room.members.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) => _avatar(room.members[i], size: 28),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _inviteChip(() => _copyInvite(room)),
        ],
      ),
    );
  }

  Widget _inviteChip(VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.pink.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.pink.withValues(alpha: 0.4)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 14, color: AppColors.pink),
            SizedBox(width: 2),
            Text(
              '邀请',
              style: TextStyle(
                color: AppColors.pink,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(WatchMemberInfo m, {double size = 32, bool bordered = false}) {
    final name = m.nickName.isEmpty ? '观众' : m.nickName;
    final color = m.isHost
        ? AppColors.vipGold
        : (m.online ? AppColors.auroraBlue : _WatchColors.text3);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.18),
              border: Border.all(
                color: m.isHost
                    ? AppColors.vipGold
                    : (bordered ? Colors.white : Colors.transparent),
                width: m.isHost ? 1.6 : (bordered ? 1.5 : 0),
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              name.characters.first,
              style: TextStyle(
                fontSize: size * 0.42,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
          if (m.isHost)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.all(1.5),
                decoration: const BoxDecoration(
                  color: AppColors.vipGoldDeep,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.star_rounded,
                    size: 9, color: Colors.white),
              ),
            ),
          if (m.buffering && !m.isHost)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: AppColors.vipGold,
                  shape: BoxShape.circle,
                  border: Border.all(color: _WatchColors.panel, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildChat(String myId) {
    if (_lines.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline_rounded,
                size: 30, color: _WatchColors.text3.withValues(alpha: 0.7)),
            const SizedBox(height: 8),
            const Text(
              '还没有消息，和大家打个招呼吧',
              style: TextStyle(fontSize: 12.5, color: _WatchColors.text3),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _chatScroll,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      itemCount: _lines.length,
      itemBuilder: (context, index) => _buildLine(_lines[index], myId),
    );
  }

  Widget _buildLine(_ChatLine line, String myId) {
    if (line.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              line.content,
              style: const TextStyle(
                fontSize: 11.5,
                color: _WatchColors.text3,
              ),
            ),
          ),
        ),
      );
    }
    final mine = myId.isNotEmpty && line.userId == myId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine) ...[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.auroraBlue.withValues(alpha: 0.18),
              ),
              alignment: Alignment.center,
              child: Text(
                line.name.characters.first,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.auroraBlue,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 3, left: 2, right: 2),
                  child: Text(
                    mine
                        ? _formatTime(line.createdAt)
                        : '${line.name}  ${_formatTime(line.createdAt)}',
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: _WatchColors.text3,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: mine ? AppColors.pink : _WatchColors.card,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(mine ? 16 : 4),
                      bottomRight: Radius.circular(mine ? 4 : 16),
                    ),
                    border: mine
                        ? null
                        : Border.all(color: const Color(0x14FFFFFF)),
                  ),
                  child: Text(
                    line.content,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.35,
                      color: _WatchColors.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (mine) const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildInput() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        child: Row(
          children: [
            _overlayIcon(Icons.emoji_emotions_outlined, _showEmojiPicker),
            const SizedBox(width: 4),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: _WatchColors.card,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: const Color(0x12FFFFFF)),
                ),
                child: TextField(
                  controller: _chatInput,
                  style: const TextStyle(
                      color: _WatchColors.text, fontSize: 14),
                  cursorColor: AppColors.pink,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendMessage(),
                  decoration: const InputDecoration(
                    hintText: '和大家一起聊聊…',
                    hintStyle: TextStyle(
                        fontSize: 13, color: _WatchColors.text3),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _sendMessage,
              child: Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [AppColors.pink, AppColors.pinkDeep],
                  ),
                ),
                child: const Icon(Icons.arrow_upward_rounded,
                    size: 20, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

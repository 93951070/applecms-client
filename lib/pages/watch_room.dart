import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../models/watch_party.dart';
import '../services/watch_party_service.dart';
import '../widgets/video_player.dart';
import '../widgets/zen_ui.dart';

/// 一起看房间页：服务器权威时间线 + 心跳纠偏。
class WatchRoomPage extends ConsumerStatefulWidget {
  final String code;
  final WatchRoomInfo? initialRoom;

  const WatchRoomPage({super.key, required this.code, this.initialRoom});

  @override
  ConsumerState<WatchRoomPage> createState() => _WatchRoomPageState();
}

class _WatchRoomPageState extends ConsumerState<WatchRoomPage> {
  final GlobalKey<EchoVideoPlayerState> _playerKey =
      GlobalKey<EchoVideoPlayerState>();
  final TextEditingController _chatInput = TextEditingController();
  final ScrollController _chatScroll = ScrollController();

  WatchRoomInfo? _room;
  List<WatchChatMessage> _messages = const [];
  String? _playUrl;
  bool _loading = true;
  String? _error;

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
      final service = _service;
      final room = await service.joinRoom(widget.code);
      _room = room;
      _episode = room.episode;
      _playSource = room.playSource;
      _initialPosition = room.positionMs / 1000.0;
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
      setState(() => _error = result.message.isEmpty ? '暂时无法播放该内容' : result.message);
    }
  }

  Future<void> _loadMessages() async {
    try {
      final msgs = await _service.fetchMessages(widget.code, since: 0);
      if (!mounted) return;
      setState(() => _messages = msgs);
      _scrollChatToEnd();
    } catch (_) {}
  }

  Future<void> _refreshMessages() async {
    final last = _messages.isEmpty ? 0 : _messages.last.createdAt - 1;
    try {
      final msgs = await _service.fetchMessages(widget.code, since: last);
      if (!mounted || msgs.isEmpty) return;
      setState(() => _messages = [..._messages, ...msgs]);
      _scrollChatToEnd();
    } catch (_) {}
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
        if (mounted) setState(() => _room = updated);
      } else {
        final updated = await _service.heartbeat(widget.code, buffering: false);
        if (!mounted) return;
        setState(() => _room = updated);
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
    }
    if (room.paused && player.isPlaying) {
      player.forcePause();
    } else if (!room.paused && !player.isPlaying) {
      player.resumePlayback();
    }
  }

  Future<void> _sendMessage() async {
    final content = _chatInput.text.trim();
    if (content.isEmpty) return;
    _chatInput.clear();
    try {
      final msg = await _service.sendMessage(widget.code, content);
      if (!mounted || msg == null) return;
      setState(() => _messages = [..._messages, msg]);
      _scrollChatToEnd();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('AppApiException: ', ''))),
        );
      }
    }
  }

  Future<void> _closeRoom() async {
    _timer?.cancel();
    _leaving = true;
    try {
      await _service.closeRoom(widget.code);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    return ZenScaffold(
      appBar: AppBar(
        title: Text(room == null ? '一起看' : '一起看 · ${room.code}'),
        actions: [
          if (room?.isHost == true)
            IconButton(
              tooltip: '解散房间',
              onPressed: _closeRoom,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : room == null
              ? _buildError()
              : Column(
                  children: [
                    _buildVideoArea(room),
                    _buildRoomBar(room),
                    _buildMembers(room),
                    _buildChatList(),
                    _buildChatInput(),
                  ],
                ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _error ?? '房间不存在或已结束',
          style: TextStyle(color: Theme.of(context).colorScheme.secondary),
        ),
      ),
    );
  }

  Widget _buildVideoArea(WatchRoomInfo room) {
    if (_playUrl == null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: Text(
            _error ?? '正在准备播放…',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      );
    }
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: EchoVideoPlayer(
        key: _playerKey,
        url: _playUrl!,
        title: room.title,
        initialPosition: _initialPosition,
        danmaku: const [],
        danmakuEnabled: false,
      ),
    );
  }

  Widget _buildRoomBar(WatchRoomInfo room) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              room.title.isEmpty ? '未命名影片' : room.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.lightText,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (room.paused ? AppColors.lightText3 : AppColors.scoreGreen)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              room.paused ? '已暂停' : '同步播放中',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: room.paused ? AppColors.lightText2 : AppColors.scoreGreen,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMembers(WatchRoomInfo room) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: room.members.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final m = room.members[index];
          final color = m.online ? AppColors.auroraBlue : AppColors.lightText3;
          return Chip(
            visualDensity: VisualDensity.compact,
            avatar: CircleAvatar(
              radius: 10,
              backgroundColor: color.withValues(alpha: 0.2),
              child: Icon(
                m.isHost ? Icons.star_rounded : Icons.person_rounded,
                size: 12,
                color: color,
              ),
            ),
            label: Text(
              m.nickName.isEmpty ? '观众' : m.nickName,
              style: const TextStyle(fontSize: 12),
            ),
          );
        },
      ),
    );
  }

  Widget _buildChatList() {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(16),
        ),
        child: _messages.isEmpty
            ? Center(
                child: Text(
                  '还没有消息，和大家打个招呼吧',
                  style: TextStyle(fontSize: 12, color: AppColors.lightText3),
                ),
              )
            : ListView.builder(
                controller: _chatScroll,
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final m = _messages[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.lightText,
                        ),
                        children: [
                          TextSpan(
                            text: '${m.nickName.isEmpty ? "观众" : m.nickName}：',
                            style: const TextStyle(
                              color: AppColors.pink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextSpan(text: m.content),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _buildChatInput() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _chatInput,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                decoration: InputDecoration(
                  hintText: '说点什么…',
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.7),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ZenButton(
              onPressed: _sendMessage,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: const Text('发送'),
            ),
          ],
        ),
      ),
    );
  }
}

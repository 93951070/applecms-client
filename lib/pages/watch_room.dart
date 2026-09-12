import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/share_utils.dart';
import '../core/theme.dart';
import '../models/watch_party.dart';
import '../providers/auth_provider.dart';
import '../services/config_service.dart';
import '../services/watch_party_service.dart';
import '../widgets/video_player.dart';

/// 深色沉浸主题色板（对齐腾讯视频「一起看」的暗色氛围）。
class _WatchColors {
  _WatchColors._();

  static const Color bg = Color(0xFF0B0B0F);
  static const Color panel = Color(0xFF15151B);
  static const Color panel2 = Color(0xFF1C1C24);
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
  final String portrait;
  final String content;
  final int createdAt;

  const _ChatLine({
    this.system = false,
    this.userId = '',
    this.name = '',
    this.portrait = '',
    required this.content,
    required this.createdAt,
  });

  String get key => system
      ? 'sys|$createdAt|${content.hashCode}'
      : '$userId|$createdAt|$content';
}

/// 一起看房间页：横屏沉浸、服务器权威时间线 + 心跳纠偏。
class WatchRoomPage extends ConsumerStatefulWidget {
  final String code;
  final WatchRoomInfo? initialRoom;

  const WatchRoomPage({super.key, required this.code, this.initialRoom});

  @override
  ConsumerState<WatchRoomPage> createState() => _WatchRoomPageState();
}

class _WatchRoomPageState extends ConsumerState<WatchRoomPage>
    with WidgetsBindingObserver {
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
  bool _hasMoreHistory = false;
  bool _loadingHistory = false;

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
  late final String _myId;

  bool _chatVisible = true;
  int _unread = 0;
  int _tickFails = 0;
  bool _reconnecting = false;
  bool _ended = false;
  bool _busy = false;
  String? _endReason;
  bool _removedHandled = false;
  String _mediaBase = '';

  @override
  void initState() {
    super.initState();
    _service = ref.read(watchPartyServiceProvider);
    _myId = ref.read(authProvider).user?.id ?? '';
    _loadMediaBase();
    _room = widget.initialRoom;
    if (_room != null) {
      _episode = _room!.episode;
      _playSource = _room!.playSource;
      _initialPosition = _room!.positionMs / 1000.0;
    }
    WidgetsBinding.instance.addObserver(this);
    _enterImmersive();
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _chatInput.dispose();
    _chatScroll.dispose();
    _leaving = true;
    _service.leaveRoom(widget.code).ignore();
    _restoreSystemUi();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _enterImmersive();
      if (!_loading && !_ended) _tick();
    }
  }

  void _enterImmersive() {
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
  }

  void _restoreSystemUi() {
    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
    try {
      final result = await _service.resolvePlayUrl(
        vodId: room.vodId,
        playSource: _playSource,
        playIndex: _episode,
      );
      if (!mounted) return;
      if (result.success &&
          result.hasAccess &&
          (result.playUrl ?? '').isNotEmpty) {
        setState(() {
          _playUrl = result.playUrl;
          _error = null;
        });
      } else {
        setState(
          () => _error = result.message.isEmpty ? '暂时无法播放该内容' : result.message,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = e.toString().replaceFirst('AppApiException: ', ''),
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
      system: m.system,
      userId: m.userId,
      name: m.nickName.isEmpty ? '观众' : m.nickName,
      portrait: m.portrait,
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
      _hasMoreHistory = msgs.length >= 50;
    });
    _scrollChatToEnd();
  }

  Future<void> _refreshMessages() async {
    final since = _lastMessageAt <= 1 ? 0 : _lastMessageAt - 1;
    final msgs = await _service.fetchMessages(widget.code, since: since);
    if (msgs.isEmpty || !mounted) return;
    var changed = false;
    var incoming = 0;
    for (final m in msgs) {
      final before = _lines.length;
      _addMessage(m);
      if (_lines.length != before) {
        changed = true;
        if (m.userId != _myId) incoming++;
      }
    }
    if (changed) {
      if (!_chatVisible && incoming > 0) _unread += incoming;
      setState(() {});
      if (_chatVisible) _scrollChatToEnd();
    }
  }

  /// 上拉加载更早的聊天记录。
  Future<void> _loadOlderMessages() async {
    if (_loadingHistory || !_hasMoreHistory || _lines.isEmpty) return;
    setState(() => _loadingHistory = true);
    final oldest = _lines.first.createdAt;
    final msgs =
        await _service.fetchMessages(widget.code, before: oldest);
    if (!mounted) return;
    final older = <_ChatLine>[];
    for (final m in msgs) {
      final line = _ChatLine(
        system: m.system,
        userId: m.userId,
        name: m.nickName.isEmpty ? '观众' : m.nickName,
        portrait: m.portrait,
        content: m.content,
        createdAt: m.createdAt,
      );
      if (_seenKeys.add(line.key)) older.add(line);
    }
    setState(() {
      _lines.insertAll(0, older);
      _hasMoreHistory = msgs.length >= 50;
      _loadingHistory = false;
    });
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
    if (room == null || _leaving || _ended) return;
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
          buffering: player.isBuffering,
        );
        _onTickSuccess();
        _updateRoom(updated);
      } else {
        final updated = await _service.heartbeat(
          widget.code,
          buffering: player?.isBuffering ?? false,
        );
        if (!mounted) return;
        _onTickSuccess();
        _updateRoom(updated);
        await _applyRemote(updated);
      }
      await _refreshMessages();
    } catch (e) {
      _onTickError(e.toString());
    }
  }

  void _onTickSuccess() {
    if (_tickFails != 0 || _reconnecting) {
      _tickFails = 0;
      if (mounted) setState(() => _reconnecting = false);
    }
  }

  void _onTickError(String raw) {
    final text = raw.replaceFirst('AppApiException: ', '');
    if (text.contains('已被移出')) {
      _handleRemoved(text);
      return;
    }
    if (text.contains('已被关闭') ||
        text.contains('房间不存在') ||
        text.contains('已结束')) {
      _handleEnded(reason: _extractReason(text));
      return;
    }
    _tickFails++;
    if (_tickFails >= 4 && mounted && !_reconnecting) {
      setState(() => _reconnecting = true);
    }
  }

  /// 从服务端错误文案中取出「：」之后的具体原因。
  static String? _extractReason(String text) {
    final idx = text.indexOf('：');
    if (idx < 0 || idx + 1 >= text.length) return null;
    final reason = text.substring(idx + 1).trim();
    return reason.isEmpty ? null : reason;
  }

  void _handleEnded({String? reason}) {
    if (_ended || !mounted) return;
    _ended = true;
    _endReason = reason;
    _timer?.cancel();
    setState(() {});
  }

  /// 被管理员/房主移出：弹窗说明原因，确认后退出房间。
  void _handleRemoved(String text) {
    if (_removedHandled || !mounted) return;
    _removedHandled = true;
    _timer?.cancel();
    final reason = _extractReason(text) ?? '违反房间规定';
    final navigator = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _WatchColors.panel2,
        title: const Text('你已被移出房间',
            style: TextStyle(color: _WatchColors.text, fontSize: 16)),
        content: Text('原因：$reason',
            style: const TextStyle(color: _WatchColors.text2, fontSize: 13.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('返回', style: TextStyle(color: AppColors.pink)),
          ),
        ],
      ),
    ).then((_) {
      if (mounted) navigator.pop();
    });
  }

  /// 成员侧按服务器时间线纠偏，偏差超过 1.5 秒才 seek。
  Future<void> _applyRemote(WatchRoomInfo room) async {
    final player = _playerKey.currentState;
    if (room.episode != _episode) {
      _episode = room.episode;
      _playSource = room.playSource;
      _initialPosition = room.positionMs / 1000.0;
      await _resolveUrl();
      return;
    }
    if (player == null || _playUrl == null) return;
    if (room.stallHold && !room.isHost) {
      if (player.isPlaying) player.forcePause();
      return;
    }
    if (DateTime.now().difference(_lastSyncAt).inSeconds < 2) {
      if (room.paused && player.isPlaying) player.forcePause();
      return;
    }
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
      _toast(e.toString().replaceFirst('AppApiException: ', ''));
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
      ClipboardData(
        text: '我在一起看「${room.title}」，房间号 ${room.code}，一起来看吧',
      ),
    );
    if (mounted) _toast('房间号 ${room.code} 已复制');
  }

  Future<void> _shareInvite(WatchRoomInfo room) async {
    await shareText(
      context,
      '我在一起看「${room.title}」，房间号 ${room.code}，打开 EchoTV 输入房间号一起来看吧',
      subject: '一起看邀请',
    );
  }

  Future<void> _closeRoom() async {
    final ok = await _confirm('解散房间', '解散后所有成员将退出，确定解散吗？', '解散');
    if (!ok) return;
    _timer?.cancel();
    _leaving = true;
    try {
      await _service.closeRoom(widget.code);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _WatchColors.panel2,
        title: Text(title,
            style: const TextStyle(color: _WatchColors.text, fontSize: 16)),
        content: Text(message,
            style: const TextStyle(color: _WatchColors.text2, fontSize: 13.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消',
                style: TextStyle(color: _WatchColors.text2)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(action, style: const TextStyle(color: AppColors.pink)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _runBusy(Future<void> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await task();
    } catch (e) {
      _toast(e.toString().replaceFirst('AppApiException: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _transferHost(WatchRoomInfo room, WatchMemberInfo m) async {
    final ok = await _confirm('移交房主', '将房主移交给「${_displayName(m)}」？', '移交');
    if (!ok) return;
    await _runBusy(() async {
      final updated =
          await _service.transferHost(widget.code, m.userId);
      if (!mounted) return;
      Navigator.of(context).pop();
      _updateRoom(updated);
      _toast('已移交房主');
    });
  }

  Future<void> _kickMember(WatchRoomInfo room, WatchMemberInfo m) async {
    final ok = await _confirm('移出成员', '将「${_displayName(m)}」移出房间？', '移出');
    if (!ok) return;
    await _runBusy(() async {
      final updated = await _service.kickMember(widget.code, m.userId);
      if (!mounted) return;
      Navigator.of(context).pop();
      _updateRoom(updated);
      _toast('已移出成员');
    });
  }

  Future<void> _toggleMute(WatchRoomInfo room, WatchMemberInfo m) async {
    await _runBusy(() async {
      final updated = await _service.muteMember(
        widget.code,
        m.userId,
        muted: !m.muted,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      _updateRoom(updated);
      _toast(m.muted ? '已解除禁言' : '已禁言');
    });
  }

  Future<void> _changeEpisode(int delta) async {
    if (_busy) return;
    final room = _room;
    if (room == null || !room.canControl) return;
    final next = _episode + delta;
    if (next < 0) return;
    final prevEpisode = _episode;
    final prevSource = _playSource;
    setState(() {
      _episode = next;
      _playSource = room.playSource;
    });
    final result = await _service.resolvePlayUrl(
      vodId: room.vodId,
      playSource: _playSource,
      playIndex: _episode,
    );
    if (!result.success ||
        !result.hasAccess ||
        (result.playUrl ?? '').isEmpty) {
      if (!mounted) return;
      setState(() {
        _episode = prevEpisode;
        _playSource = prevSource;
      });
      _toast(delta > 0 ? '没有下一集了' : '已经是第一集');
      return;
    }
    if (!mounted) return;
    setState(() {
      _playUrl = result.playUrl;
      _initialPosition = 0;
      _error = null;
    });
    _playerKey.currentState?.resumePlayback();
    _tick();
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

  void _showMembers() {
    final room = _room;
    if (room == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _membersSheet(room),
    );
  }

  void _showSettings() {
    final room = _room;
    if (room == null || !room.isHost) return;
    var allowControl = room.allowMemberControl;
    var limit = room.memberLimit;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          margin: const EdgeInsets.all(14),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          decoration: BoxDecoration(
            color: _WatchColors.panel,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0x1FFFFFFF)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('房间设置',
                  style: TextStyle(
                      color: _WatchColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: allowControl,
                activeThumbColor: AppColors.pink,
                title: const Text('允许成员控制播放',
                    style: TextStyle(color: _WatchColors.text, fontSize: 13.5)),
                subtitle: const Text('开启后成员也可暂停、拖动进度',
                    style: TextStyle(color: _WatchColors.text3, fontSize: 11.5)),
                onChanged: (v) => setSheet(() => allowControl = v),
              ),
              const Divider(height: 18, color: _WatchColors.line),
              Row(
                children: [
                  const Expanded(
                    child: Text('房间人数上限',
                        style: TextStyle(
                            color: _WatchColors.text, fontSize: 13.5)),
                  ),
                  IconButton(
                    onPressed: limit > 2
                        ? () => setSheet(() => limit--)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline_rounded,
                        color: _WatchColors.text2),
                  ),
                  Text('$limit',
                      style: const TextStyle(
                          color: _WatchColors.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  IconButton(
                    onPressed: limit < 50 ? () => setSheet(() => limit++) : null,
                    icon: const Icon(Icons.add_circle_outline_rounded,
                        color: _WatchColors.text2),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.pink,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24)),
                  ),
                  onPressed: () => _runBusy(() async {
                    final updated = await _service.updateSettings(
                      widget.code,
                      allowMemberControl: allowControl,
                      memberLimit: limit,
                    );
                    if (!mounted) return;
                    Navigator.of(ctx).pop();
                    _updateRoom(updated);
                    _toast('房间设置已更新');
                  }),
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _membersSheet(WatchRoomInfo room) {
    return Container(
      margin: const EdgeInsets.all(14),
      constraints: const BoxConstraints(maxHeight: 340),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      decoration: BoxDecoration(
        color: _WatchColors.panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0x1FFFFFFF)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('房间成员',
                  style: TextStyle(
                      color: _WatchColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Text('${room.members.length}/${room.memberLimit}',
                  style: const TextStyle(
                      color: _WatchColors.text3, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: room.members.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 14, color: _WatchColors.line),
              itemBuilder: (ctx, i) {
                final m = room.members[i];
                final isSelf = m.userId == _myId;
                return Row(
                  children: [
                    _avatar(m, size: 34, bordered: false),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  _displayName(m),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: _WatchColors.text, fontSize: 13.5),
                                ),
                              ),
                              if (m.isHost)
                                const Padding(
                                  padding: EdgeInsets.only(left: 6),
                                  child: _Badge(text: '房主', color: AppColors.pink),
                                ),
                              if (m.muted)
                                const Padding(
                                  padding: EdgeInsets.only(left: 4),
                                  child: Icon(Icons.mic_off_rounded,
                                      size: 13, color: _WatchColors.text3),
                                ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            m.buffering
                                ? '缓冲中…'
                                : (m.online ? '在线' : '离线'),
                            style: TextStyle(
                              color: m.buffering
                                  ? AppColors.vipGold
                                  : _WatchColors.text3,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (room.isHost && !isSelf && !m.isHost) ...[
                      _memberAction(
                        icon: Icons.swap_horiz_rounded,
                        tip: '移交',
                        onTap: () => _transferHost(room, m),
                      ),
                      _memberAction(
                        icon: m.muted
                            ? Icons.volume_up_rounded
                            : Icons.mic_off_rounded,
                        tip: m.muted ? '解除' : '禁言',
                        onTap: () => _toggleMute(room, m),
                      ),
                      _memberAction(
                        icon: Icons.person_remove_alt_1_rounded,
                        tip: '移出',
                        color: const Color(0xFFFF5B5B),
                        onTap: () => _kickMember(room, m),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _memberAction({
    required IconData icon,
    required String tip,
    required VoidCallback onTap,
    Color color = _WatchColors.text2,
  }) {
    return Tooltip(
      message: tip,
      child: IconButton(
        onPressed: _busy ? null : onTap,
        icon: Icon(icon, size: 19, color: color),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Future<void> _openChat() async {
    if (mounted) setState(() => _unread = 0);
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

  String _displayName(WatchMemberInfo m) =>
      m.nickName.isEmpty ? '观众' : m.nickName;

  @override
  Widget build(BuildContext context) {
    final room = _room;
    return PopScope(
      canPop: _chatVisible || _room == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _chatVisible) {
          if (mounted) setState(() => _chatVisible = false);
        } else if (didPop) {
          _restoreSystemUi();
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          resizeToAvoidBottomInset: true,
          backgroundColor: _WatchColors.bg,
          body: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.pink))
              : room == null
                  ? _buildError()
                  : _buildRoom(room),
        ),
      ),
    );
  }

  Widget _buildError() {
    final ended = _ended;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_off_rounded,
              size: 42, color: _WatchColors.text3),
          const SizedBox(height: 12),
          Text(
            ended
                ? (_endReason == null ? '房间已结束' : '房间已结束：${_endReason!}')
                : (_error ?? '房间不存在或已结束'),
            textAlign: TextAlign.center,
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
            child: const Text('返回',
                style: TextStyle(color: Colors.white, fontSize: 13.5)),
          ),
        ],
      ),
    );
  }

  // ==================== 主布局 ====================

  Widget _buildRoom(WatchRoomInfo room) {
    final size = MediaQuery.sizeOf(context);
    final landscape = size.width >= size.height;
    final stage = Stack(
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
        if (_ended) _buildEndedOverlay(),
      ],
    );
    if (!landscape) {
      return Column(
        children: [
          SizedBox(height: size.width * 9 / 16, child: stage),
          if (_chatVisible) Expanded(child: _buildSocial(room)),
        ],
      );
    }
    final panelWidth = _chatVisible
        ? (size.width * 0.36).clamp(280.0, 380.0).toDouble()
        : 0.0;
    return Row(
      children: [
        Expanded(
          flex: 1,
          // 点击视频区域自动收起右侧消息面板；用 Listener 不拦截播放器手势。
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) {
              if (_chatVisible) setState(() => _chatVisible = false);
            },
            child: stage,
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          width: panelWidth,
          child: panelWidth <= 0.5
              ? const SizedBox.shrink()
              : _buildSocial(room),
        ),
      ],
    );
  }

  Widget _buildEndedOverlay() {
    return Positioned.fill(
      child: Container(
        color: const Color(0xCC000000),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.emoji_emotions_outlined,
                size: 40, color: Colors.white70),
            const SizedBox(height: 12),
            const Text('房间已结束',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            if (_endReason != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text('原因：${_endReason!}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: _WatchColors.text2, fontSize: 12.5)),
              ),
            ],
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                backgroundColor: _WatchColors.card,
                padding:
                    const EdgeInsets.symmetric(horizontal: 30, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22)),
              ),
              child: const Text('返回',
                  style: TextStyle(color: Colors.white, fontSize: 13.5)),
            ),
          ],
        ),
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
      showDanmakuControl: false,
      showSettingsControl: false,
      showFullscreenControl: false,
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
        crossAxisAlignment: CrossAxisAlignment.center,
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
                      Text('$online 人在线',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11)),
                      const SizedBox(width: 10),
                      Flexible(child: _statusPill(room)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _overlayIcon(Icons.ios_share_rounded, () => _shareInvite(room)),
          _overlayIcon(Icons.people_alt_rounded, _showMembers),
          if (room.isHost)
            _overlayIcon(Icons.tune_rounded, _showSettings),
          if (room.isHost) _overlayIcon(Icons.close_rounded, _closeRoom),
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
          if (room.canControl) ...[
            _overlayIcon(Icons.skip_previous_rounded,
                () => _changeEpisode(-1)),
            _overlayIcon(Icons.skip_next_rounded, () => _changeEpisode(1)),
          ],
          const Spacer(),
          if (!_chatVisible)
            Stack(
              clipBehavior: Clip.none,
              children: [
                _overlayIcon(Icons.chat_bubble_rounded, () {
                  setState(() => _chatVisible = true);
                  _openChat();
                }),
                if (_unread > 0)
                  Positioned(
                    right: 2,
                    top: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.pink,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _unread > 99 ? '99+' : '$_unread',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
              ],
            )
          else
            _overlayIcon(Icons.keyboard_arrow_right_rounded,
                () => setState(() => _chatVisible = false)),
          const SizedBox(width: 4),
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
    if (_reconnecting) {
      color = AppColors.vipGold;
      icon = Icons.wifi_tethering_error_rounded;
      text = '连接不稳定，正在重连…';
    } else if (room.stallHold && !room.isHost) {
      color = AppColors.vipGold;
      icon = Icons.hourglass_bottom_rounded;
      text = '房主缓冲中，已暂停等待…';
    } else if (room.canControl) {
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
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
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

  Widget _buildSocial(WatchRoomInfo room) {
    return Container(
      decoration: const BoxDecoration(
        color: _WatchColors.panel,
        border: Border(left: BorderSide(color: Color(0x14FFFFFF))),
      ),
      child: Column(
        children: [
          _buildPanelHeader(room),
          const Divider(height: 1, color: _WatchColors.line),
          Expanded(child: _buildChat()),
          _buildInput(room),
        ],
      ),
    );
  }

  Widget _buildPanelHeader(WatchRoomInfo room) {
    final online = room.members.where((m) => m.online).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 8),
      child: Row(
        children: [
          const Text('聊天',
              style: TextStyle(
                  color: _WatchColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          const Icon(Icons.circle, size: 6, color: AppColors.scoreGreen),
          const SizedBox(width: 4),
          Text('$online 人在线',
              style: const TextStyle(color: _WatchColors.text2, fontSize: 11.5)),
          const Spacer(),
          IconButton(
            onPressed: () => setState(() => _chatVisible = false),
            icon: const Icon(Icons.keyboard_arrow_right_rounded,
                color: _WatchColors.text2, size: 22),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildChat() {
    if (_lines.isEmpty) {
      return const Center(
        child: Text('还没有消息，来说点什么吧',
            style: TextStyle(color: _WatchColors.text3, fontSize: 12.5)),
      );
    }
    return ListView.builder(
      controller: _chatScroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      itemCount: _lines.length + 1,
      itemBuilder: (ctx, i) {
        if (i == 0) {
          if (!_hasMoreHistory) return const SizedBox(height: 2);
          return Center(
            child: TextButton(
              onPressed: _loadingHistory ? null : _loadOlderMessages,
              child: Text(
                _loadingHistory ? '加载中…' : '查看更早的消息',
                style: const TextStyle(
                    color: _WatchColors.text2, fontSize: 11.5),
              ),
            ),
          );
        }
        final line = _lines[i - 1];
        if (line.system) return _systemLine(line);
        return _messageLine(line);
      },
    );
  }

  Widget _systemLine(_ChatLine line) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            line.content,
            style: const TextStyle(color: _WatchColors.text3, fontSize: 11),
          ),
        ),
      ),
    );
  }

  Widget _messageLine(_ChatLine line) {
    final mine = line.userId == _myId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!mine) ...[
            _letterAvatar(line.name, size: 28, portrait: line.portrait),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!mine)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      line.name,
                      style: const TextStyle(
                          color: _WatchColors.text3, fontSize: 11),
                    ),
                  ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    color: mine
                        ? AppColors.pink
                        : _WatchColors.panel2,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    line.content,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13.5, height: 1.3),
                  ),
                ),
              ],
            ),
          ),
          if (mine) const SizedBox(width: 2),
        ],
      ),
    );
  }

  Widget _buildInput(WatchRoomInfo room) {
    final muted = !room.isHost &&
        room.members.any((m) => m.userId == _myId && m.muted);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _WatchColors.line)),
      ),
      child: muted
          ? Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              alignment: Alignment.center,
              child: const Text(
                '你已被房主禁言',
                style: TextStyle(color: _WatchColors.text3, fontSize: 12.5),
              ),
            )
          : Row(
              children: [
                IconButton(
                  onPressed: _showEmojiPicker,
                  icon: const Icon(Icons.emoji_emotions_outlined,
                      color: _WatchColors.text2, size: 22),
                  visualDensity: VisualDensity.compact,
                ),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: _WatchColors.panel2,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: TextField(
                      controller: _chatInput,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      style: const TextStyle(
                          color: _WatchColors.text, fontSize: 13.5),
                      decoration: const InputDecoration(
                        hintText: '说点什么…',
                        hintStyle: TextStyle(
                            color: _WatchColors.text3, fontSize: 13),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: _sendMessage,
                  icon: const Icon(Icons.send_rounded,
                      color: AppColors.pink, size: 20),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
    );
  }

  // ==================== 头像 ====================

  Widget _avatar(WatchMemberInfo m, {required double size, bool bordered = true}) {
    final name = _displayName(m);
    final url = _absoluteMedia(m.portrait);
    final border = bordered
        ? Border.all(color: Colors.black.withValues(alpha: 0.5), width: 1.5)
        : null;
    if (url.isNotEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: border,
          image: DecorationImage(image: NetworkImage(url), fit: BoxFit.cover),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _colorFor(name),
        border: border,
      ),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '?' : name.characters.first,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _letterAvatar(String name, {required double size, String portrait = ''}) {
    final url = _absoluteMedia(portrait);
    if (url.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _letterAvatarBox(name, size),
        ),
      );
    }
    return _letterAvatarBox(name, size);
  }

  Widget _letterAvatarBox(String name, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: _colorFor(name)),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '?' : name.characters.first,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _absoluteMedia(String path) {
    final p = path.trim();
    if (p.isEmpty) return p;
    if (p.startsWith('http://') || p.startsWith('https://')) return p;
    if (p.startsWith('/') && _mediaBase.isNotEmpty) return '$_mediaBase$p';
    return p;
  }

  Future<void> _loadMediaBase() async {
    try {
      final base = await ref.read(configServiceProvider).getApiBaseUrl();
      if (mounted) setState(() => _mediaBase = base);
    } catch (_) {}
  }

  Color _colorFor(String name) {
    const palette = [
      Color(0xFF7C5CFF),
      Color(0xFF2E8BFF),
      Color(0xFF16A34A),
      Color(0xFFF59E0B),
      Color(0xFFEF4444),
      Color(0xFF0EA5E9),
      Color(0xFFDB2777),
    ];
    if (name.isEmpty) return palette.first;
    return palette[name.codeUnitAt(0) % palette.length];
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;

  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 9.5, fontWeight: FontWeight.w700),
      ),
    );
  }
}

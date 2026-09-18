import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../models/watch_party.dart';
import '../pages/watch_room.dart';
import '../services/config_service.dart';
import '../services/watch_party_service.dart';
import '../tv/tv_mode.dart';

/// 从播放页打开「一起看」主页底部弹层。
///
/// 返回 `true` 表示已进入房间（播放交由房间页接管）；
/// 返回 `false` 表示用户取消/关闭弹层，调用方可以恢复原播放。
Future<bool> showWatchPartyHome(
  BuildContext context,
  WidgetRef ref, {
  required String vodId,
  required int episode,
  required int positionMs,
  void Function(WatchPlaybackState state)? onRoomExit,
}) async {
  final entered = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _WatchPartyHome(
      vodId: vodId,
      episode: episode,
      positionMs: positionMs,
      onRoomExit: onRoomExit,
    ),
  );
  return entered ?? false;
}

/// 弹层内统一取色，随明暗主题切换。
class _Palette {
  final ColorScheme cs;
  const _Palette(this.cs);

  Color get bg => cs.surface;
  Color get card => cs.surfaceContainerHighest;
  Color get text => cs.onSurface;
  Color get sub => cs.secondary;
  Color get accent => AppColors.pink;
}

enum _View { home, hall, create, join, mine }

/// 一起看主页：大厅 / 创建 / 进入 / 我的房间，均为同一弹层内的子视图。
class _WatchPartyHome extends ConsumerStatefulWidget {
  final String vodId;
  final int episode;
  final int positionMs;
  final void Function(WatchPlaybackState state)? onRoomExit;

  const _WatchPartyHome({
    required this.vodId,
    required this.episode,
    required this.positionMs,
    this.onRoomExit,
  });

  @override
  ConsumerState<_WatchPartyHome> createState() => _WatchPartyHomeState();
}

class _WatchPartyHomeState extends ConsumerState<_WatchPartyHome> {
  _View _view = _View.home;
  bool _busy = false;

  WatchPartyService get _service => ref.read(watchPartyServiceProvider);

  /// 当前是否处于 TV 模式（横屏大屏）：用于给首个可操作项自动聚焦，
  /// 使遥控器进入弹层后无需先按方向键即可操作。
  bool get _isTv => resolveTvMode(context, ref.read(tvModeSettingProvider));

  String _err(Object e) => e.toString().replaceFirst('AppApiException: ', '');

  /// 关闭弹层并在根导航打开房间页。弹层回传 `true` 表示已进入房间。
  void _openRoom(WatchRoomInfo room) {
    final nav = Navigator.of(context, rootNavigator: true);
    Navigator.of(context).pop(true);
    nav.push(MaterialPageRoute<void>(
      builder: (_) => WatchRoomPage(
        code: room.code,
        initialRoom: room,
        onExit: widget.onRoomExit,
      ),
    ));
  }

  Future<void> _createRoom({
    required bool isPublic,
    required String password,
    required int memberLimit,
    required bool allowMemberControl,
  }) async {
    setState(() => _busy = true);
    try {
      final room = await _service.createRoom(
        vodId: widget.vodId,
        episode: widget.episode,
        positionMs: widget.positionMs,
        isPublic: isPublic,
        password: password,
        memberLimit: memberLimit,
        allowMemberControl: allowMemberControl,
      );
      if (!mounted) return;
      _openRoom(room);
    } catch (e) {
      if (mounted) _toast(_err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinRoom(String code, {String password = ''}) async {
    setState(() => _busy = true);
    try {
      final room = await _service.joinRoom(code, password: password);
      if (!mounted) return;
      _openRoom(room);
    } catch (e) {
      if (mounted) _toast(_err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final p = _Palette(Theme.of(context).colorScheme);
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.78,
      ),
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHandle(p),
            _buildHeader(p),
            Flexible(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHandle(_Palette p) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: p.sub.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  String get _title {
    switch (_view) {
      case _View.home:
        return '一起看';
      case _View.hall:
        return '观影大厅';
      case _View.create:
        return '创建房间';
      case _View.join:
        return '进入房间';
      case _View.mine:
        return '我的房间';
    }
  }

  Widget _buildHeader(_Palette p) {
    Widget leading;
    if (_view != _View.home) {
      leading = IconButton(
        icon: const Icon(Icons.arrow_back_ios_new, size: 18),
        color: p.text,
        onPressed: () => setState(() => _view = _View.home),
      );
    } else if (_isTv) {
      // TV 模式：提供可见的关闭按钮，遥控器可直接退出弹层。
      leading = IconButton(
        icon: const Icon(Icons.close_rounded, size: 20),
        color: p.text,
        onPressed: () => Navigator.of(context).pop(false),
      );
    } else {
      leading = const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
      child: Row(
        children: [
          SizedBox(width: 40, child: leading),
          Expanded(
            child: Text(
              _title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
          ),
          const SizedBox(width: 40),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator(color: AppColors.pink)),
      );
    }
    switch (_view) {
      case _View.home:
        return _buildHome();
      case _View.hall:
        return _HallView(
          onJoin: (room, password) => _joinRoom(room.code, password: password),
          toast: _toast,
        );
      case _View.create:
        return _buildCreate();
      case _View.join:
        return _buildJoin();
      case _View.mine:
        return _MineView(
          onEnter: (code) => _joinRoom(code),
          toast: _toast,
        );
    }
  }

  Widget _buildHome() {
    final isTv = _isTv;
    final tiles = <Widget>[
      _homeTile(
        icon: Icons.groups_rounded,
        color: AppColors.pink,
        title: '进去大厅',
        subtitle: '看看大家正在一起看什么',
        autofocus: isTv,
        onTap: () => setState(() => _view = _View.hall),
      ),
      _homeTile(
        icon: Icons.add_circle_outline_rounded,
        color: const Color(0xFF8B5CF6),
        title: '创建房间',
        subtitle: '用当前影片开一个房间',
        onTap: () => setState(() => _view = _View.create),
      ),
      _homeTile(
        icon: Icons.login_rounded,
        color: const Color(0xFF0EA5E9),
        title: '进入房间',
        subtitle: '输入房间号加入好友',
        onTap: () => setState(() => _view = _View.join),
      ),
      _homeTile(
        icon: Icons.bookmark_border_rounded,
        color: const Color(0xFF10B981),
        title: '我的房间',
        subtitle: '查看我进行中的房间',
        onTap: () => setState(() => _view = _View.mine),
      ),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      child: Column(children: tiles),
    );
  }

  Widget _homeTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool autofocus = false,
  }) {
    final p = _Palette(Theme.of(context).colorScheme);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: p.card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          autofocus: autofocus,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: p.text)),
                      const SizedBox(height: 3),
                      Text(subtitle,
                          style: TextStyle(fontSize: 12, color: p.sub)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: p.sub, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCreate() {
    return _CreateForm(
      busy: _busy,
      autofocus: _isTv,
      onCreate: _createRoom,
    );
  }

  Widget _buildJoin() {
    return _JoinForm(
      busy: _busy,
      autofocus: _isTv,
      onJoin: (code, password) => _joinRoom(code, password: password),
    );
  }
}

/// 大厅：进入时轮询刷新进行中房间。
class _HallView extends ConsumerStatefulWidget {
  final void Function(WatchHallRoom room, String password) onJoin;
  final void Function(String message) toast;

  const _HallView({required this.onJoin, required this.toast});

  @override
  ConsumerState<_HallView> createState() => _HallViewState();
}

class _HallViewState extends ConsumerState<_HallView> {
  List<WatchHallRoom> _rooms = const [];
  bool _loading = true;
  Timer? _timer;
  String _mediaBase = '';

  bool get _isTv => resolveTvMode(context, ref.read(tvModeSettingProvider));

  @override
  void initState() {
    super.initState();
    _load();
    _loadBase();
    _timer =
        Timer.periodic(const Duration(seconds: 4), (_) => _load(silent: true));
  }

  Future<void> _loadBase() async {
    try {
      final base = await ref.read(configServiceProvider).getApiBaseUrl();
      if (mounted) setState(() => _mediaBase = base);
    } catch (_) {}
  }

  String _absolute(String path) {
    final p = path.trim();
    if (p.isEmpty) return p;
    if (p.startsWith('http://') || p.startsWith('https://')) return p;
    if (p.startsWith('/') && _mediaBase.isNotEmpty) return '$_mediaBase$p';
    return p;
  }

  Widget _hostAvatar(WatchHallRoom room, _Palette p) {
    final name = room.hostName.isEmpty ? '观众' : room.hostName;
    final url = _absolute(room.hostPortrait);
    if (url.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          url,
          width: 18,
          height: 18,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _hostAvatarFallback(name, p),
        ),
      );
    }
    return _hostAvatarFallback(name, p);
  }

  Widget _hostAvatarFallback(String name, _Palette p) {
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: p.accent.withValues(alpha: 0.22),
      ),
      child: Text(
        name.characters.first,
        style: TextStyle(fontSize: 10, color: p.text),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final rooms = await ref.read(watchPartyServiceProvider).hall();
      if (mounted) setState(() => _rooms = rooms);
    } catch (e) {
      if (!silent && mounted) {
        widget.toast(e.toString().replaceFirst('AppApiException: ', ''));
      }
    } finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  Future<void> _onTap(WatchHallRoom room) async {
    var password = '';
    if (room.hasPassword) {
      final input = await _promptPassword();
      if (input == null) return;
      password = input;
    }
    widget.onJoin(room, password);
  }

  Future<String?> _promptPassword() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请输入房间密码'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          maxLength: 4,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(hintText: '4 位数字密码'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.length == 4) Navigator.of(ctx).pop(v);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _Palette(Theme.of(context).colorScheme);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator(color: AppColors.pink)),
      );
    }
    if (_rooms.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 56),
        child: Column(
          children: [
            Icon(Icons.meeting_room_outlined, size: 40, color: p.sub),
            const SizedBox(height: 12),
            Text('暂时没有进行中的房间',
                style: TextStyle(color: p.sub, fontSize: 13)),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      itemCount: _rooms.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final room = _rooms[i];
        return Material(
          color: p.card,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            autofocus: i == 0 && _isTv,
            onTap: () => _onTap(room),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  _cover(room.cover, p),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                room.title.isEmpty ? '一起看' : room.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: p.text),
                              ),
                            ),
                            if (room.hasPassword) ...[
                              const SizedBox(width: 6),
                              Icon(Icons.lock_outline_rounded,
                                  size: 14, color: p.sub),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            _hostAvatar(room, p),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                '房主 ${room.hostName.isEmpty ? '观众' : room.hostName} · ${room.memberCount}/${room.memberLimit} 人',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: p.sub),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text('房间号 ${room.code}',
                            style: TextStyle(fontSize: 12, color: p.sub)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: p.sub),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _cover(String url, _Palette p) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 56,
        height: 74,
        child: url.isEmpty
            ? Container(
                color: p.card,
                child: Icon(Icons.movie_outlined, color: p.sub, size: 22),
              )
            : Image.network(url, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                      color: p.card,
                      child:
                          Icon(Icons.movie_outlined, color: p.sub, size: 22),
                    )),
      ),
    );
  }
}

/// 我的房间：仅展示进行中的房间。
class _MineView extends ConsumerStatefulWidget {
  final void Function(String code) onEnter;
  final void Function(String message) toast;

  const _MineView({required this.onEnter, required this.toast});

  @override
  ConsumerState<_MineView> createState() => _MineViewState();
}

class _MineViewState extends ConsumerState<_MineView> {
  List<WatchRoomInfo> _rooms = const [];
  bool _loading = true;

  bool get _isTv => resolveTvMode(context, ref.read(tvModeSettingProvider));

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rooms = await ref.read(watchPartyServiceProvider).myRooms();
      if (mounted) setState(() => _rooms = rooms);
    } catch (e) {
      if (mounted) {
        widget.toast(e.toString().replaceFirst('AppApiException: ', ''));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _Palette(Theme.of(context).colorScheme);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator(color: AppColors.pink)),
      );
    }
    if (_rooms.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 56),
        child: Column(
          children: [
            Icon(Icons.bookmark_border_rounded, size: 40, color: p.sub),
            const SizedBox(height: 12),
            Text('还没有进行中的房间',
                style: TextStyle(color: p.sub, fontSize: 13)),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      itemCount: _rooms.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final room = _rooms[i];
        return Material(
          color: p.card,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            autofocus: i == 0 && _isTv,
            onTap: () => widget.onEnter(room.code),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          room.title.isEmpty ? '一起看' : room.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: p.text),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '房间号 ${room.code} · ${room.isHost ? '我是房主' : '成员'} · ${room.members.length}/${room.memberLimit} 人',
                          style: TextStyle(fontSize: 12, color: p.sub),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: p.sub),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 创建房间表单。
class _CreateForm extends StatefulWidget {
  final bool busy;
  final bool autofocus;
  final Future<void> Function({
    required bool isPublic,
    required String password,
    required int memberLimit,
    required bool allowMemberControl,
  }) onCreate;

  const _CreateForm({
    required this.busy,
    required this.onCreate,
    this.autofocus = false,
  });

  @override
  State<_CreateForm> createState() => _CreateFormState();
}

class _CreateFormState extends State<_CreateForm> {
  bool _isPublic = true;
  bool _allowMemberControl = false;
  int _memberLimit = 8;
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _Palette(Theme.of(context).colorScheme);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('公开房间',
                style: TextStyle(fontSize: 14, color: p.text)),
            subtitle: Text('公开房间会出现在大厅，所有人都能加入',
                style: TextStyle(fontSize: 12, color: p.sub)),
            value: _isPublic,
            activeThumbColor: AppColors.pink,
            onChanged: (v) => setState(() => _isPublic = v),
          ),
          if (!_isPublic) ...[
            const SizedBox(height: 4),
            Text('房间密码（4 位数字）',
                style: TextStyle(fontSize: 13, color: p.text)),
            const SizedBox(height: 8),
            TextField(
              controller: _password,
              keyboardType: TextInputType.number,
              maxLength: 4,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                hintText: '请输入 4 位数字密码',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('允许成员控制播放',
                style: TextStyle(fontSize: 14, color: p.text)),
            subtitle: Text('关闭后仅你（房主）可以暂停、选集与拖动进度',
                style: TextStyle(fontSize: 12, color: p.sub)),
            value: _allowMemberControl,
            activeThumbColor: AppColors.pink,
            onChanged: (v) => setState(() => _allowMemberControl = v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text('房间人数上限',
                    style: TextStyle(fontSize: 14, color: p.text)),
              ),
              IconButton(
                onPressed: _memberLimit > 2
                    ? () => setState(() => _memberLimit--)
                    : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text('$_memberLimit',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: p.text)),
              IconButton(
                onPressed: _memberLimit < 50
                    ? () => setState(() => _memberLimit++)
                    : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              autofocus: widget.autofocus,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.pink,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: widget.busy
                  ? null
                  : () {
                      if (!_isPublic && _password.text.trim().length != 4) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请设置 4 位数字密码')),
                        );
                        return;
                      }
                      widget.onCreate(
                        isPublic: _isPublic,
                        password: _isPublic ? '' : _password.text.trim(),
                        memberLimit: _memberLimit,
                        allowMemberControl: _allowMemberControl,
                      );
                    },
              child: const Text('创建并进入',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 输入房间号加入。
class _JoinForm extends StatefulWidget {
  final bool busy;
  final bool autofocus;
  final Future<void> Function(String code, String password) onJoin;

  const _JoinForm({
    required this.busy,
    required this.onJoin,
    this.autofocus = false,
  });

  @override
  State<_JoinForm> createState() => _JoinFormState();
}

class _JoinFormState extends State<_JoinForm> {
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _needPassword = false;

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _Palette(Theme.of(context).colorScheme);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('房间号', style: TextStyle(fontSize: 13, color: p.text)),
          const SizedBox(height: 8),
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            maxLength: 6,
            onChanged: (v) => setState(() {}),
            decoration: const InputDecoration(
              hintText: '请输入 6 位房间号',
              counterText: '',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          if (_needPassword) ...[
            Text('房间密码', style: TextStyle(fontSize: 13, color: p.text)),
            const SizedBox(height: 8),
            TextField(
              controller: _password,
              keyboardType: TextInputType.number,
              maxLength: 4,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                hintText: '4 位数字密码',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Text('房间有密码？',
                  style: TextStyle(fontSize: 13, color: p.sub)),
              Checkbox(
                value: _needPassword,
                activeColor: AppColors.pink,
                onChanged: (v) => setState(() => _needPassword = v ?? false),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              autofocus: widget.autofocus,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.pink,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: widget.busy || _code.text.trim().length != 6
                  ? null
                  : () => widget.onJoin(
                        _code.text.trim().toUpperCase(),
                        _needPassword ? _password.text.trim() : '',
                      ),
              child: const Text('加入房间',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

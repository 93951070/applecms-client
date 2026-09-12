import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import '../models/watch_party.dart';
import '../providers/auth_provider.dart';
import '../services/watch_party_service.dart';
import '../widgets/zen_ui.dart';
import 'watch_room.dart';

/// 一起看入口页：加入房间、查看我参与的房间。
class WatchPage extends ConsumerStatefulWidget {
  const WatchPage({super.key});

  @override
  ConsumerState<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends ConsumerState<WatchPage> {
  final TextEditingController _codeInput = TextEditingController();
  List<WatchRoomInfo> _rooms = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _codeInput.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!ref.read(authProvider).isLoggedIn) {
      setState(() => _rooms = const []);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rooms = await ref.read(watchPartyServiceProvider).myRooms();
      if (!mounted) return;
      setState(() => _rooms = rooms);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('AppApiException: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _joinByCode() async {
    final code = _codeInput.text.trim().toUpperCase();
    if (code.isEmpty) {
      _toast('请输入房间号');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => WatchRoomPage(code: code)),
    );
    if (mounted) _load();
  }

  Future<void> _openRoom(WatchRoomInfo room) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WatchRoomPage(code: room.code, initialRoom: room),
      ),
    );
    if (mounted) _load();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(authProvider).isLoggedIn;
    return ZenScaffold(
      appBar: AppBar(title: const Text('一起看')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildJoinCard(loggedIn),
            const SizedBox(height: 16),
            if (!loggedIn)
              _buildLoginHint()
            else ...[
              const Text(
                '我参与的房间',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.lightText,
                ),
              ),
              const SizedBox(height: 10),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                _buildEmpty(_error!)
              else if (_rooms.isEmpty)
                _buildEmpty('还没有房间，在影片详情页点「一起看」即可创建')
              else
                ..._rooms.map(_buildRoomTile),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildJoinCard(bool loggedIn) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '输入房间号加入',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.lightText,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _codeInput,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 6,
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '例如 AB3D9K',
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.9),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ZenButton(
                onPressed: loggedIn ? _joinByCode : () => context.push('/login'),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(loggedIn ? '加入' : '登录'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLoginHint() {
    return Container(
      padding: const EdgeInsets.all(20),
      alignment: Alignment.center,
      child: Column(
        children: [
          const Icon(Icons.group_rounded, size: 40, color: AppColors.auroraBlue),
          const SizedBox(height: 10),
          Text(
            '登录后即可创建或加入一起看房间',
            style: TextStyle(fontSize: 13, color: AppColors.lightText2),
          ),
          const SizedBox(height: 12),
          ZenButton(
            onPressed: () => context.push('/login'),
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: const Text('去登录'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: AppColors.lightText3),
        ),
      ),
    );
  }

  Widget _buildRoomTile(WatchRoomInfo room) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        onTap: () => _openRoom(room),
        leading: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: room.cover.isEmpty
                  ? Container(
                      width: 52,
                      height: 52,
                      color: AppColors.pinkLight,
                      child: const Icon(Icons.movie_rounded,
                          color: AppColors.pink, size: 22),
                    )
                  : Image.network(
                      room.cover,
                      width: 52,
                      height: 52,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 52,
                        height: 52,
                        color: AppColors.pinkLight,
                        child: const Icon(Icons.movie_rounded,
                            color: AppColors.pink, size: 22),
                      ),
                    ),
            ),
          ],
        ),
        title: Text(
          room.title.isEmpty ? '未命名影片' : room.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '房间号 ${room.code} · ${room.members.length}/${room.memberLimit} 人'
          '${room.isHost ? " · 我是房主" : ""}',
          style: const TextStyle(fontSize: 12, color: AppColors.lightText2),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}

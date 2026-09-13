import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';

/// 播放已离线缓存的本地视频文件。
class OfflinePlayerPage extends StatefulWidget {
  final String filePath;
  final String title;

  const OfflinePlayerPage({
    super.key,
    required this.filePath,
    required this.title,
  });

  @override
  State<OfflinePlayerPage> createState() => _OfflinePlayerPageState();
}

class _OfflinePlayerPageState extends State<OfflinePlayerPage> {
  BetterPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _init() {
    try {
      final controller = BetterPlayerController(
        const BetterPlayerConfiguration(
          autoPlay: true,
          fit: BoxFit.contain,
          allowedScreenSleep: false,
          handleLifecycle: false,
          autoDispose: false,
        ),
        betterPlayerDataSource: BetterPlayerDataSource(
          BetterPlayerDataSourceType.file,
          widget.filePath,
        ),
      );
      controller.addEventsListener((event) {
        if (event.betterPlayerEventType == BetterPlayerEventType.exception &&
            mounted) {
          setState(() => _error = '缓存文件已损坏或不存在');
        }
      });
      _controller = controller;
      setState(() {});
    } catch (_) {
      if (mounted) setState(() => _error = '缓存文件已损坏或不存在');
    }
  }

  @override
  void dispose() {
    _controller?.dispose(forceDispose: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white70))
            : (controller == null
                ? const CircularProgressIndicator(color: Colors.white)
                : BetterPlayer(controller: controller)),
      ),
    );
  }
}

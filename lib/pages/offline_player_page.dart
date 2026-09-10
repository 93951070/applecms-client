import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

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
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final controller =
          VideoPlayerController.file(File(widget.filePath));
      await controller.initialize();
      if (!mounted) return;
      _videoController = controller;
      _chewieController = ChewieController(
        videoPlayerController: controller,
        autoPlay: true,
        looping: false,
        aspectRatio: controller.value.aspectRatio,
        allowFullScreen: true,
      );
      setState(() {});
    } catch (_) {
      if (mounted) setState(() => _error = '缓存文件已损坏或不存在');
    }
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
            : (_chewieController == null
                ? const CircularProgressIndicator(color: Colors.white)
                : AspectRatio(
                    aspectRatio: _videoController!.value.aspectRatio,
                    child: Chewie(controller: _chewieController!),
                  )),
      ),
    );
  }
}

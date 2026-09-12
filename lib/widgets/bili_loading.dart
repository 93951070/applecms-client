import 'package:flutter/material.dart';

/// 视频缓冲/初始化时的横向进度条。
class VideoLoadingBar extends StatelessWidget {
  final double width;
  final double height;
  final Color color;
  final EdgeInsetsGeometry padding;

  const VideoLoadingBar({
    super.key,
    this.width = 160,
    this.height = 3,
    this.color = Colors.white,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: SizedBox(
        width: width,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(height),
          child: LinearProgressIndicator(
            minHeight: height,
            backgroundColor: color.withValues(alpha: 0.18),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ),
    );
  }
}

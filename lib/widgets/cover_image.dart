import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// 通用封面图片组件
class CoverImage extends StatelessWidget {
  final String imageUrl;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;
  final double aspectRatio;

  const CoverImage({
    super.key,
    required this.imageUrl,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
    this.aspectRatio = 2 / 3,
  });

  @override
  Widget build(BuildContext context) {
    final loadingPlaceholder = AspectRatio(
      aspectRatio: aspectRatio,
      child: placeholder ?? Container(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.05),
      ),
    );

    return AspectRatio(
      aspectRatio: aspectRatio,
      child: CachedNetworkImage(
        imageUrl: imageUrl,
        fit: fit,
        memCacheHeight: 600,
        placeholder: (context, url) => loadingPlaceholder,
        errorWidget: (context, url, error) => errorWidget ?? Container(
          color: Colors.black12,
          child: const Center(child: Icon(Icons.broken_image_outlined, size: 24, color: Colors.grey)),
        ),
      ),
    );
  }
}

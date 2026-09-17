/// 豆瓣图片统一走后台代理，避免客户端直连豆瓣被限流。
String doubanImageUrl(String base, String raw) =>
    '$base/api/douban/image?u=${Uri.encodeQueryComponent(raw)}';

/// 展示用数字格式化：与视频站习惯保持一致，避免长数字撑破布局。
String formatCount(int value) {
  if (value >= 100000000) {
    return '${(value / 100000000).toStringAsFixed(1)}亿';
  }
  if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
  return '$value';
}

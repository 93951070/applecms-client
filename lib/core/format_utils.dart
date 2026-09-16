/// 展示用数字格式化：与视频站习惯保持一致，避免长数字撑破布局。
String formatCount(int value) {
  if (value >= 100000000) {
    return '${(value / 100000000).toStringAsFixed(1)}亿';
  }
  if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
  return '$value';
}

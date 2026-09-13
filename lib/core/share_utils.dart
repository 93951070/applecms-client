import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

/// 调用系统分享面板。iPad 等设备需要 sharePositionOrigin，否则会抛出异常。
Future<void> shareText(
  BuildContext context,
  String text, {
  String? subject,
}) async {
  Rect? origin;
  final box = context.findRenderObject() as RenderBox?;
  if (box != null && box.hasSize) {
    origin = box.localToGlobal(Offset.zero) & box.size;
  }
  await SharePlus.instance.share(
    ShareParams(
      text: text,
      subject: subject,
      sharePositionOrigin: origin,
    ),
  );
}

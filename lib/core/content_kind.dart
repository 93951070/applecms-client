/// 内容形态判定：决定分类进入网格列表还是竖屏 Feed。
///
/// 后端如需新增竖屏/短剧分类，只需在此登记 type_id，或让分类名包含关键字。
library;

/// 短剧分类的 type_id（后端初始数据中为一级分类）。
const int kShortDramaTypeId = 31;

/// 分类名包含这些关键字时也按竖屏 Feed 处理。
const List<String> kFeedNameKeywords = <String>['短剧', '竖屏', '微短剧'];

/// 是否为竖屏 Feed 形态的分类。
bool isFeedCategory({required int typeId, String? typeName}) {
  if (typeId == kShortDramaTypeId) return true;
  final name = (typeName ?? '').trim();
  if (name.isEmpty) return false;
  for (final kw in kFeedNameKeywords) {
    if (name.contains(kw)) return true;
  }
  return false;
}

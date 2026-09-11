import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/site.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';

final historyProvider = NotifierProvider<HistoryNotifier, AsyncValue<List<PlayRecord>>>(HistoryNotifier.new);

class HistoryNotifier extends Notifier<AsyncValue<List<PlayRecord>>> {
  @override
  AsyncValue<List<PlayRecord>> build() {
    _loadHistory();
    return const AsyncLoading();
  }

  /// 登录后以账号数据为准，未登录/离线时退回本机缓存。
  Future<void> _loadHistory() async {
    final config = ref.read(configServiceProvider);
    List<PlayRecord> local = [];
    try {
      local = await config.getHistory();
    } catch (_) {}

    final token = await config.getAuthToken();
    if (token == null || token.isEmpty) {
      state = AsyncData(local);
      return;
    }
    try {
      final remote = await ref.read(cmsServiceProvider).fetchServerHistory();
      state = AsyncData(remote);
      await config.saveHistory(remote);
    } catch (_) {
      state = AsyncData(local);
    }
  }

  /// 登录/退出后重新拉取播放记录来源。
  Future<void> reload() => _loadHistory();

  Future<void> saveRecord(PlayRecord record) async {
    final service = ref.read(configServiceProvider);

    // 获取当前列表并更新
    final currentHistory = state.value ?? [];
    final updatedHistory = List<PlayRecord>.from(currentHistory);
    final recordVodId = record.doubanId ?? '';

    updatedHistory.removeWhere((r) =>
        (recordVodId.isNotEmpty && r.doubanId == recordVodId) ||
        r.searchTitle == record.searchTitle);
    updatedHistory.insert(0, record);
    if (updatedHistory.length > 20) updatedHistory.removeLast();

    // 先更新 UI 状态，实现秒开感
    state = AsyncData(updatedHistory);

    // 异步持久化（本机缓存 + 账号）
    await service.saveHistory(updatedHistory);
    if (recordVodId.isNotEmpty) {
      try {
        await ref.read(cmsServiceProvider).pushServerHistory(record);
      } catch (_) {}
    }
  }

  Future<void> clearHistory() async {
    final service = ref.read(configServiceProvider);
    state = const AsyncData([]);
    await service.saveHistory([]);
    try {
      await ref.read(cmsServiceProvider).clearServerHistory();
    } catch (_) {}
  }

  Future<void> removeRecord(String searchTitle) async {
    final service = ref.read(configServiceProvider);
    final currentHistory = state.value ?? [];
    final matched = currentHistory.where((r) => r.searchTitle == searchTitle);
    final vodId = matched.isNotEmpty ? (matched.first.doubanId ?? '') : '';
    final updatedHistory = currentHistory.where((r) => r.searchTitle != searchTitle).toList();

    state = AsyncData(updatedHistory);
    await service.saveHistory(updatedHistory);
    if (vodId.isNotEmpty) {
      try {
        await ref.read(cmsServiceProvider).clearServerHistory(videoId: vodId);
      } catch (_) {}
    }
  }

  /// 退出登录：清空本机记录，避免上一账号数据残留。
  Future<void> onLoggedOut() async {
    state = const AsyncData([]);
    await ref.read(configServiceProvider).saveHistory([]);
  }
}

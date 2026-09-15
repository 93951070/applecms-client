import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/config_service.dart';

/// 「推荐」（点赞）状态：与收藏一致，落在本机存储里，离线也保留。
final likesProvider = NotifierProvider<LikesNotifier, AsyncValue<Set<String>>>(
  LikesNotifier.new,
);

class LikesNotifier extends Notifier<AsyncValue<Set<String>>> {
  @override
  AsyncValue<Set<String>> build() {
    _load();
    return const AsyncLoading();
  }

  Future<void> _load() async {
    final service = ref.read(configServiceProvider);
    try {
      state = AsyncData(await service.getLikedKeys());
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  bool contains(String key) => (state.value ?? const <String>{}).contains(key);

  /// 切换推荐状态，返回切换后是否处于「已推荐」。
  Future<bool> toggle(String key) async {
    if (key.isEmpty) return false;
    final liked = !contains(key);
    await setLiked(key, liked);
    return liked;
  }

  /// 以服务端结果为准写入本地镜像（离线时仍能展示推荐状态）。
  Future<void> setLiked(String key, bool liked) async {
    if (key.isEmpty) return;
    final service = ref.read(configServiceProvider);
    final current = Set<String>.from(state.value ?? const <String>{});
    if (liked) {
      current.add(key);
    } else {
      current.remove(key);
    }
    state = AsyncData(current);
    await service.saveLikedKeys(current);
  }
}

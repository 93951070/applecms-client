import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/site.dart';
import '../services/config_service.dart';

final favoritesProvider =
    NotifierProvider<FavoritesNotifier, AsyncValue<List<Favorite>>>(
        FavoritesNotifier.new);

class FavoritesNotifier extends Notifier<AsyncValue<List<Favorite>>> {
  @override
  AsyncValue<List<Favorite>> build() {
    _load();
    return const AsyncLoading();
  }

  Future<void> _load() async {
    final service = ref.read(configServiceProvider);
    try {
      state = AsyncData(await service.getFavorites());
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  String _keyOf(Favorite f) =>
      f.subjectId.isNotEmpty ? f.subjectId : f.searchTitle;

  bool contains(String subjectId, String searchTitle) {
    final key = subjectId.isNotEmpty ? subjectId : searchTitle;
    return (state.value ?? const <Favorite>[])
        .any((f) => _keyOf(f) == key);
  }

  Future<void> add(Favorite favorite) async {
    final service = ref.read(configServiceProvider);
    final current = List<Favorite>.from(state.value ?? const <Favorite>[]);
    current.removeWhere((f) => _keyOf(f) == _keyOf(favorite));
    current.insert(0, favorite);
    state = AsyncData(current);
    await service.saveFavorites(current);
  }

  Future<void> remove(String subjectId, String searchTitle) async {
    final service = ref.read(configServiceProvider);
    final key = subjectId.isNotEmpty ? subjectId : searchTitle;
    final current = (state.value ?? const <Favorite>[])
        .where((f) => _keyOf(f) != key)
        .toList();
    state = AsyncData(current);
    await service.saveFavorites(current);
  }

  Future<void> clear() async {
    final service = ref.read(configServiceProvider);
    state = const AsyncData([]);
    await service.saveFavorites([]);
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/user.dart';
import '../services/auth_service.dart';
import '../services/config_service.dart';

class AuthState {
  final bool initialized;
  final bool loading;
  final AppUser? user;
  final String? token;

  const AuthState({
    this.initialized = false,
    this.loading = false,
    this.user,
    this.token,
  });

  bool get isLoggedIn => token != null && token!.isNotEmpty;
}

final authProvider = NotifierProvider<AuthModel, AuthState>(AuthModel.new);

class AuthModel extends Notifier<AuthState> {
  @override
  AuthState build() {
    _restore();
    return const AuthState();
  }

  Future<void> _restore() async {
    final token = await ref.read(configServiceProvider).getAuthToken();
    if (token == null) {
      state = const AuthState(initialized: true);
      return;
    }
    state = AuthState(initialized: true, token: token);
    await refresh();
  }

  /// 拉取最新用户（会员等级/到期时间）；token 失效则清除本地登录态
  Future<void> refresh() async {
    final token = state.token;
    if (token == null) return;
    final base = await ref.read(configServiceProvider).getApiBaseUrl();
    try {
      final user = await ref.read(authServiceProvider).me(base, token);
      if (user == null) {
        await _clearToken();
      } else {
        state = AuthState(initialized: true, token: token, user: user);
      }
    } catch (_) {
      // 网络异常时保留本地登录态，等待下次刷新
      state = AuthState(initialized: true, token: token, user: state.user);
    }
  }

  Future<String?> login(String username, String password) async {
    final prev = state;
    state = AuthState(
        initialized: true, loading: true, token: prev.token, user: prev.user);
    final base = await ref.read(configServiceProvider).getApiBaseUrl();
    final result =
        await ref.read(authServiceProvider).login(base, username, password);
    if (result.success && result.token != null) {
      await ref.read(configServiceProvider).setAuthToken(result.token);
      state = AuthState(
          initialized: true, token: result.token, user: result.user);
      if (result.user == null) await refresh();
      return null;
    }
    state = AuthState(
        initialized: true, token: prev.token, user: prev.user);
    return result.message;
  }

  Future<String?> register(
    String username,
    String password,
    String email,
  ) async {
    final prev = state;
    state = AuthState(
        initialized: true, loading: true, token: prev.token, user: prev.user);
    final base = await ref.read(configServiceProvider).getApiBaseUrl();
    final result = await ref
        .read(authServiceProvider)
        .register(base, username, password, email);
    if (result.success && result.token != null) {
      await ref.read(configServiceProvider).setAuthToken(result.token);
      state = AuthState(
          initialized: true, token: result.token, user: result.user);
      if (result.user == null) await refresh();
      return null;
    }
    state = AuthState(
        initialized: true, token: prev.token, user: prev.user);
    return result.message;
  }

  Future<void> logout() async {
    final token = state.token;
    if (token != null) {
      final base = await ref.read(configServiceProvider).getApiBaseUrl();
      await ref.read(authServiceProvider).logout(base, token);
    }
    await _clearToken();
  }

  Future<RedeemResult> redeemCard(String code) async {
    final token = state.token;
    if (token == null) return const RedeemResult(false, '请先登录');
    final base = await ref.read(configServiceProvider).getApiBaseUrl();
    final result =
        await ref.read(authServiceProvider).redeemCard(base, token, code);
    if (result.success) await refresh();
    return result;
  }

  Future<String?> buyCardUrl() async {
    final base = await ref.read(configServiceProvider).getApiBaseUrl();
    return ref.read(authServiceProvider).buyCardUrl(base);
  }

  Future<void> _clearToken() async {
    await ref.read(configServiceProvider).setAuthToken(null);
    state = const AuthState(initialized: true);
  }
}

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/user.dart';

final authServiceProvider = Provider((ref) => AuthService());

class AuthResult {
  final bool success;
  final String message;
  final String? token;
  final AppUser? user;

  const AuthResult({
    required this.success,
    required this.message,
    this.token,
    this.user,
  });
}

class RedeemResult {
  final bool success;
  final String message;

  const RedeemResult(this.success, this.message);
}

/// 网站会员系统 API 客户端。
/// 基址由 ConfigService 的「网站地址」提供，路径与后端 `/api/auth/*`、`/api/user/*` 对齐。
class AuthService {
  final Dio _dio;

  AuthService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 12),
              validateStatus: (s) => s != null && s < 500,
            ));

  Options _auth(String token) =>
      Options(headers: {'Authorization': 'Bearer $token'});

  Future<AuthResult> login(String base, String username, String password) async {
    try {
      final res = await _dio.post(
        '$base/api/auth/login',
        data: {'username': username, 'password': password},
      );
      final data = _asMap(res.data);
      if (data == null) {
        return const AuthResult(success: false, message: '服务器返回数据异常');
      }
      final ok = data['success'] == true;
      return AuthResult(
        success: ok,
        message: (data['msg'] ?? (ok ? '登录成功' : '登录失败')).toString(),
        token: data['token']?.toString(),
        user: AppUser.fromJson(_asMap(data['user'])),
      );
    } on DioException catch (e) {
      return AuthResult(success: false, message: _dioMessage(e));
    } catch (e) {
      return AuthResult(success: false, message: '登录失败：$e');
    }
  }

  Future<AuthResult> register(
    String base,
    String username,
    String password,
    String email,
  ) async {
    try {
      final res = await _dio.post(
        '$base/api/auth/register',
        data: {'username': username, 'password': password, 'email': email},
      );
      final data = _asMap(res.data);
      if (data == null) {
        return const AuthResult(success: false, message: '服务器返回数据异常');
      }
      final ok = data['code'] == 1;
      return AuthResult(
        success: ok,
        message: (data['msg'] ?? (ok ? '注册成功' : '注册失败')).toString(),
        token: data['token']?.toString(),
        user: AppUser.fromJson(_asMap(data['user'])),
      );
    } on DioException catch (e) {
      return AuthResult(success: false, message: _dioMessage(e));
    } catch (e) {
      return AuthResult(success: false, message: '注册失败：$e');
    }
  }

  /// 用 token 拉取当前用户；token 失效返回 null
  Future<AppUser?> me(String base, String token) async {
    final res = await _dio.get('$base/api/auth/me', options: _auth(token));
    final data = _asMap(res.data);
    if (data == null || data['code'] != 1) return null;
    return AppUser.fromJson(_asMap(data['user']));
  }

  Future<RedeemResult> redeemCard(String base, String token, String code) async {
    try {
      final res = await _dio.post(
        '$base/api/user/use-card',
        data: {'card_code': code},
        options: _auth(token),
      );
      final data = _asMap(res.data);
      if (data == null) {
        return const RedeemResult(false, '服务器返回数据异常');
      }
      return RedeemResult(
        data['success'] == true,
        (data['message'] ?? data['msg'] ?? '兑换失败').toString(),
      );
    } on DioException catch (e) {
      return RedeemResult(false, _dioMessage(e));
    } catch (e) {
      return RedeemResult(false, '兑换失败：$e');
    }
  }

  /// 购买/赞助卡密链接，未配置返回 null
  Future<String?> buyCardUrl(String base) async {
    try {
      final res = await _dio.get('$base/api/config/buy_card');
      final data = _asMap(res.data);
      if (data == null || data['success'] != true) return null;
      final value = data['config_value']?.toString().trim();
      return (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }

  Future<void> logout(String base, String token) async {
    try {
      await _dio.post('$base/api/auth/logout', options: _auth(token));
    } catch (_) {
      // 登出失败不阻塞本地清理
    }
  }

  String _dioMessage(DioException e) {
    final data = _asMap(e.response?.data);
    if (data != null) {
      final msg = data['msg'] ?? data['message'];
      if (msg != null && msg.toString().trim().isNotEmpty) return msg.toString();
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '网络超时，请稍后重试';
      case DioExceptionType.connectionError:
        return '无法连接服务器，请检查网站地址';
      default:
        return '网络请求失败，请稍后重试';
    }
  }

  Map<String, dynamic>? _asMap(dynamic v) {
    if (v == null) return null;
    if (v is Map) return Map<String, dynamic>.from(v);
    if (v is String && v.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(v);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return null;
  }
}

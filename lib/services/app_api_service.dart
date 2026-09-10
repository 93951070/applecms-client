import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final appApiServiceProvider = Provider((ref) => AppApiService());

/// 网关调用失败时抛出。`statusCode` 为 HTTP 状态码（网络异常时为 null）。
class AppApiException implements Exception {
  final String message;
  final int? statusCode;

  const AppApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// `POST /api/app/v1/play` 的解析结果。
class AppPlayResult {
  final bool success;
  final bool hasAccess;
  final String message;
  final String? playUrl;
  final String? episodeName;
  final String? playToken;
  final int? expireAt;

  const AppPlayResult({
    required this.success,
    required this.hasAccess,
    required this.message,
    this.playUrl,
    this.episodeName,
    this.playToken,
    this.expireAt,
  });
}

/// `GET /api/app/v1/version` 的解析结果。
class AppVersionInfo {
  final bool forceUpdate;
  final bool needUpdate;
  final String latestVersion;
  final String minVersion;
  final String? updateUrl;

  const AppVersionInfo({
    required this.forceUpdate,
    required this.needUpdate,
    required this.latestVersion,
    required this.minVersion,
    this.updateUrl,
  });
}

class _Session {
  final String id;
  final SecretKey key;
  final DateTime expiresAt;

  const _Session({required this.id, required this.key, required this.expiresAt});

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class _SessionExpiredException implements Exception {
  const _SessionExpiredException();
}

/// App 专用加密网关客户端。
///
/// 负责规范化串签名、X25519 握手、AES-256-GCM 响应解密与失败重试。
/// 客户端凭证内置；服务端地址复用「网站会员接口地址」（ConfigService.apiBaseUrl）。
class AppApiService {
  /// 内置客户端凭证，可通过 `--dart-define=APP_CLIENT_ID/APP_CLIENT_SECRET` 覆盖。
  static const String clientId =
      String.fromEnvironment('APP_CLIENT_ID', defaultValue: 'echotv-app');
  static const String clientSecret = String.fromEnvironment(
      'APP_CLIENT_SECRET',
      defaultValue: 'echotv-app-secret-change-me');

  static const String _apiPrefix = '/api/app/v1';
  static const String _sessionKeyInfo = 'app-gateway-session-v1';
  static const int _timestampToleranceSeconds = 300;

  final Dio _dio;
  final X25519 _x25519 = X25519();
  final AesGcm _aes = AesGcm.with256bits();
  final Hmac _hmac = Hmac.sha256();
  final Sha256 _sha256 = Sha256();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  final Map<String, _Session> _sessions = {};

  AppApiService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 12),
              validateStatus: (s) => s != null && s < 500,
            ));

  // ==================== 公开接口 ====================

  /// 版本检查。`currentVersion` 形如 `1.0.6`。
  Future<AppVersionInfo> checkVersion(String base, String currentVersion) async {
    final data = await _request(
      base,
      method: 'GET',
      path: '$_apiPrefix/version',
      query: 'version=${Uri.encodeQueryComponent(currentVersion)}',
    );
    return AppVersionInfo(
      forceUpdate: data['force_update'] == true,
      needUpdate: data['need_update'] == true,
      latestVersion: (data['latest_version'] ?? '').toString(),
      minVersion: (data['min_version'] ?? '').toString(),
      updateUrl: (data['update_url'] ?? '').toString().trim().isEmpty
          ? null
          : data['update_url'].toString(),
    );
  }

  /// 视频列表（分页）。返回解密后的明文 Map。
  Future<Map<String, dynamic>> listVideos(
    String base, {
    int page = 1,
    int limit = 20,
    String? typeId,
    String? keyword,
    String? sort,
  }) async {
    final params = <String, String>{
      'page': '$page',
      'limit': '$limit',
      if (typeId != null && typeId.isNotEmpty) 'type_id': typeId,
      if (keyword != null && keyword.isNotEmpty) 'wd': keyword,
      if (sort != null && sort.isNotEmpty) 'sort': sort,
    };
    return _request(
      base,
      method: 'GET',
      path: '$_apiPrefix/videos',
      query: _encodeQuery(params),
    );
  }

  /// 视频详情。
  Future<Map<String, dynamic>> videoDetail(String base, String vodId) async {
    return _request(base, method: 'GET', path: '$_apiPrefix/videos/$vodId');
  }

  /// 分类树（主分类 + 子分类）。
  Future<List<Map<String, dynamic>>> categories(String base) async {
    final data =
        await _request(base, method: 'GET', path: '$_apiPrefix/categories');
    final hierarchy = data['hierarchy'];
    if (hierarchy is List) {
      return hierarchy
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  /// 会员校验并解析直连地址。`token` 为账号令牌（未登录可不传）。
  Future<AppPlayResult> play(
    String base, {
    required String videoId,
    required int playSource,
    required int playIndex,
    String? token,
  }) async {
    final data = await _request(
      base,
      method: 'POST',
      path: '$_apiPrefix/play',
      jsonBody: {
        'video_id': videoId,
        'play_source': playSource,
        'play_index': playIndex,
      },
      token: token,
    );
    return AppPlayResult(
      success: data['success'] == true,
      hasAccess: data['has_access'] == true,
      message: (data['message'] ?? '').toString(),
      playUrl: _nonEmpty(data['play_url']),
      episodeName: _nonEmpty(data['episode_name']),
      playToken: _nonEmpty(data['play_token']),
      expireAt: (data['expire_at'] as num?)?.toInt(),
    );
  }

  /// 清除已缓存的会话（例如用户切换了后端地址）。
  void clearSession([String? base]) {
    if (base == null) {
      _sessions.clear();
    } else {
      _sessions.remove(base);
    }
  }

  // ==================== 请求与签名 ====================

  Future<Map<String, dynamic>> _request(
    String base, {
    required String method,
    required String path,
    String query = '',
    Map<String, dynamic>? jsonBody,
    String? token,
  }) async {
    final body = jsonBody == null ? '' : jsonEncode(jsonBody);
    var session = await _ensureSession(base);

    for (var attempt = 0; attempt < 2; attempt++) {
      final res = await _rawRequest(
        base,
        method: method,
        path: path,
        query: query,
        body: body,
        sessionId: session.id,
        token: token,
      );

      if (res.statusCode == 401) {
        // 会话过期或签名时间窗偏差，重握手后重试一次。
        _sessions.remove(base);
        if (attempt == 0) {
          session = await _ensureSession(base, force: true);
          continue;
        }
        throw AppApiException(_errorMessage(res), statusCode: 401);
      }
      if (res.statusCode == 403) {
        throw AppApiException(_errorMessage(res), statusCode: 403);
      }
      if (res.statusCode == 429) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        throw AppApiException(_errorMessage(res), statusCode: 429);
      }
      if (res.statusCode != null && res.statusCode! >= 400) {
        throw AppApiException(_errorMessage(res), statusCode: res.statusCode);
      }

      final map = _asMap(res.data);
      if (map == null) {
        throw const AppApiException('服务器响应格式异常');
      }
      if (map['iv'] != null && map['data'] != null) {
        try {
          return await _decryptEnvelope(session, map);
        } on _SessionExpiredException {
          _sessions.remove(base);
          if (attempt == 0) {
            session = await _ensureSession(base, force: true);
            continue;
          }
          throw const AppApiException('会话已过期，请重试');
        } catch (_) {
          // 解密失败：重新握手并重试一次。
          _sessions.remove(base);
          if (attempt == 0) {
            session = await _ensureSession(base, force: true);
            continue;
          }
          throw const AppApiException('响应解密失败，请重试');
        }
      }
      // 非加密的明文错误体
      if (map['success'] == false) {
        throw AppApiException(
            (map['message'] ?? map['msg'] ?? '请求失败').toString(),
            statusCode: res.statusCode);
      }
      throw const AppApiException('服务器响应格式异常');
    }
    throw const AppApiException('请求失败，请稍后重试');
  }

  Future<Response<dynamic>> _rawRequest(
    String base, {
    required String method,
    required String path,
    required String query,
    required String body,
    String? sessionId,
    String? token,
  }) async {
    final headers = await _signedHeaders(method, path, query, body);
    if (sessionId != null && sessionId.isNotEmpty) {
      headers['X-Session-Id'] = sessionId;
    }
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    final url = '$base$path${query.isEmpty ? '' : '?$query'}';
    try {
      return await _dio.request<dynamic>(
        url,
        data: body.isEmpty ? null : body,
        options: Options(method: method.toUpperCase(), headers: headers),
      );
    } on DioException catch (e) {
      throw AppApiException(_dioMessage(e));
    }
  }

  Future<Map<String, String>> _signedHeaders(
      String method, String path, String query, String body) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nonce = _randomHex(16);
    final bodyHash = _hex((await _sha256.hash(utf8.encode(body))).bytes);
    final canonical = '${method.toUpperCase()}\n$path\n$query\n$timestamp\n$nonce\n$bodyHash';
    final mac = await _hmac.calculateMac(
      utf8.encode(canonical),
      secretKey: SecretKey(utf8.encode(clientSecret)),
    );
    return {
      'X-Client-Id': clientId,
      'X-Timestamp': '$timestamp',
      'X-Nonce': nonce,
      'X-Signature': _hex(mac.bytes),
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
  }

  /// 校验签名与本机时间偏差，超窗时抛出，供上层提示用户校正时间。
  bool timestampWithinWindow(int timestamp) =>
      (DateTime.now().millisecondsSinceEpoch ~/ 1000 - timestamp).abs() <=
      _timestampToleranceSeconds;

  // ==================== 会话与解密 ====================

  Future<_Session> _ensureSession(String base, {bool force = false}) async {
    final cached = _sessions[base];
    if (!force && cached != null && !cached.isExpired) {
      return cached;
    }
    final session = await _handshake(base);
    _sessions[base] = session;
    return session;
  }

  Future<_Session> _handshake(String base) async {
    final keyPair = await _x25519.newKeyPair();
    final clientPublic = await keyPair.extractPublicKey();
    final salt = _randomBytes(16);
    final body = jsonEncode({
      'client_public_key': base64Encode(clientPublic.bytes),
      'salt': base64Encode(salt),
    });

    final res = await _rawRequest(
      base,
      method: 'POST',
      path: '$_apiPrefix/handshake',
      query: '',
      body: body,
    );
    final map = _asMap(res.data);
    if (res.statusCode == 403 || res.statusCode == 401) {
      throw AppApiException(_errorMessage(res), statusCode: res.statusCode);
    }
    if (map == null || map['session_id'] == null) {
      throw const AppApiException('握手失败，请稍后重试');
    }

    final serverPublic = base64Decode(map['server_public_key'].toString());
    final respSalt = map['salt'] == null
        ? salt
        : base64Decode(map['salt'].toString());

    final shared = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey:
          SimplePublicKey(serverPublic, type: KeyPairType.x25519),
    );
    final key = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: respSalt,
      info: utf8.encode(_sessionKeyInfo),
    );
    final expiresIn = (map['expires_in'] as num?)?.toInt() ?? 3600;
    return _Session(
      id: map['session_id'].toString(),
      key: key,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn - 30)),
    );
  }

  Future<Map<String, dynamic>> _decryptEnvelope(
      _Session session, Map<String, dynamic> envelope) async {
    final iv = base64Decode(envelope['iv'].toString());
    final cipherText = base64Decode(envelope['data'].toString());
    final tag = base64Decode(envelope['tag'].toString());
    final clear = await _aes.decrypt(
      SecretBox(cipherText, nonce: iv, mac: Mac(tag)),
      secretKey: session.key,
    );
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! Map) {
      throw const _SessionExpiredException();
    }
    return Map<String, dynamic>.from(decoded);
  }

  // ==================== 工具 ====================

  String _encodeQuery(Map<String, String> params) => params.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  Uint8List _randomBytes(int length) {
    final rnd = Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = rnd.nextInt(256);
    }
    return bytes;
  }

  String _randomHex(int length) => _hex(_randomBytes(length));

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String? _nonEmpty(dynamic value) {
    final s = value?.toString();
    return (s == null || s.isEmpty) ? null : s;
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

  String _errorMessage(Response<dynamic> res) {
    final map = _asMap(res.data);
    final msg = map?['message'] ?? map?['msg'];
    if (msg != null && msg.toString().trim().isNotEmpty) return msg.toString();
    if (res.statusCode == 429) return '请求过于频繁，请稍后重试';
    if (res.statusCode == 403) return '客户端已被禁用';
    if (res.statusCode == 401) return '请求校验失败，请检查设备时间';
    return '请求失败，请稍后重试';
  }

  String _dioMessage(DioException e) {
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
}

/// 网站用户（会员）模型，字段对应后端 `models::User` 的序列化结果。
class AppUser {
  final String id;
  final String userName;
  final String nickName;
  final String email;
  final String phone;
  final String portrait;
  final int points;
  final int vipLevel;
  final DateTime? vipEndTime;
  final int groupId;

  const AppUser({
    required this.id,
    required this.userName,
    required this.nickName,
    required this.email,
    required this.phone,
    required this.portrait,
    required this.points,
    required this.vipLevel,
    required this.vipEndTime,
    required this.groupId,
  });

  String get displayName => nickName.trim().isNotEmpty ? nickName.trim() : userName;

  bool get isVip =>
      vipLevel > 0 && vipEndTime != null && vipEndTime!.isAfter(DateTime.now());

  String get vipLabel => vipLevel > 0 ? 'VIP$vipLevel' : '普通用户';

  bool get isAdmin => groupId == 1;

  static AppUser? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return AppUser(
      id: _asId(json['_id']),
      userName: _asString(json['user_name']),
      nickName: _asString(json['user_nick_name']),
      email: _asString(json['user_email']),
      phone: _asString(json['user_phone']),
      portrait: _asString(json['user_portrait']),
      points: _asInt(json['user_points']),
      vipLevel: _asInt(json['vip_level']),
      vipEndTime: _asDate(json['vip_end_time']),
      groupId: _asInt(json['group_id']),
    );
  }
}

String _asString(dynamic v) => v == null ? '' : v.toString();

int _asInt(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is double) return v.toInt();
  return int.tryParse(v.toString()) ?? 0;
}

String _asId(dynamic v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is Map && v['\$oid'] != null) return v['\$oid'].toString();
  return v.toString();
}

/// 兼容后端 MongoDB 扩展 JSON 的日期形态：
/// 毫秒整数 / 数字字符串 / ISO 字符串 / {"$date": ...} / {"$numberLong": "..."}
DateTime? _asDate(dynamic v) {
  if (v == null) return null;
  if (v is int) return DateTime.fromMillisecondsSinceEpoch(v).toLocal();
  if (v is double) return DateTime.fromMillisecondsSinceEpoch(v.toInt()).toLocal();
  if (v is String) {
    final s = v.trim();
    if (s.isEmpty) return null;
    final n = int.tryParse(s);
    if (n != null) return DateTime.fromMillisecondsSinceEpoch(n).toLocal();
    return DateTime.tryParse(s)?.toLocal();
  }
  if (v is Map) {
    if (v['\$date'] != null) return _asDate(v['\$date']);
    final n = v['\$numberLong'] ?? v['\$numberInt'];
    if (n != null) return _asDate(n);
  }
  return null;
}

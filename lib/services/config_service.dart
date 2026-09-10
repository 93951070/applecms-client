import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/site.dart';

final configServiceProvider = Provider((ref) => ConfigService());

class ConfigService {
  static const String keySites = 'cms_sites';
  static const String keyThemeMode = 'theme_mode';
  static const String keySiteName = 'site_name';

  static const String keyAnnouncement = 'announcement';
  static const String keyFavorites = 'favorites';
  static const String keyHistory = 'play_history';
  static const String keySkipConfigs = 'skip_configs';
  static const String keyHasAgreedTerms = 'has_agreed_terms';
  static const String keyPlayerVolume = 'player_volume';
  static const String keyAdBlockEnabled = 'enable_blockad';
  static const String keyAdBlockKeywords = 'ad_block_keywords';
  static const String keyAdBlockWhitelist = 'ad_block_whitelist';

  static const List<String> defaultAdKeywords = [
    'ads', 'union', 'click', 'p6p', 'pop', 'short.mp4', 'advert', 'adv.', 
    'guanggao', 'miaopai', '666216.com', 'v.it608.com', 'ovscic',
    '888216.com', '999216.com', '661216.com'
  ];

  static const List<String> defaultAdWhitelist = [
    '/video/', '_1080', '_720', '_480', '1080p', '720p', '/hls/video'
  ];

  Future<List<String>> getAdBlockKeywords() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(keyAdBlockKeywords) ?? defaultAdKeywords;
  }

  Future<void> setAdBlockKeywords(List<String> keywords) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(keyAdBlockKeywords, keywords);
  }

  Future<List<String>> getAdBlockWhitelist() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(keyAdBlockWhitelist) ?? defaultAdWhitelist;
  }

  Future<void> setAdBlockWhitelist(List<String> keywords) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(keyAdBlockWhitelist, keywords);
  }

  Future<bool> getAdBlockEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyAdBlockEnabled) ?? true;
  }

  Future<void> setAdBlockEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyAdBlockEnabled, enabled);
  }

  Future<bool> getHasAgreedTerms() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyHasAgreedTerms) ?? false;
  }

  Future<void> setHasAgreedTerms(bool agreed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyHasAgreedTerms, agreed);
  }

  Future<void> clearAllData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  Future<List<SiteConfig>> getSites() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList(keySites);
    if (data == null || data.isEmpty) {
      return [_defaultSite()];
    }
    return data.map((s) => SiteConfig.fromJson(jsonDecode(s))).toList();
  }

  // 内置默认站点（占位符，用户可在「视频源管理」修改 API 地址）
  SiteConfig _defaultSite() {
    return SiteConfig(
      key: 'default_local',
      name: '我的站点',
      api: 'http://your-domain.com/api/provide/vod',
      from: 'custom',
      disabled: false,
    );
  }

  /// 获取唯一的后端站点（只对接一个后端）
  Future<SiteConfig> getPrimarySite() async {
    final sites = await getSites();
    if (sites.isEmpty) return _defaultSite();
    return sites.first;
  }

  /// 保存唯一的后端站点
  Future<void> savePrimarySite(SiteConfig site) async {
    await saveSites([site]);
  }

  Future<void> saveSites(List<SiteConfig> sites) async {
    final prefs = await SharedPreferences.getInstance();
    final data = sites.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(keySites, data);
  }

  Future<String> getSiteName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(keySiteName) ?? 'EchoTV';
  }

  Future<void> setSiteName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keySiteName, name);
  }

  Future<String> getAnnouncement() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(keyAnnouncement) ?? '';
  }

  Future<void> setAnnouncement(String text) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyAnnouncement, text);
  }

  Future<ThemeMode> getThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString(keyThemeMode);
    if (mode == 'light') return ThemeMode.light;
    if (mode == 'dark') return ThemeMode.dark;
    return ThemeMode.system;
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyThemeMode, mode.toString().split('.').last);
  }

  Future<List<Favorite>> getFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList(keyFavorites);
    if (data == null) return [];
    return data.map((s) => Favorite.fromJson(jsonDecode(s))).toList();
  }

  Future<void> saveFavorites(List<Favorite> favorites) async {
    final prefs = await SharedPreferences.getInstance();
    final data = favorites.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(keyFavorites, data);
  }

  Future<List<PlayRecord>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList(keyHistory);
    if (data == null) return [];
    return data.map((s) => PlayRecord.fromJson(jsonDecode(s))).toList();
  }

  Future<void> saveHistory(List<PlayRecord> history) async {
    final prefs = await SharedPreferences.getInstance();
    final data = history.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(keyHistory, data);
  }

  Future<Map<String, SkipConfig>> getSkipConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(keySkipConfigs);
    if (data == null) return <String, SkipConfig>{};
    try {
      final Map<String, dynamic> jsonData = jsonDecode(data);
      final Map<String, SkipConfig> result = {};
      jsonData.forEach((key, value) {
        if (value != null) {
          result[key] = SkipConfig.fromJson(value as Map<String, dynamic>);
        }
      });
      return result;
    } catch (e) {
      debugPrint('Error loading skip configs: $e');
      return <String, SkipConfig>{};
    }
  }

  Future<void> saveSkipConfig(String key, SkipConfig config) async {
    final configs = await getSkipConfigs();
    configs[key] = config;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keySkipConfigs, jsonEncode(configs.map((key, value) => MapEntry(key, value.toJson()))));
  }

  Future<double> getPlayerVolume() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(keyPlayerVolume) ?? 0.5;
  }

  Future<void> setPlayerVolume(double volume) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(keyPlayerVolume, volume);
  }
}
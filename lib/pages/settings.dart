import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../services/config_service.dart';
import '../providers/settings_provider.dart';
import '../widgets/zen_ui.dart';
import '../widgets/edit_dialog.dart';
import '../widgets/update_gate.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String _version = 'v1.0.0';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  void _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _version = 'v${info.version}');
  }

  void _pushPage(Widget page) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => page),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isPC = screenWidth > 800;
    final horizontalPadding = isPC ? 48.0 : 24.0;

    return ZenScaffold(
      body: CustomScrollView(
        slivers: [
          const ZenSliverAppBar(
            title: '设置',
            subtitle: '偏好设置',
          ),

          // 2. 设置主体内容
          SliverPadding(
            padding: EdgeInsets.fromLTRB(horizontalPadding, 4, horizontalPadding, 8),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildSectionTitle('外观与偏好'),
                _buildSettingGroup([
                  _buildSelectionItem(
                    icon: LucideIcons.palette,
                    title: '主题模式',
                    value: _getThemeModeLabel(ref.watch(themeModelProvider)),
                    onTap: () => _showThemePicker(),
                  ),
                  _buildNavigationItem(
                    icon: LucideIcons.shieldCheck,
                    title: '广告拦截',
                    showDivider: false,
                    onTap: () => _pushPage(const AdBlockSettingsPage()),
                  ),
                ]),

                _buildSectionTitle('高级设置'),
                _buildSettingGroup([
                  _buildActionItem(
                    icon: LucideIcons.trash2,
                    title: '清除所有数据并重置',
                    onTap: _showClearDataConfirm,
                  ),
                  _buildNavigationItem(
                    icon: LucideIcons.shieldAlert,
                    title: '免责声明',
                    onTap: _showDisclaimer,
                  ),
                  _buildNavigationItem(
                    icon: LucideIcons.info,
                    title: '关于 EchoTV',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_version, style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontSize: 13)),
                        const SizedBox(width: 8),
                        Icon(LucideIcons.chevronRight, size: 14, color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.5)),
                      ],
                    ),
                    showDivider: false,
                    onTap: () => checkAppUpdate(context, ref, showNoUpdate: true),
                  ),
                ]),

                const SizedBox(height: 120),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  // --- 组件构建方法 ---

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 32, 0, 12),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.8),
        ),
      ),
    );
  }

  Widget _buildSettingGroup(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  Widget _buildBaseItem({
    Key? key,
    required IconData icon,
    required String title,
    Widget? trailing,
    VoidCallback? onTap,
    bool showDivider = true,
  }) {
    return Material(
      key: key,
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                    ),
                  ),
                  if (trailing != null) trailing,
                ],
              ),
            ),
            if (showDivider)
              Divider(
                height: 1,
                indent: 52,
                endIndent: 0,
                color: Theme.of(context).dividerColor,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionItem({required IconData icon, required String title, required String value, required VoidCallback onTap, bool showDivider = true}) {
    return _buildBaseItem(
      icon: icon,
      title: title,
      onTap: onTap,
      showDivider: showDivider,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontSize: 13)),
          const SizedBox(width: 4),
          Icon(LucideIcons.chevronRight, size: 14, color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.5)),
        ],
      ),
    );
  }

  Widget _buildNavigationItem({
    Key? key,
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    Widget? trailing,
    bool showDivider = true,
  }) {
    return _buildBaseItem(
      key: key,
      icon: icon,
      title: title,
      onTap: onTap,
      showDivider: showDivider,
      trailing: trailing ?? Icon(LucideIcons.chevronRight, size: 16, color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.5)),
    );
  }

  Widget _buildActionItem({required IconData icon, required String title, required VoidCallback onTap, bool showDivider = true}) {
    return _buildBaseItem(icon: icon, title: title, onTap: onTap, showDivider: showDivider);
  }

  // --- 数据转换与弹窗 ---

  String _getThemeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system: return '跟随系统';
      case ThemeMode.light: return '浅色';
      case ThemeMode.dark: return '深色';
    }
  }

  void _showThemePicker() {
    _showSimplePicker('选择主题模式', {
      ThemeMode.system: '跟随系统',
      ThemeMode.light: '浅色',
      ThemeMode.dark: '深色',
    }, ref.read(themeModelProvider), (mode) {
      ref.read(themeModelProvider.notifier).setThemeMode(mode as ThemeMode);
    });
  }

  void _showSimplePicker(String title, Map<dynamic, String> options, dynamic currentVal, Function(dynamic) onSelect) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final isPC = screenWidth > 800;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        constraints: BoxConstraints(
          maxWidth: isPC ? 500 : double.infinity,
        ),
        margin: isPC ? const EdgeInsets.only(bottom: 40) : EdgeInsets.zero,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: isPC ? BorderRadius.circular(28) : const BorderRadius.vertical(top: Radius.circular(32)),
          boxShadow: isPC ? [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 40)] : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isPC) 
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 36,
                height: 4,
                decoration: BoxDecoration(color: theme.dividerColor, borderRadius: BorderRadius.circular(2)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: options.entries.map((e) {
                    final isSelected = e.key == currentVal;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () {
                            onSelect(e.key);
                            Navigator.pop(context);
                          },
                          splashColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    e.value,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                      color: isSelected 
                                          ? (theme.brightness == Brightness.dark ? Colors.black : Colors.white) 
                                          : theme.colorScheme.onSurface,
                                    ),
                                  ),
                                ),
                                if (isSelected)
                                  Icon(
                                    LucideIcons.check, 
                                    size: 18, 
                                    color: theme.brightness == Brightness.dark ? Colors.black : Colors.white
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // --- 逻辑操作 (保持原有) ---

  void _showDisclaimer() {
    showDialog(
      context: context,
      builder: (context) => EditDialog(
        title: const Text('免责声明'),
        width: 460,
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'EchoTV 是一款纯粹的第三方聚合工具，致力于提升用户在不同平台上的视听体验。',
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            SizedBox(height: 16),
            Text('免责声明：', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text(
              '1. 本应用不提供任何内容源，所有内容均由用户自行配置。\n'
              '2. 应用对用户配置的内容不承担任何法律责任。\n'
              '3. 用户应当确保所使用的资源符合当地法律法规。',
              style: TextStyle(fontSize: 13, height: 1.6),
            ),
          ],
        ),
        actions: [
          ZenButton(
            isSecondary: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showClearDataConfirm() {
    showDialog(
      context: context,
      builder: (context) => EditDialog(
        title: const Text('确认清除数据？'),
        content: const Text('此操作将抹除所有站点配置、历史记录及偏好设置。应用将恢复到初始状态并需要重新同意用户协议。'),
        actions: [
          ZenButton(
            isSecondary: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ZenButton(
            backgroundColor: Colors.redAccent,
            onPressed: () async {
              await ref.read(configServiceProvider).clearAllData();
              exit(0); // 清除后退出，确保下次启动重新加载
            },
            child: const Text('确认清除并退出'),
          ),
        ],
      ),
    );
  }
}

class AdBlockSettingsPage extends ConsumerWidget {
  const AdBlockSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isPC = screenWidth > 800;
    final horizontalPadding = isPC ? 48.0 : 24.0;
    final theme = Theme.of(context);

    return ZenScaffold(
      body: CustomScrollView(
        slivers: [
          const ZenSliverAppBar(
            title: '广告拦截设置',
            subtitle: '精细化管理视频流过滤规则',
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(horizontalPadding, 16, horizontalPadding, 32),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildSettingGroup(context, [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(LucideIcons.shieldCheck,
                            size: 20,
                            color: theme.colorScheme.primary.withValues(alpha: 0.7)),
                        const SizedBox(width: 16),
                        const Expanded(
                          child: Text(
                            '广告过滤由服务端自动完成，无需在客户端设置。',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),
                  ),
                ]),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    '提示：服务端会识别并过滤 M3U8 中的广告分片，客户端直接播放处理后的播放列表。',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.secondary.withValues(alpha: 0.6),
                      height: 1.5,
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingGroup(BuildContext context, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

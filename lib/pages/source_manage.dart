import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/config_service.dart';
import '../models/site.dart';
import '../widgets/zen_ui.dart';

class SourceManagePage extends ConsumerStatefulWidget {
  const SourceManagePage({super.key});

  @override
  ConsumerState<SourceManagePage> createState() => _SourceManagePageState();
}

class _SourceManagePageState extends ConsumerState<SourceManagePage> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _apiController = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _apiController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final site = await ref.read(configServiceProvider).getPrimarySite();
    _nameController.text = site.name;
    _apiController.text = site.api;
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final api = _apiController.text.trim();
    if (api.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('API 地址不能为空'), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    final name = _nameController.text.trim();
    final site = SiteConfig(
      key: 'primary',
      name: name.isEmpty ? '我的站点' : name,
      api: api,
    );
    await ref.read(configServiceProvider).savePrimarySite(site);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPC = MediaQuery.of(context).size.width > 800;
    final horizontalPadding = isPC ? 48.0 : 24.0;

    return ZenScaffold(
      body: CustomScrollView(
        slivers: [
          const ZenSliverAppBar(
            title: '视频源管理',
            subtitle: '配置唯一的 CMS 后端接口',
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(horizontalPadding, 16, horizontalPadding, 16),
            sliver: SliverToBoxAdapter(
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.only(top: 60),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : ZenGlassContainer(
                      borderRadius: 20,
                      blur: 10,
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('名称', style: TextStyle(fontSize: 13, color: theme.colorScheme.secondary)),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _nameController,
                              decoration: InputDecoration(
                                hintText: '我的站点',
                                filled: true,
                                fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),
                            Text('API 地址', style: TextStyle(fontSize: 13, color: theme.colorScheme.secondary)),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _apiController,
                              keyboardType: TextInputType.url,
                              decoration: InputDecoration(
                                hintText: 'http://your-domain.com/api/provide/vod',
                                filled: true,
                                fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'App 会自动在该地址后追加参数（如 ?ac=videolist&wd=关键词&pg=页码）。',
                              style: TextStyle(fontSize: 12, color: theme.colorScheme.secondary.withValues(alpha: 0.7)),
                            ),
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              child: ZenButton(
                                onPressed: _save,
                                child: const Center(child: Text('保存')),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    );
  }
}

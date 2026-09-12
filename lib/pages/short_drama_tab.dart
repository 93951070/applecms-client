import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/content_kind.dart';
import '../core/theme.dart';
import '../models/site.dart';
import '../services/cms_service.dart';
import '../services/config_service.dart';
import 'short_drama_feed.dart';

/// 底部「短剧」Tab：进入时随机挑一部短剧，全屏竖屏随机上下滑。
class ShortDramaTabPage extends ConsumerStatefulWidget {
  const ShortDramaTabPage({super.key});

  @override
  ConsumerState<ShortDramaTabPage> createState() => _ShortDramaTabPageState();
}

class _ShortDramaTabPageState extends ConsumerState<ShortDramaTabPage> {
  VideoDetail? _initial;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRandom();
  }

  Future<void> _loadRandom() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cms = ref.read(cmsServiceProvider);
      final site = await ref.read(configServiceProvider).getPrimarySite();
      final list = await cms.getCategoryList(
        site,
        kShortDramaTypeId,
        page: 1,
        pageSize: 30,
        sort: 'day',
      );
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() {
          _error = '暂无短剧内容';
          _loading = false;
        });
        return;
      }
      final pool = List.of(list)..shuffle(Random());
      setState(() {
        _initial = pool.first;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '短剧加载失败，请稍后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: AppColors.pink)),
      );
    }
    final initial = _initial;
    if (initial == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error ?? '短剧加载失败',
                  style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _loadRandom,
                child: const Text('重新加载',
                    style: TextStyle(color: AppColors.pink)),
              ),
            ],
          ),
        ),
      );
    }
    return ShortDramaFeedPage(
      key: ValueKey('shortdrama-tab-${initial.id}'),
      typeId: kShortDramaTypeId,
      categoryTitle: '短剧',
      initial: initial,
      random: true,
      showBack: false,
    );
  }
}

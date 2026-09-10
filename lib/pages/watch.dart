import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../widgets/zen_ui.dart';

/// 一起看：占位页（原 App 未提供设计稿）
class WatchPage extends StatelessWidget {
  const WatchPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ZenScaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.construction_rounded,
                size: 48,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(height: 14),
              Text(
                '「一起看」页面待设计',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.secondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '敬请期待',
                style: TextStyle(
                  color: AppColors.pink.withValues(alpha: 0.8),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

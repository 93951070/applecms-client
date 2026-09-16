import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../providers/cast_provider.dart';

/// 投屏面板：搜索局域网 DLNA 设备并把当前播放地址推给电视。
///
/// 搜索依赖 SSDP 组播；系统屏蔽组播时可在面板内手动输入电视 IP 投屏。
class CastSheet extends ConsumerStatefulWidget {
  const CastSheet({
    super.key,
    required this.url,
    required this.title,
    this.onCastStarted,
  });

  /// 当前解析出的播放地址；为空时不允许投屏。
  final String url;

  /// 投给电视的标题（剧名 + 集名）。
  final String title;

  /// 投屏成功回调，用于暂停本机播放。
  final VoidCallback? onCastStarted;

  @override
  ConsumerState<CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends ConsumerState<CastSheet> {
  final TextEditingController _ipController = TextEditingController();
  late final DlnaCastNotifier _notifier = ref.read(dlnaCastProvider.notifier);
  bool _manualVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _notifier.discover();
    });
  }

  @override
  void dispose() {
    // 关闭面板即停止组播搜索，正在进行的投屏连接不受影响。
    _notifier.stopDiscovery();
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(dlnaCastProvider);
    final notifier = _notifier;
    final ready = widget.url.trim().isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 14),
            const Center(
              child: Text(
                '投屏到电视',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                ready ? '选择同一 Wi-Fi 下的电视即可开始播放' : '播放地址还没准备好，请稍后再试',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.secondary,
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (state.casting) _buildCastingCard(theme, state, notifier),
            Flexible(child: _buildDeviceList(theme, state, notifier)),
            if (state.error != null) _buildError(theme, state.error!),
            _buildManualEntry(notifier, ready),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  /// 投屏中：显示目标设备并提供停止入口。
  Widget _buildCastingCard(
    ThemeData theme,
    DlnaCastState state,
    DlnaCastNotifier notifier,
  ) {
    final device = state.castingDevice!;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.tv, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '正在投屏到',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.secondary,
                  ),
                ),
                Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => notifier.stopCasting(),
            child: const Text('停止投屏'),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceList(
    ThemeData theme,
    DlnaCastState state,
    DlnaCastNotifier notifier,
  ) {
    if (state.devices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state.scanning)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                LucideIcons.tvMinimal,
                size: 26,
                color: theme.colorScheme.secondary,
              ),
            const SizedBox(height: 10),
            Text(
              state.scanning ? '正在搜索设备…' : '暂未发现可投屏的电视',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.secondary,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: state.devices.length,
      itemBuilder: (context, i) {
        final device = state.devices[i];
        final active = state.castingDevice == device;
        return ListTile(
          leading: Icon(
            LucideIcons.tv,
            size: 22,
            color: active ? theme.colorScheme.primary : null,
          ),
          title: Text(
            device.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: device.host.isEmpty ? null : Text(device.host),
          trailing: state.phase == DlnaCastPhase.connecting && active
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: () => _cast(notifier, device),
        );
      },
    );
  }

  Widget _buildError(ThemeData theme, String message) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
      ),
    );
  }

  /// 手动输入 IP：为系统屏蔽组播的设备（如未申请组播权限的 iOS）保留通道。
  Widget _buildManualEntry(DlnaCastNotifier notifier, bool ready) {
    if (!_manualVisible) {
      return TextButton.icon(
        onPressed: () => setState(() => _manualVisible = true),
        icon: const Icon(LucideIcons.keyboard, size: 16),
        label: const Text('搜不到？手动输入电视 IP'),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ipController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '例如 192.168.1.100',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: ready ? () => _castByAddress(notifier) : null,
            child: const Text('投屏'),
          ),
        ],
      ),
    );
  }

  Future<void> _cast(DlnaCastNotifier notifier, DlnaCastDevice device) async {
    final error = await notifier.cast(
      device,
      url: widget.url,
      title: widget.title,
    );
    if (!mounted) return;
    if (error == null) {
      widget.onCastStarted?.call();
      _toast('已投屏到 ${device.name}');
      Navigator.of(context).pop();
    } else {
      _toast(error);
    }
  }

  Future<void> _castByAddress(DlnaCastNotifier notifier) async {
    FocusScope.of(context).unfocus();
    final error = await notifier.castToAddress(
      _ipController.text,
      url: widget.url,
      title: widget.title,
    );
    if (!mounted) return;
    if (error == null) {
      widget.onCastStarted?.call();
      _toast('已投屏到电视');
      Navigator.of(context).pop();
    } else {
      _toast(error);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }
}

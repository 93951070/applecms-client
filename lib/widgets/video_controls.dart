import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../models/site.dart';

class ZenDanmakuInputBar extends StatelessWidget {
  final bool active;
  final bool visible;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final VoidCallback? onActivate;
  final VoidCallback? onClose;
  final VoidCallback? onSubmit;

  const ZenDanmakuInputBar({
    super.key,
    required this.active,
    this.visible = true,
    this.controller,
    this.focusNode,
    this.onActivate,
    this.onClose,
    this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: active
            ? Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        maxLength: 50,
                        maxLines: 1,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => onSubmit?.call(),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: const InputDecoration(
                          hintText: '发个弹幕吧...',
                          hintStyle: TextStyle(color: Colors.white70, fontSize: 13),
                          counterText: '',
                          isDense: true,
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _barButton('发送', () => onSubmit?.call()),
                  const SizedBox(width: 6),
                  _barButton('取消', () => onClose?.call()),
                ],
              )
            : Row(
                children: [
                  Flexible(
                    child: GestureDetector(
                      onTap: onActivate,
                      child: Container(
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.edit_rounded, size: 14, color: Colors.white70),
                            SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                '发个弹幕吧...',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: Colors.white70, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _barButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Center(
          child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
      ),
    );
  }
}

class ZenEpisodeSheet extends StatelessWidget {
  final List<String> episodeTitles;
  final List<int> episodeNeedVip;
  final bool isVip;
  final int currentEpisodeIndex;
  final void Function(int index)? onSelect;

  const ZenEpisodeSheet({
    super.key,
    required this.episodeTitles,
    this.episodeNeedVip = const [],
    this.isVip = false,
    this.currentEpisodeIndex = 0,
    this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final total = episodeTitles.length;
    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        color: const Color(0xE6000000),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text(
                '选集 ($total)',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            Flexible(
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.3,
                ),
                itemCount: total,
                itemBuilder: (context, index) {
                  final selected = index == currentEpisodeIndex;
                  final locked = !isVip &&
                      index < episodeNeedVip.length &&
                      episodeNeedVip[index] > 0;
                  return GestureDetector(
                    onTap: () {
                      Navigator.of(context).pop();
                      onSelect?.call(index);
                    },
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? const Color(0xFF0A84FF)
                            : Colors.white10,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: selected
                              ? const Color(0xFF0A84FF)
                              : Colors.white24,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (locked) ...[
                            const Icon(Icons.lock,
                                color: Color(0xFFFFC24B), size: 10),
                            const SizedBox(width: 2),
                          ],
                          Text(
                            '${index + 1}',
                            style: TextStyle(
                              color: selected ? Colors.white : Colors.white70,
                              fontSize: 12,
                              fontWeight:
                                  selected ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ZenSkipSheet extends StatefulWidget {
  final SkipConfig initial;
  final Duration currentPosition;
  final Duration duration;
  final Function(SkipConfig)? onChanged;

  const ZenSkipSheet({
    super.key,
    required this.initial,
    this.currentPosition = Duration.zero,
    this.duration = Duration.zero,
    this.onChanged,
  });

  @override
  State<ZenSkipSheet> createState() => _ZenSkipSheetState();
}

class _ZenSkipSheetState extends State<ZenSkipSheet> {
  late SkipConfig _config;

  @override
  void initState() {
    super.initState();
    _config = widget.initial;
  }

  void _apply(SkipConfig config) {
    setState(() => _config = config);
    widget.onChanged?.call(config);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        color: const Color(0xE6000000),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text(
                '播放设置',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            SwitchListTile(
              value: _config.enable,
              onChanged: (val) => _apply(SkipConfig(
                enable: val,
                introTime: _config.introTime,
                outroTime: _config.outroTime,
              )),
              title: const Text('跳过片头片尾',
                  style: TextStyle(color: Colors.white, fontSize: 13)),
              activeTrackColor: const Color(0xFF0A84FF),
            ),
            ListTile(
              dense: true,
              title: const Text('设当前为片头',
                  style: TextStyle(color: Colors.white, fontSize: 13)),
              subtitle: Text(
                _config.introTime > 0 ? '${_config.introTime}s' : '未设置',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              onTap: () => _apply(SkipConfig(
                enable: true,
                introTime: widget.currentPosition.inSeconds,
                outroTime: _config.outroTime,
              )),
            ),
            ListTile(
              dense: true,
              title: const Text('设当前为片尾',
                  style: TextStyle(color: Colors.white, fontSize: 13)),
              subtitle: Text(
                _config.outroTime > 0 ? '跳过最后 ${_config.outroTime}s' : '未设置',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              onTap: () {
                final total = widget.duration.inSeconds;
                if (total <= 0) return;
                _apply(SkipConfig(
                  enable: true,
                  introTime: _config.introTime,
                  outroTime: total - widget.currentPosition.inSeconds,
                ));
              },
            ),
            ListTile(
              dense: true,
              title: const Text('重置跳过设置',
                  style: TextStyle(color: Colors.redAccent, fontSize: 13)),
              onTap: () => _apply(const SkipConfig(enable: false)),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class ZenLockButton extends StatelessWidget {
  final bool locked;
  final VoidCallback onToggle;

  const ZenLockButton({
    super.key,
    required this.locked,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 24),
        child: GestureDetector(
          onTap: onToggle,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.black38,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              locked ? LucideIcons.lock : LucideIcons.unlock,
              size: 22,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

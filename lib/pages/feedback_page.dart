import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../services/cms_service.dart';
import '../widgets/zen_ui.dart';

/// 意见反馈：提交内容到 App 网关，管理员可在后台查看。
class FeedbackPage extends ConsumerStatefulWidget {
  const FeedbackPage({super.key});

  @override
  ConsumerState<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends ConsumerState<FeedbackPage> {
  final TextEditingController _contentController = TextEditingController();
  final TextEditingController _contactController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _contentController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请填写反馈内容')));
      return;
    }
    setState(() => _submitting = true);
    try {
      final ok = await ref
          .read(cmsServiceProvider)
          .postFeedback(content, contact: _contactController.text.trim());
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '感谢您的反馈' : '提交失败，请稍后重试')),
      );
      if (ok) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('提交失败，请稍后重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ZenScaffold(
      body: CustomScrollView(
        slivers: [
          const ZenSliverAppBar(title: '意见反馈', subtitle: '我们重视您的每一条建议'),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: TextField(
                    controller: _contentController,
                    minLines: 5,
                    maxLines: 8,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      hintText: '请描述您遇到的问题或建议（1-500 字）',
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: TextField(
                    controller: _contactController,
                    maxLength: 100,
                    decoration: const InputDecoration(
                      hintText: '联系方式（选填）',
                      counterText: '',
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _submitting ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.pink,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('提交反馈',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

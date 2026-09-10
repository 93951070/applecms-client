import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../providers/auth_provider.dart';
import '../widgets/zen_ui.dart';

/// 独立登录 / 注册页（对接网站 /api/auth/login、/api/auth/register）
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _userCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();

  bool _isRegister = false;
  bool _obscure = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _userCtrl.dispose();
    _pwdCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _userCtrl.text.trim();
    final password = _pwdCtrl.text;
    final email = _emailCtrl.text.trim();

    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = '请输入用户名和密码');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = '密码至少 6 位');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final notifier = ref.read(authProvider.notifier);
    final err = _isRegister
        ? await notifier.register(username, password, email)
        : await notifier.login(username, password);

    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = err;
    });

    if (err == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_isRegister ? '注册成功，欢迎加入' : '登录成功'),
        duration: const Duration(seconds: 1),
      ));
      Navigator.of(context).maybePop();
    }
  }

  void _toggleMode() {
    setState(() {
      _isRegister = !_isRegister;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ZenScaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(Icons.arrow_back_ios_new,
                    size: 18, color: theme.colorScheme.onSurface),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 16),
                    Container(
                      width: 64,
                      height: 64,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFFF7EB0), AppColors.pink],
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.pink.withValues(alpha: 0.35),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.pets,
                          size: 32, color: Colors.white),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      _isRegister ? '创建账号' : '欢迎回来',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 24, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isRegister ? '注册后即可兑换会员卡密' : '登录以同步你的会员权益',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13, color: theme.colorScheme.secondary),
                    ),
                    const SizedBox(height: 30),
                    TextField(
                      controller: _userCtrl,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: _decoration(theme,
                          hint: '用户名', icon: Icons.person_outline_rounded),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _pwdCtrl,
                      obscureText: _obscure,
                      textInputAction: _isRegister
                          ? TextInputAction.next
                          : TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      decoration: _decoration(theme,
                              hint: '密码', icon: Icons.lock_outline_rounded)
                          .copyWith(
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setState(() => _obscure = !_obscure),
                          icon: Icon(
                            _obscure
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 20,
                            color: theme.colorScheme.secondary,
                          ),
                        ),
                      ),
                    ),
                    if (_isRegister) ...[
                      const SizedBox(height: 14),
                      TextField(
                        controller: _emailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        decoration: _decoration(theme,
                            hint: '邮箱（选填）',
                            icon: Icons.mail_outline_rounded),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.yearRed.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline,
                                size: 16, color: AppColors.yearRed),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                    fontSize: 12.5, color: AppColors.yearRed),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 26),
                    ZenButton(
                      height: 50,
                      backgroundColor: AppColors.pink,
                      onPressed: _submitting ? () {} : _submit,
                      child: _submitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Text(_isRegister ? '注册' : '登录',
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(height: 18),
                    Center(
                      child: TextButton(
                        onPressed: _submitting ? null : _toggleMode,
                        child: Text(
                          _isRegister ? '已有账号？去登录' : '还没有账号？立即注册',
                          style: TextStyle(
                              fontSize: 13,
                              color: isDark
                                  ? AppColors.pink
                                  : AppColors.pinkDeep),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _decoration(ThemeData theme,
      {required String hint, required IconData icon}) {
    return InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon, size: 20, color: theme.colorScheme.secondary),
      filled: true,
      fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 16),
    );
  }
}

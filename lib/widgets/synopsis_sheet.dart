import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/douban_media.dart';
import '../core/theme.dart';

/// 播放页「简介」底部弹层。
///
/// 优先展示豆瓣评分/简介/演职员头像；豆瓣不可用时回退到本地简介与演职员文本。
class SynopsisSheet extends StatelessWidget {
  final String title;
  final String? year;
  final String? typeName;
  final String localDesc;
  final String localActors;
  final String localDirectors;
  final Future<DoubanMedia?> future;

  /// 将豆瓣原图地址转换为服务端代理地址。
  final String Function(String raw) proxyImageUrl;

  const SynopsisSheet({
    super.key,
    required this.title,
    required this.year,
    required this.typeName,
    required this.localDesc,
    required this.localActors,
    required this.localDirectors,
    required this.future,
    required this.proxyImageUrl,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.78;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: FutureBuilder<DoubanMedia?>(
        future: future,
        builder: (context, snapshot) {
          final media = snapshot.data;
          return _buildBody(context, theme, media, snapshot.connectionState);
        },
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ThemeData theme,
    DoubanMedia? media,
    ConnectionState state,
  ) {
    final intro = _pick(
      media?.intro,
      localDesc,
    );
    final actors = media?.actors ?? const <DoubanCredit>[];
    final directors = media?.directors ?? const <DoubanCredit>[];
    final localActorNames = _splitNames(localActors);
    final localDirectorNames = _splitNames(localDirectors);
    final loading = state == ConnectionState.waiting;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: theme.colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 12, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ),
              GestureDetector(
                onTap: () => Navigator.of(context).maybePop(),
                child: Icon(LucideIcons.x,
                    size: 22, color: theme.colorScheme.secondary),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
          child: Row(
            children: [
              if (media?.rating != null) ...[
                Text(
                  media!.rating!.toStringAsFixed(1),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFF59E0B),
                  ),
                ),
                const SizedBox(width: 4),
                const Text('分',
                    style: TextStyle(fontSize: 11, color: Color(0xFFF59E0B))),
                const SizedBox(width: 12),
              ],
              if (loading)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: theme.colorScheme.secondary,
                  ),
                ),
              Expanded(
                child: Text(
                  _metaLine(media, year, typeName),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 11.5, color: theme.colorScheme.secondary),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Divider(height: 1),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionTitle('简介'),
                const SizedBox(height: 8),
                Text(
                  intro.isEmpty ? '暂无简介' : intro,
                  style: const TextStyle(fontSize: 13, height: 1.75),
                ),
                if (actors.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const _SectionTitle('主演'),
                  const SizedBox(height: 12),
                  _CreditGrid(
                    credits: actors,
                    proxyImageUrl: proxyImageUrl,
                    showCharacter: true,
                  ),
                ] else if (localActorNames.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const _SectionTitle('主演'),
                  const SizedBox(height: 10),
                  Text(
                    localActorNames.join('  /  '),
                    style: const TextStyle(fontSize: 13, height: 1.7),
                  ),
                ],
                if (directors.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const _SectionTitle('导演'),
                  const SizedBox(height: 12),
                  _CreditGrid(
                    credits: directors,
                    proxyImageUrl: proxyImageUrl,
                    showCharacter: false,
                  ),
                ] else if (localDirectorNames.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const _SectionTitle('导演'),
                  const SizedBox(height: 10),
                  Text(
                    localDirectorNames.join('  /  '),
                    style: const TextStyle(fontSize: 13, height: 1.7),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _pick(String? a, String b) {
    final av = (a ?? '').trim();
    if (av.isNotEmpty) return av;
    return b.trim();
  }

  static String _metaLine(DoubanMedia? media, String? year, String? typeName) {
    final parts = <String>[];
    final y = (media?.year ?? '').trim().isNotEmpty ? media!.year : (year ?? '');
    if (y.trim().isNotEmpty) parts.add(y.trim());
    if ((typeName ?? '').trim().isNotEmpty) parts.add(typeName!.trim());
    if (media?.episodes != null && media!.episodes! > 0) {
      parts.add('全 ${media.episodes} 集');
    }
    return parts.join(' · ');
  }

  static List<String> _splitNames(String raw) => raw
      .split(RegExp(r'[,，/、]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
    );
  }
}

class _CreditGrid extends StatelessWidget {
  final List<DoubanCredit> credits;
  final String Function(String raw) proxyImageUrl;
  final bool showCharacter;

  const _CreditGrid({
    required this.credits,
    required this.proxyImageUrl,
    required this.showCharacter,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: credits
          .map((c) => _CreditItem(
                credit: c,
                proxyImageUrl: proxyImageUrl,
                showCharacter: showCharacter,
              ))
          .toList(),
    );
  }
}

class _CreditItem extends StatelessWidget {
  final DoubanCredit credit;
  final String Function(String raw) proxyImageUrl;
  final bool showCharacter;

  const _CreditItem({
    required this.credit,
    required this.proxyImageUrl,
    required this.showCharacter,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatar = credit.avatar.trim();
    return SizedBox(
      width: 58,
      child: Column(
        children: [
          ClipOval(
            child: SizedBox(
              width: 50,
              height: 50,
              child: avatar.isEmpty
                  ? _fallback(theme)
                  : CachedNetworkImage(
                      imageUrl: proxyImageUrl(avatar),
                      fit: BoxFit.cover,
                      placeholder: (_, __) => _fallback(theme),
                      errorWidget: (_, __, ___) => _fallback(theme),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            credit.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          if (showCharacter && _character(credit.character).isNotEmpty)
            Text(
              _character(credit.character),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: theme.colorScheme.secondary),
            ),
        ],
      ),
    );
  }

  Widget _fallback(ThemeData theme) {
    final label = credit.name.isNotEmpty ? credit.name.characters.first : '?';
    return Container(
      color: AppColors.pink.withValues(alpha: 0.12),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.pink,
        ),
      ),
    );
  }

  static String _character(String raw) {
    var s = raw.trim();
    if (s.startsWith('饰')) {
      s = s.replaceFirst('饰', '').trim();
    }
    return s;
  }
}

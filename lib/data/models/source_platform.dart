import 'package:flutter/material.dart';

enum SourcePlatform {
  wechat,
  zhihu,
  web,
  x,
  bilibili,
  xiaohongshu,
  chatgpt,
  youtube,
  reddit,
  local;

  String get displayName {
    switch (this) {
      case SourcePlatform.wechat:
        return 'WeChat';
      case SourcePlatform.zhihu:
        return 'Zhihu';
      case SourcePlatform.web:
        return 'Web';
      case SourcePlatform.x:
        return 'X';
      case SourcePlatform.bilibili:
        return 'Bilibili';
      case SourcePlatform.xiaohongshu:
        return 'Rednote';
      case SourcePlatform.chatgpt:
        return 'ChatGPT';
      case SourcePlatform.youtube:
        return 'YouTube';
      case SourcePlatform.reddit:
        return 'Reddit';
      case SourcePlatform.local:
        return 'Local';
    }
  }

  String get shortLabel {
    switch (this) {
      case SourcePlatform.wechat:
        return 'WX';
      case SourcePlatform.zhihu:
        return '知乎';
      case SourcePlatform.web:
        return 'Web';
      case SourcePlatform.x:
        return 'X';
      case SourcePlatform.bilibili:
        return 'B站';
      case SourcePlatform.xiaohongshu:
        return '小红书';
      case SourcePlatform.chatgpt:
        return 'GPT';
      case SourcePlatform.youtube:
        return 'YT';
      case SourcePlatform.reddit:
        return 'RD';
      case SourcePlatform.local:
        return '本地';
    }
  }

  IconData get icon {
    switch (this) {
      case SourcePlatform.wechat:
        return Icons.forum_rounded;
      case SourcePlatform.zhihu:
        return Icons.psychology_alt_rounded;
      case SourcePlatform.web:
        return Icons.language_rounded;
      case SourcePlatform.x:
        return Icons.alternate_email_rounded;
      case SourcePlatform.bilibili:
        return Icons.smart_display_rounded;
      case SourcePlatform.xiaohongshu:
        return Icons.auto_awesome_rounded;
      case SourcePlatform.chatgpt:
        return Icons.bolt_rounded;
      case SourcePlatform.youtube:
        return Icons.play_circle_fill_rounded;
      case SourcePlatform.reddit:
        return Icons.chat_bubble_rounded;
      case SourcePlatform.local:
        return Icons.description_outlined;
    }
  }

  Color get accentColor {
    switch (this) {
      case SourcePlatform.wechat:
        return const Color(0xFF09B83E);
      case SourcePlatform.zhihu:
        return const Color(0xFF1677FF);
      case SourcePlatform.web:
        return const Color(0xFF00AEEF);
      case SourcePlatform.x:
        return const Color(0xFF0F172A);
      case SourcePlatform.bilibili:
        return const Color(0xFFFB7299);
      case SourcePlatform.xiaohongshu:
        return const Color(0xFFFF355D);
      case SourcePlatform.chatgpt:
        return const Color(0xFF10A37F);
      case SourcePlatform.youtube:
        return const Color(0xFFFF0033);
      case SourcePlatform.reddit:
        return const Color(0xFFFF5700);
      case SourcePlatform.local:
        return const Color(0xFF00AEEF);
    }
  }

  Color iconColor({required bool isDark}) {
    if (isDark && accentColor.computeLuminance() < 0.3) {
      return Colors.white;
    }
    return accentColor;
  }

  static SourcePlatform fromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return SourcePlatform.web;

    final host = uri.host.toLowerCase();
    if (host.isEmpty) return SourcePlatform.web;

    if (uri.scheme == 'file') return SourcePlatform.local;

    if (_matchesAny(host, const [
      'weixin.qq.com',
      'wechat.com',
      'weixin.com',
    ])) {
      return SourcePlatform.wechat;
    }

    if (_matchesAny(host, const ['zhihu.com'])) {
      return SourcePlatform.zhihu;
    }

    if (_matchesAny(host, const ['x.com', 'twitter.com', 't.co'])) {
      return SourcePlatform.x;
    }

    if (_matchesAny(host, const ['bilibili.com', 'b23.tv'])) {
      return SourcePlatform.bilibili;
    }

    if (_matchesAny(host, const ['xiaohongshu.com', 'xhslink.com'])) {
      return SourcePlatform.xiaohongshu;
    }

    if (_matchesAny(host, const ['chatgpt.com', 'openai.com'])) {
      return SourcePlatform.chatgpt;
    }

    if (_matchesAny(host, const ['youtube.com', 'youtu.be'])) {
      return SourcePlatform.youtube;
    }

    if (_matchesAny(host, const ['reddit.com', 'redd.it'])) {
      return SourcePlatform.reddit;
    }

    return SourcePlatform.web;
  }

  // Matches a host against registrable-domain patterns. A pattern matches when
  // the host equals it exactly or is a subdomain of it (e.g. 'zhuanlan.zhihu.com'
  // matches 'zhihu.com'). This avoids substring false positives such as
  // 'netflix.com' matching 'x.com'.
  static bool _matchesAny(String host, List<String> domains) {
    for (final domain in domains) {
      if (host == domain || host.endsWith('.$domain')) {
        return true;
      }
    }
    return false;
  }
}

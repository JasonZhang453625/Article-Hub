enum SourcePlatform {
  wechat,
  zhihu,
  generic;

  String get displayName {
    switch (this) {
      case SourcePlatform.wechat:
        return 'WeChat';
      case SourcePlatform.zhihu:
        return 'Zhihu';
      case SourcePlatform.generic:
        return 'Web';
    }
  }

  static SourcePlatform fromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return SourcePlatform.generic;

    final host = uri.host.toLowerCase();

    if (host.contains('weixin') ||
        host.contains('mp.weixin') ||
        host.contains('wechat') ||
        host.contains('weixin.qq')) {
      return SourcePlatform.wechat;
    }

    if (host.contains('zhihu') || host.contains('zhuanlan.zhihu')) {
      return SourcePlatform.zhihu;
    }

    return SourcePlatform.generic;
  }
}

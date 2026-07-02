import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/models/source_platform.dart';

void main() {
  group('SourcePlatform.fromUrl', () {
    test('detects canonical domains', () {
      expect(SourcePlatform.fromUrl('https://x.com/user/status/1'),
          SourcePlatform.x);
      expect(SourcePlatform.fromUrl('https://twitter.com/user'),
          SourcePlatform.x);
      expect(SourcePlatform.fromUrl('https://t.co/abc'), SourcePlatform.x);
      expect(SourcePlatform.fromUrl('https://www.bilibili.com/video/BV1'),
          SourcePlatform.bilibili);
      expect(SourcePlatform.fromUrl('https://b23.tv/abc'),
          SourcePlatform.bilibili);
      expect(SourcePlatform.fromUrl('https://www.youtube.com/watch?v=1'),
          SourcePlatform.youtube);
      expect(SourcePlatform.fromUrl('https://youtu.be/abc'),
          SourcePlatform.youtube);
      expect(SourcePlatform.fromUrl('https://www.reddit.com/r/flutter'),
          SourcePlatform.reddit);
    });

    test('detects subdomains of registrable domains', () {
      expect(SourcePlatform.fromUrl('https://zhuanlan.zhihu.com/p/123'),
          SourcePlatform.zhihu);
      expect(SourcePlatform.fromUrl('https://mp.weixin.qq.com/s/abc'),
          SourcePlatform.wechat);
      expect(SourcePlatform.fromUrl('https://chat.openai.com/c/abc'),
          SourcePlatform.chatgpt);
      expect(SourcePlatform.fromUrl('https://chatgpt.com/c/abc'),
          SourcePlatform.chatgpt);
      expect(SourcePlatform.fromUrl('https://www.xiaohongshu.com/explore'),
          SourcePlatform.xiaohongshu);
      expect(SourcePlatform.fromUrl('https://xhslink.com/abc'),
          SourcePlatform.xiaohongshu);
    });

    test('does not false-positive on substring collisions (regression)', () {
      // 'netflix.com' contains the substring 'x.com' but is NOT X/Twitter.
      expect(SourcePlatform.fromUrl('https://www.netflix.com/title/1'),
          SourcePlatform.web);
      // 'linux.com' also contains 'x.com'.
      expect(SourcePlatform.fromUrl('https://www.linux.com/news'),
          SourcePlatform.web);
      // A domain merely ending in a brand word should not match the brand.
      expect(SourcePlatform.fromUrl('https://notzhihu.com/p/1'),
          SourcePlatform.web);
      expect(SourcePlatform.fromUrl('https://fakemedium.com/post'),
          SourcePlatform.web);
    });

    test('falls back to web for unknown or invalid input', () {
      expect(SourcePlatform.fromUrl('https://example.com/article'),
          SourcePlatform.web);
      expect(SourcePlatform.fromUrl('not a url'), SourcePlatform.web);
      expect(SourcePlatform.fromUrl(''), SourcePlatform.web);
      // No host (e.g. a bare scheme) falls back to web.
      expect(SourcePlatform.fromUrl('https://'), SourcePlatform.web);
    });

    test('is case-insensitive on host', () {
      expect(SourcePlatform.fromUrl('https://WWW.YouTube.COM/watch?v=1'),
          SourcePlatform.youtube);
    });
  });
}

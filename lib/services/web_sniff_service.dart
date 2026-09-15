import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// web嗅探服务。
///
/// 用无界面（headless）WebView 打开服务端下发的解析站页面，在页面脚本运行前
/// 注入钩子拦截 XHR / fetch / hls.js / video 元素的媒体请求，嗅出真正的播放地址
/// 后返回。全程不创建路由、不渲染任何界面，对用户完全无感。
///
/// 播放地址不限于 `.m3u8`：解析站也会直接播放 `.mp4`/`.mov`/`.mkv`/`.webm`/
/// `.mpd` 等格式，因此嗅探按「来源 + 格式」打分挑选，而不是只认 m3u8。
///
/// 为提升被风控站点的通过率，嗅探时使用真实移动端 UA、持久化站点 Cookie，
/// 并注入反自动化脚本修正 WebView 特征。
///
/// 页面自身的播放会被强制静音：无界面 WebView 里的音轨用户看不到画面，
/// 却会盖在播放器上出声，必须在源头掐掉。
class WebSniffService {
  static final Set<_SniffSession> _sessions = <_SniffSession>{};

  /// 打开解析页并嗅探，成功返回直链，失败或超时返回 null。
  ///
  /// 超时压到 8 秒：超过后立刻判定失败，由调用方回传让服务端换源，
  /// 避免用户长时间卡在加载页；多数解析页在 3~5 秒内即可嗅到直链。
  static Future<String?> sniff(
    String url, {
    Duration timeout = const Duration(seconds: 8),
    Object? owner,
  }) async {
    final session = _SniffSession(url, timeout, owner);
    _sessions.add(session);
    try {
      return await session.run();
    } finally {
      _sessions.remove(session);
    }
  }

  /// 立即中断在飞的嗅探。
  ///
  /// 用户离开当前页面时调用：无界面 WebView 不在 widget 树里，不会随页面
  /// 销毁，必须显式 dispose，否则它会继续加载、继续出声。
  ///
  /// [owner] 用于只中断某个调用方（通常是页面 State）发起的嗅探，
  /// 避免页面之间互相打断：不传则中断全部。
  static void abortAll({Object? owner}) {
    for (final s in List<_SniffSession>.of(_sessions)) {
      if (owner == null || identical(s.owner, owner)) s.abort();
    }
  }

  static Future<void> _restoreCookies(String url) async {
    try {
      final uri = WebUri(url);
      if (uri.host.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cookieKey(uri.host));
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      final manager = CookieManager.instance();
      for (final item in list) {
        if (item is! Map) continue;
        final name = item['name']?.toString() ?? '';
        final value = item['value']?.toString() ?? '';
        if (name.isEmpty) continue;
        await manager.setCookie(
          url: uri,
          name: name,
          value: value,
          domain: item['domain']?.toString(),
          path: item['path']?.toString() ?? '/',
          isSecure: item['secure'] == true,
          isHttpOnly: item['httpOnly'] == true,
        );
      }
    } catch (_) {}
  }

  static Future<void> _saveCookies(String url) async {
    try {
      final uri = WebUri(url);
      if (uri.host.isEmpty) return;
      final cookies = await CookieManager.instance().getCookies(url: uri);
      if (cookies.isEmpty) return;
      final data = cookies
          .map((c) => {
                'name': c.name,
                'value': c.value,
                'domain': c.domain,
                'path': c.path,
                'secure': c.isSecure,
                'httpOnly': c.isHttpOnly,
              })
          .toList();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cookieKey(uri.host), jsonEncode(data));
    } catch (_) {}
  }

  static String _cookieKey(String host) => 'websniff_cookies_$host';
}

/// 一次嗅探会话：负责 WebView 生命周期、候选收集与打分挑选。
class _SniffSession {
  _SniffSession(this.url, this.timeout, this.owner);

  final String url;
  final Duration timeout;

  /// 发起本次嗅探的调用方，用于精确中断。
  final Object? owner;

  /// 首个有效候选出现后再多等一小段，攒够同一页面的多个媒体请求，
  /// 避免「第一个请求恰是广告/音频清单」被误选。
  static const Duration _settle = Duration(milliseconds: 500);

  /// 结算窗口的顺延上限：期间不断出现更高分的候选时，最多等这么久，
  /// 防止一直等不到「最优」而拖到整体超时。
  static const Duration _settleCap = Duration(milliseconds: 1600);

  final Completer<String?> _completer = Completer<String?>();
  final List<_Candidate> _candidates = <_Candidate>[];

  HeadlessInAppWebView? _webView;
  Timer? _timeoutTimer;
  Timer? _settleTimer;
  int _seq = 0;
  bool _done = false;
  int _bestScore = 0;
  DateTime? _firstHitAt;
  DateTime? _lastImproveAt;

  Future<String?> run() async {
    await WebSniffService._restoreCookies(url);
    if (_done) return _completer.future;

    final isIOS = Platform.isIOS;
    _webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        // 真实移动端 UA，避免默认 WebView 标识被风控直接拦。
        userAgent: isIOS ? _iosUserAgent : _androidUserAgent,
        preferredContentMode: UserPreferredContentMode.MOBILE,
        javaScriptEnabled: true,
        domStorageEnabled: true,
        // 页面必须能自动播放才能触发真实媒体请求（嗅探依赖它），
        // 声音由注入脚本强制静音处理。
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        // 与系统 Cookie 存储共享，并允许第三方 Cookie，便于复用风控下发的凭证。
        sharedCookiesEnabled: true,
        thirdPartyCookiesEnabled: true,
        cacheEnabled: true,
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: _stealthScript(isIOS: isIOS),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
        // 静音必须在嗅探脚本之前挂载，页面一出声就被掐掉。
        UserScript(
          source: _muteJs,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
        UserScript(
          source: _sniffJs,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
      ]),
      onWebViewCreated: (controller) {
        controller.addJavaScriptHandler(
          handlerName: 'echoSniff',
          callback: (args) {
            final raw = args.isNotEmpty ? args.first?.toString() ?? '' : '';
            final kind = args.length > 1 ? args[1]?.toString() ?? '' : '';
            _onHit(raw, kind);
            return null;
          },
        );
      },
      // Android 兜底：直接观察子资源请求里的媒体地址（iOS 不会回调 http(s)）。
      shouldInterceptRequest: (controller, request) async {
        _onHit(request.url.toString(), 'net');
        return null;
      },
      // 主文档被 WAF/风控直接拒绝（403/418 等）时快速失败。
      onReceivedHttpError: (controller, request, errorResponse) {
        final status = errorResponse.statusCode ?? 0;
        if (status == 401 || status == 403 || status == 418 || status == 429) {
          finish(null);
        }
      },
      onLoadStop: (controller, _) {
        controller.evaluateJavascript(source: _muteJs);
        controller.evaluateJavascript(source: _sniffJs);
      },
    );

    _timeoutTimer = Timer(timeout, () => finish(null));
    try {
      await _webView!.run();
    } catch (_) {
      finish(null);
    }
    return _completer.future;
  }

  /// 中断嗅探并返回 null，同时释放 WebView（连带停掉页面内的声音）。
  void abort() => finish(null);

  void finish(String? result) {
    if (_done) return;
    _done = true;
    _timeoutTimer?.cancel();
    _settleTimer?.cancel();
    unawaited(WebSniffService._saveCookies(url));
    final view = _webView;
    _webView = null;
    if (view != null) {
      try {
        unawaited(view.dispose());
      } catch (_) {}
    }
    if (!_completer.isCompleted) _completer.complete(result);
  }

  void _onHit(String raw, String kind) {
    if (_done) return;
    final hit = raw.trim();
    if (hit.isEmpty) return;
    // 解析站被 WAF 拦截（返回人机验证页）时，脚本会回传该哨兵值，
    // 立即判定失败让上层换源，不再干等超时。
    if (hit == _wafSentinel) {
      finish(null);
      return;
    }
    final candidate = _Candidate.of(hit, kind, _seq++);
    if (candidate == null) return;
    _candidates.add(candidate);
    final now = DateTime.now();
    _firstHitAt ??= now;
    if (candidate.score >= _bestScore) {
      _bestScore = candidate.score;
      _lastImproveAt = now;
    }
    _schedulePick(now);
  }

  /// 出现新候选后重排结算时机：以最后一次「更优候选」为起点等 [_settle]，
  /// 但整体不超过 [_settleCap]。
  void _schedulePick(DateTime now) {
    final first = _firstHitAt;
    if (first == null) return;
    final elapsed = now.difference(first);
    _settleTimer?.cancel();
    if (elapsed >= _settleCap) {
      _pick();
      return;
    }
    final lastImprove = _lastImproveAt ?? first;
    final sinceImprove = now.difference(lastImprove);
    var wait = sinceImprove >= _settle ? Duration.zero : _settle - sinceImprove;
    final remaining = _settleCap - elapsed;
    if (wait > remaining) wait = remaining;
    _settleTimer = Timer(wait, _pick);
  }

  void _pick() {
    if (_done) return;
    if (_candidates.isEmpty) {
      finish(null);
      return;
    }
    _candidates.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      // 同分取更晚出现的：解析站正常播放的地址通常在最后一刻才落地。
      return byScore != 0 ? byScore : b.seq.compareTo(a.seq);
    });
    finish(_candidates.first.url);
  }
}

/// 一个嗅探候选地址及其打分。
class _Candidate {
  _Candidate(this.url, this.score, this.seq);

  final String url;
  final int score;
  final int seq;

  static final RegExp _directMedia = RegExp(
    r'\.(mp4|m4v|mov|mkv|webm|flv|f4v|avi|mpd|ism|m3u8)(\?|#|$)',
    caseSensitive: false,
  );

  /// 分片、音频、图片、脚本等噪音：不是可播放的完整媒体地址。
  static final RegExp _noise = RegExp(
    r'\.(ts|m4s|m4a|aac|mp3|ogg|ac3|jpg|jpeg|png|gif|webp|bmp|'
    r'css|js|json|map|html?|svg|woff2?|ttf)(\?|#|$)',
    caseSensitive: false,
  );

  static const List<String> _adHosts = <String>[
    'doubleclick.net',
    'googlesyndication.com',
    'google-analytics.com',
    'googletagmanager.com',
    'adsystem.com',
    'adservice',
    'adtrack',
    'umeng',
    'cnzz',
    'hm.baidu.com',
    '/ad/',
    '.ads.',
  ];

  /// 来源权重：页面自身 video 元素播放的东西最可信，其次是 hls.js 载入的清单，
  /// 最后才是普通网络请求。audio 元素单独降级，避免把背景音乐/音频轨当成正片。
  static final Map<String, int> _kindWeight = <String, int>{
    'video': 40,
    'hls': 30,
    'net': 20,
    'audio': 5,
  };

  static _Candidate? of(String raw, String kind, int seq) {
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) return null;
    final lower = raw.toLowerCase();
    if (_noise.hasMatch(lower)) return null;
    for (final ad in _adHosts) {
      if (lower.contains(ad)) return null;
    }
    final base = _kindWeight[kind] ?? 0;
    final isMedia = _directMedia.hasMatch(lower);
    // 普通网络请求、音频元素里没有媒体后缀的地址噪音太大，直接丢弃；
    // video / hls.js 来源的地址是页面自己在播的内容，允许没有后缀。
    if (!isMedia && (kind == 'net' || kind == 'audio')) return null;
    if (base == 0) return null;
    var score = base;
    if (isMedia) score += 12;
    if (lower.contains('.m3u8')) score += 4;
    return _Candidate(raw, score, seq);
  }
}

const String _iosUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';

const String _androidUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36';

/// WAF 验证页哨兵值：页面脚本识别到人机验证后回传，触发快速失败。
const String _wafSentinel = '__ECHO_WAF__';

/// 修正 WebView 的自动化特征，降低被风控识别的概率。
String _stealthScript({required bool isIOS}) {
  final platform = isIOS ? 'iPhone' : 'Linux armv8l';
  final vendor = isIOS ? 'Apple Computer, Inc.' : 'Google Inc.';
  final glVendor = isIOS ? 'Apple Inc.' : 'Qualcomm';
  final glRenderer = isIOS ? 'Apple GPU' : 'Adreno (TM) 640';
  return '''
(function () {
  try { Object.defineProperty(navigator, 'webdriver', { get: function () { return false; } }); } catch (e) {}
  try { Object.defineProperty(navigator, 'languages', { get: function () { return ['zh-CN', 'zh', 'en']; } }); } catch (e) {}
  try { Object.defineProperty(navigator, 'plugins', { get: function () { return [1, 2, 3, 4, 5]; } }); } catch (e) {}
  try { Object.defineProperty(navigator, 'hardwareConcurrency', { get: function () { return 8; } }); } catch (e) {}
  try { Object.defineProperty(navigator, 'deviceMemory', { get: function () { return 8; } }); } catch (e) {}
  try { Object.defineProperty(navigator, 'platform', { get: function () { return '$platform'; } }); } catch (e) {}
  try { Object.defineProperty(navigator, 'vendor', { get: function () { return '$vendor'; } }); } catch (e) {}
  try { if (!window.chrome) { window.chrome = {}; } if (!window.chrome.runtime) { window.chrome.runtime = {}; } } catch (e) {}
  try {
    var gp = WebGLRenderingContext.prototype.getParameter;
    WebGLRenderingContext.prototype.getParameter = function (p) {
      if (p === 37445) { return '$glVendor'; }
      if (p === 37446) { return '$glRenderer'; }
      return gp.apply(this, arguments);
    };
  } catch (e) {}
  try {
    var oq = navigator.permissions && navigator.permissions.query;
    if (oq) {
      navigator.permissions.query = function (params) {
        if (params && params.name === 'notifications') { return Promise.resolve({ state: 'prompt' }); }
        return oq.apply(this, arguments);
      };
    }
  } catch (e) {}
})();
''';
}

/// 强制静音：无界面 WebView 里播放的媒体没有画面可看，却会出声，
/// 会盖住真正的播放器。这里把所有 media 元素的音量压到 0 并保持。
const String _muteJs = r'''
(function () {
  if (window.__echoMuted) return;
  window.__echoMuted = true;
  function silence(el) {
    try { el.muted = true; } catch (e) {}
    try { el.volume = 0; } catch (e) {}
    try { el.autoplay = false; } catch (e) {}
  }
  function killAll() {
    try {
      var nodes = document.querySelectorAll('video,audio');
      for (var i = 0; i < nodes.length; i++) { silence(nodes[i]); }
    } catch (e) {}
  }
  try { killAll(); setInterval(killAll, 500); } catch (e) {}
  try {
    var proto = HTMLMediaElement.prototype;
    var volumeDesc = Object.getOwnPropertyDescriptor(proto, 'volume');
    if (volumeDesc && volumeDesc.set && volumeDesc.get) {
      Object.defineProperty(proto, 'volume', {
        configurable: true,
        get: function () { try { return volumeDesc.get.call(this); } catch (e) { return 0; } },
        set: function () { try { volumeDesc.set.call(this, 0); } catch (e) {} }
      });
    }
    var _play = proto.play;
    if (_play) {
      proto.play = function () {
        silence(this);
        return _play.apply(this, arguments);
      };
    }
  } catch (e) {}
})();
''';

/// 在页面脚本之前挂载嗅探钩子：video 元素、XHR / fetch、hls.js 的媒体请求
/// 都会被捕获并按来源上报（video / hls / net），由 Dart 侧统一打分挑选。
const String _sniffJs = r'''
(function () {
  if (window.__echoSniffHooked) return;
  window.__echoSniffHooked = true;
  function report(u, kind) {
    try {
      if (typeof u !== 'string' || u.length === 0) return;
      if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
      var abs = u;
      try { abs = new URL(u, location.href).href; } catch (e) {}
      window.flutter_inappwebview.callHandler('echoSniff', abs, kind || 'net');
    } catch (e) {}
  }
  // 识别 WAF 人机验证页：命中后立即回传哨兵，让上层秒速换源。
  var wafReported = false;
  function checkWaf() {
    if (wafReported) return;
    try {
      var title = document.title || '';
      var text = title + ' ' + ((document.body && document.body.innerText) || '').slice(0, 500);
      var hasWafScript = !!document.querySelector('script[src*="/_waf/"]');
      if (hasWafScript ||
          text.indexOf('人机验证') >= 0 ||
          text.indexOf('Security Check') >= 0 ||
          text.indexOf('安全验证') >= 0 ||
          text.indexOf('点击验证') >= 0) {
        wafReported = true;
        window.flutter_inappwebview.callHandler('echoSniff', '__ECHO_WAF__', 'waf');
      }
    } catch (e) {}
  }
  try {
    var _open = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (m, u) {
      try { report(u, 'net'); } catch (e) {}
      return _open.apply(this, arguments);
    };
  } catch (e) {}
  try {
    var _fetch = window.fetch;
    if (_fetch) {
      window.fetch = function (input, init) {
        try { report(typeof input === 'string' ? input : (input && input.url), 'net'); } catch (e) {}
        return _fetch.apply(this, arguments);
      };
    }
  } catch (e) {}
  function hookHls(H) {
    try {
      if (H && H.prototype && !H.prototype.__echoHooked) {
        var ls = H.prototype.loadSource;
        if (ls) {
          H.prototype.loadSource = function (u) {
            try { report(u, 'hls'); } catch (e) {}
            return ls.apply(this, arguments);
          };
        }
        H.prototype.__echoHooked = true;
      }
    } catch (e) {}
  }
  try { hookHls(window.Hls); } catch (e) {}
  try {
    var _hls;
    Object.defineProperty(window, 'Hls', {
      configurable: true,
      get: function () { return _hls; },
      set: function (v) { _hls = v; try { hookHls(v); } catch (e) {} }
    });
  } catch (e) {}
  try {
    setInterval(function () {
      try {
        checkWaf();
        var videos = document.querySelectorAll('video');
        for (var i = 0; i < videos.length; i++) {
          var v = videos[i];
          report(v.currentSrc || v.src || '', 'video');
          var srcs = v.querySelectorAll ? v.querySelectorAll('source') : [];
          for (var j = 0; j < srcs.length; j++) { report(srcs[j].src || '', 'video'); }
        }
        var audios = document.querySelectorAll('audio');
        for (var k = 0; k < audios.length; k++) {
          report(audios[k].currentSrc || audios[k].src || '', 'audio');
        }
      } catch (e) {}
    }, 800);
  } catch (e) {}
})();
''';

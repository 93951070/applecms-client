import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// web嗅探服务。
///
/// 用无界面（headless）WebView 打开服务端下发的解析站页面，在页面脚本运行前
/// 注入钩子拦截 XHR / fetch / hls.js 的清单请求，嗅出真正的 `.m3u8` 地址后返回。
/// 全程不创建路由、不渲染任何界面，对用户完全无感。
///
/// 为提升被风控站点的通过率，嗅探时使用真实移动端 UA、持久化站点 Cookie，
/// 并注入反自动化脚本修正 WebView 特征。
class WebSniffService {
  /// 打开解析页并嗅探，成功返回直链，失败或超时返回 null。
  ///
  /// 超时压到 8 秒：超过后立刻判定失败，由调用方回传让服务端换源，
  /// 避免用户长时间卡在加载页；多数解析页在 3~5 秒内即可嗅到直链。
  static Future<String?> sniff(
    String url, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final completer = Completer<String?>();
    HeadlessInAppWebView? webView;
    Timer? timer;

    await _restoreCookies(url);

    void finish(String? result) {
      if (completer.isCompleted) return;
      timer?.cancel();
      unawaited(_saveCookies(url));
      try {
        webView?.dispose();
      } catch (_) {}
      completer.complete(result);
    }

    void onHit(Object? raw) {
      final hit = raw?.toString() ?? '';
      if (hit.isEmpty) return;
      // 解析站被 WAF 拦截（返回人机验证页）时，脚本会回传该哨兵值，
      // 立即判定失败让上层换源，不再干等超时。
      if (hit == _wafSentinel) {
        finish(null);
        return;
      }
      if (!hit.toLowerCase().contains('.m3u8')) return;
      finish(hit);
    }

    final isIOS = Platform.isIOS;
    webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        // 真实移动端 UA，避免默认 WebView 标识被风控直接拦。
        userAgent: isIOS ? _iosUserAgent : _androidUserAgent,
        preferredContentMode: UserPreferredContentMode.MOBILE,
        javaScriptEnabled: true,
        domStorageEnabled: true,
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
            if (args.isNotEmpty) onHit(args.first);
            return null;
          },
        );
      },
      // Android 兜底：直接观察子资源请求里的 m3u8（iOS 不会回调 http(s)）。
      shouldInterceptRequest: (controller, request) async {
        onHit(request.url.toString());
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
        controller.evaluateJavascript(source: _sniffJs);
      },
    );

    timer = Timer(timeout, () => finish(null));
    try {
      await webView.run();
    } catch (_) {
      finish(null);
    }
    return completer.future;
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

/// 在页面脚本之前挂载嗅探钩子：XHR / fetch / hls.js 的清单请求都会被捕获。
const String _sniffJs = r'''
(function () {
  if (window.__echoSniffHooked) return;
  window.__echoSniffHooked = true;
  function report(u) {
    try {
      if (typeof u !== 'string' || u.length === 0) return;
      if (u.toLowerCase().indexOf('.m3u8') < 0) return;
      window.flutter_inappwebview.callHandler('echoSniff', u);
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
        window.flutter_inappwebview.callHandler('echoSniff', '__ECHO_WAF__');
      }
    } catch (e) {}
  }
  try {
    var _open = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (m, u) {
      try { report(u); } catch (e) {}
      return _open.apply(this, arguments);
    };
  } catch (e) {}
  try {
    var _fetch = window.fetch;
    if (_fetch) {
      window.fetch = function (input, init) {
        try { report(typeof input === 'string' ? input : (input && input.url)); } catch (e) {}
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
            try { report(u); } catch (e) {}
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
        var v = document.querySelector('video');
        if (v) report(v.currentSrc || v.src || '');
      } catch (e) {}
    }, 800);
  } catch (e) {}
})();
''';

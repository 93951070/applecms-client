import 'dart:async';
import 'dart:collection';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// web嗅探服务。
///
/// 用无界面（headless）WebView 打开服务端下发的解析站页面，在页面脚本运行前
/// 注入钩子拦截 XHR / fetch / hls.js 的清单请求，嗅出真正的 `.m3u8` 地址后返回。
/// 全程不创建路由、不渲染任何界面，对用户完全无感。
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

    void finish(String? result) {
      if (completer.isCompleted) return;
      timer?.cancel();
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

    webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
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
}

/// WAF 验证页哨兵值：页面脚本识别到人机验证后回传，触发快速失败。
const String _wafSentinel = '__ECHO_WAF__';

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

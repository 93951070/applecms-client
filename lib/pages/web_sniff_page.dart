import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// web嗅探播放页。
///
/// 用 WebView 打开服务端下发的解析站页面，在页面脚本运行前注入钩子拦截
/// XHR / fetch / hls.js 的清单请求，嗅出真正的 `.m3u8` 地址后关闭本页并返回。
/// WebView 全程渲染但不透明遮罩盖住，只展示「解析中」，避免解析页画面与声音外泄。
class WebSniffPage extends StatefulWidget {
  final String sniffUrl;

  const WebSniffPage({super.key, required this.sniffUrl});

  /// 打开嗅探页，成功返回嗅探到的直链，失败或超时返回 null。
  static Future<String?> show(BuildContext context, {required String sniffUrl}) {
    return Navigator.of(context, rootNavigator: true).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => WebSniffPage(sniffUrl: sniffUrl),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<WebSniffPage> createState() => _WebSniffPageState();
}

class _WebSniffPageState extends State<WebSniffPage> {
  static const Duration _timeout = Duration(seconds: 22);

  Timer? _timer;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_timeout, () => _finish(null));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _finish(String? url) {
    if (_done || !mounted) return;
    _done = true;
    _timer?.cancel();
    Navigator.of(context).pop(url);
  }

  void _onHit(Object? raw) {
    final url = raw?.toString() ?? '';
    if (url.isEmpty || !url.toLowerCase().contains('.m3u8')) return;
    _finish(url);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(widget.sniffUrl)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              mediaPlaybackRequiresUserGesture: false,
              allowsInlineMediaPlayback: true,
              mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
              transparentBackground: true,
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
                  if (args.isNotEmpty) _onHit(args.first);
                  return null;
                },
              );
            },
            // Android 兜底：直接观察子资源请求里的 m3u8（iOS 不会回调 http(s)）。
            shouldInterceptRequest: (controller, request) async {
              _onHit(request.url.toString());
              return null;
            },
            onLoadStop: (controller, url) {
              controller.evaluateJavascript(source: _sniffJs);
            },
          ),
          const Positioned.fill(
            child: ColoredBox(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white70,
                      ),
                    ),
                    SizedBox(height: 14),
                    Text(
                      '正在解析线路…',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 40,
            left: 8,
            child: IconButton(
              icon: const Icon(LucideIcons.x, color: Colors.white, size: 26),
              onPressed: () => _finish(null),
            ),
          ),
        ],
      ),
    );
  }
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
        var v = document.querySelector('video');
        if (v) report(v.currentSrc || v.src || '');
      } catch (e) {}
    }, 800);
  } catch (e) {}
})();
''';

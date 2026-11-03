import 'dart:async';
import 'dart:collection';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../app_services.dart';
import '../data/providers/guangya_login.dart';
import '../domain/auth.dart';
import '../domain/models.dart';
import '../platform/login_browser.dart';
import 'common.dart';
import 'login_webview.dart';

class GuangyaVerificationPage extends StatefulWidget {
  const GuangyaVerificationPage(this.services, this.challenge, {super.key});
  final AppServices services;
  final GuangyaCaptchaChallenge challenge;

  @override
  State<GuangyaVerificationPage> createState() =>
      _GuangyaVerificationPageState();
}

class _GuangyaVerificationPageState extends State<GuangyaVerificationPage> {
  WebViewEnvironment? _environment;
  DetachedLoginPage? _detached;
  StreamSubscription<LinuxWebViewEvent>? _detachedEvents;
  bool _ready = false, _finished = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      widget.services.control.checkCloud(CloudPlatform.guangya);
      _environment = await widget.services.webEnvironment();
      if (loginBrowserIsDetached) {
        final page = await openDetachedLoginPage(
          url: widget.challenge.url.toString(),
          userAgent: WebLoginTarget.desktopUserAgent,
          title: '光鸭安全验证',
          initScripts: [desktopLoginUserScript()],
        );
        _detached = page;
        _detachedEvents = page.events.listen(_onDetachedEvent);
      }
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _error = '验证页面初始化失败，请返回后重试或切换网页登录');
    }
  }

  void _onDetachedEvent(LinuxWebViewEvent event) {
    final page = _detached;
    if (!mounted || _finished || page == null) return;
    switch (event.type) {
      case LinuxWebViewEvent.loadFinished:
        if (_callback(event.url)) return;
        unawaited(_injectDetached(page));
      case LinuxWebViewEvent.loadFailed:
        if (mounted && !_finished) {
          setState(() => _error = '验证网页加载失败，请返回后重试');
        }
      case LinuxWebViewEvent.navigation:
        unawaited(_resolveDetachedNavigation(page, event));
      case LinuxWebViewEvent.closed:
        if (mounted && !_finished) {
          setState(() {
            _ready = false;
            _error = '验证窗口已关闭，请返回后重试';
          });
        }
      default:
        break;
    }
  }

  Future<void> _injectDetached(DetachedLoginPage page) async {
    try {
      await page.evaluateJavascript(source: desktopLoginViewportScript);
    } catch (_) {
      // The verification redirect may replace the document.
    }
  }

  Future<void> _resolveDetachedNavigation(
    DetachedLoginPage page,
    LinuxWebViewEvent event,
  ) async {
    final token = event.token;
    if (token == null) return;
    var allow = false;
    if (mounted && !_finished) {
      if (event.mainFrame && _callback(event.url)) {
        allow = false;
      } else {
        allow = GuangyaCaptchaChallenge.trustedPage(event.url);
      }
    }
    try {
      await page.resolveNavigation(token, allow: allow);
    } catch (_) {
      // The window can close between the event and this answer.
    }
  }

  @override
  void dispose() {
    unawaited(_detachedEvents?.cancel());
    unawaited(_detached?.close());
    super.dispose();
  }

  bool _callback(String? url) {
    if (!mounted || _finished) return false;
    final token = widget.challenge.tokenFromCallback(url);
    if (token == null) return false;
    _finished = true;
    Navigator.pop(context, token);
    return true;
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '光鸭安全验证',
    child: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('请完成官方安全验证，完成后将自动继续登录'),
        ),
        Expanded(
          child: _error.isNotEmpty
              ? EmptyPanel('验证页面不可用', _error, icon: CupertinoIcons.lock_shield)
              : !_ready
              ? const Center(child: CircularProgressIndicator())
              : loginBrowserIsDetached
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '安全验证已在独立窗口中打开',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '请在系统窗口里完成验证，完成后会自动继续登录。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: secondary(context),
                        ),
                      ),
                      const SizedBox(height: 18),
                      FilledButton.tonal(
                        onPressed: () => unawaited(_detached?.present()),
                        child: const Text('显示验证窗口'),
                      ),
                    ],
                  ),
                )
              : InAppWebView(
                  webViewEnvironment: _environment,
                  initialUrlRequest: URLRequest(
                    url: WebUri.uri(widget.challenge.url),
                  ),
                  initialSettings: webSettings(),
                  initialUserScripts: UnmodifiableListView([
                    desktopLoginUserScript(),
                  ]),
                  onLoadStop: (web, url) async {
                    if (_callback(url?.toString()) || !mounted) return;
                    try {
                      await web.evaluateJavascript(
                        source: desktopLoginViewportScript,
                      );
                    } catch (_) {
                      // The verification redirect may replace the document.
                    }
                  },
                  onReceivedError: (_, request, _) {
                    if (mounted &&
                        !_finished &&
                        request.isForMainFrame == true) {
                      setState(() => _error = '验证网页加载失败，请返回后重试');
                    }
                  },
                  shouldOverrideUrlLoading: (_, action) async {
                    if (!mounted || _finished) {
                      return NavigationActionPolicy.CANCEL;
                    }
                    final url = action.request.url?.toString();
                    if (action.isForMainFrame && _callback(url)) {
                      return NavigationActionPolicy.CANCEL;
                    }
                    return GuangyaCaptchaChallenge.trustedPage(url)
                        ? NavigationActionPolicy.ALLOW
                        : NavigationActionPolicy.CANCEL;
                  },
                ),
        ),
      ],
    ),
  );
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/providers/quark.dart';
import '../data/providers/quark_login.dart';
import '../domain/models.dart';
import '../domain/quark_sms_verification.dart';
import '../platform/login_browser.dart';
import 'common.dart';
import 'login_webview.dart';

class QuarkSmsVerificationPage extends StatefulWidget {
  const QuarkSmsVerificationPage(
    this.services, {
    required this.useSlider,
    super.key,
  });
  final AppServices services;
  final bool useSlider;

  @override
  State<QuarkSmsVerificationPage> createState() =>
      _QuarkSmsVerificationPageState();
}

class _QuarkSmsVerificationPageState extends State<QuarkSmsVerificationPage> {
  WebViewEnvironment? _environment;
  LoginBrowserPage? _web;
  DetachedLoginPage? _detached;
  StreamSubscription<LinuxWebViewEvent>? _detachedEvents;
  LoginCookieJar? _cookies;
  Timer? _timer;
  bool _ready = false, _finished = false, _checking = false;
  String _error = '';
  bool get _active => mounted && !_finished;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      widget.services.control.checkCloud(CloudPlatform.quark);
      _environment = await widget.services.webEnvironment();
      if (!_active) return;
      _cookies = await createLoginCookieJar(_environment);
      await _cookies!.deleteAllCookies();
      if (!_active) return;
      if (loginBrowserIsDetached) {
        await _openDetached();
        if (!_active) return;
      }
      if (_active) setState(() => _ready = true);
    } catch (_) {
      if (_active) setState(() => _error = '安全验证初始化失败，请返回重试或切换网页登录');
    }
  }

  Future<void> _openDetached() async {
    await _closeDetached();
    final page = await openDetachedLoginPage(
      url: QuarkLoginService.mobilePage,
      userAgent: QuarkConnector.webUa,
      title: '夸克安全验证',
    );
    _web = page;
    _detached = page;
    _detachedEvents = page.events.listen(_onDetachedEvent);
  }

  Future<void> _closeDetached() async {
    final events = _detachedEvents;
    final page = _detached;
    _detachedEvents = null;
    _detached = null;
    await events?.cancel();
    if (page == null) return;
    if (identical(_web, page)) _web = null;
    await page.close();
  }

  void _onDetachedEvent(LinuxWebViewEvent event) {
    final page = _detached;
    if (!_active || page == null) return;
    switch (event.type) {
      case LinuxWebViewEvent.loadFinished:
        if (!QuarkSmsVerification.trustedPage(event.url)) return;
        _web = page;
        _restartPolling();
        unawaited(_capture());
      case LinuxWebViewEvent.loadFailed:
        if (_active) {
          setState(() => _error = '安全验证加载失败，请返回重试或切换网页登录');
        }
      case LinuxWebViewEvent.navigation:
        unawaited(_resolveDetachedNavigation(page, event));
      case LinuxWebViewEvent.closed:
        if (_active) {
          setState(() {
            _ready = false;
            _error = '验证窗口已关闭，可重新加载安全验证';
          });
        }
      default:
        break;
    }
  }

  Future<void> _resolveDetachedNavigation(
    DetachedLoginPage page,
    LinuxWebViewEvent event,
  ) async {
    final token = event.token;
    if (token == null) return;
    final allow =
        _active &&
        (!event.mainFrame || QuarkSmsVerification.trustedPage(event.url));
    try {
      await page.resolveNavigation(token, allow: allow);
    } catch (_) {
      // The window can close between the event and this answer.
    }
  }

  void _restartPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(milliseconds: 350),
      (_) => unawaited(_capture()),
    );
  }

  Future<void> _capture() async {
    final web = _web;
    if (!_active || _checking || web == null) return;
    _checking = true;
    try {
      final page = (await web.getUrl())?.toString();
      if (!_active ||
          !identical(_web, web) ||
          !QuarkSmsVerification.trustedPage(page)) {
        return;
      }
      final result = await web.evaluateJavascript(
        source: QuarkSmsVerification.captureScript(useSlider: widget.useSlider),
      );
      if (!_active ||
          !identical(_web, web) ||
          result is! String ||
          result.isEmpty) {
        return;
      }
      final data = asJson(jsonDecode(result));
      if (data.values.any((value) => value is! String)) return;
      final fields = data.map((key, value) => MapEntry(key, value as String));
      if (!QuarkCaptchaProof(fields).valid) return;
      final cookies = await _cookies!.getCookies(
        url: Uri.parse(QuarkLoginService.mobilePage),
        view: web,
      );
      if (!_active || !identical(_web, web)) return;
      // Preserve domain/path scoping when moving this private attempt's cookies
      // to its HTTP jar. Nothing is written to the account store here.
      final proof = QuarkCaptchaProof(fields, [
        for (final cookie in cookies)
          '${cookie.name}=${cookie.value}; Path=${cookie.path ?? '/'}'
              '${cookie.domain == null ? '' : '; Domain=${cookie.domain}'}'
              '${cookie.secure ? '; Secure' : ''}',
      ]);
      _timer?.cancel();
      await _cookies!.deleteAllCookies();
      if (!mounted || !_active || !identical(_web, web)) return;
      _finished = true;
      await _closeDetached();
      if (mounted) Navigator.pop(context, proof);
    } catch (_) {
      // A redirect or an SDK reload can replace the document while polling.
      // The next poll retries against the current official document.
    } finally {
      _checking = false;
    }
  }

  void _stop() {
    _finished = true;
    _timer?.cancel();
    unawaited(_closeDetached());
  }

  void _reload() {
    if (!_active) return;
    _timer?.cancel();
    _web = null;
    setState(() {
      _ready = false;
      _error = '';
    });
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _stop();
    },
    child: PageFrame(
      title: '夸克安全验证',
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('请完成官方安全验证，完成后将自动发送短信验证码'),
          ),
          Expanded(
            child: _error.isNotEmpty
                ? EmptyPanel(
                    '验证页面不可用',
                    _error,
                    icon: CupertinoIcons.lock_shield,
                  )
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
                          '请在系统窗口里完成官方安全验证，完成后会自动发送短信验证码。',
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
                      url: WebUri(QuarkLoginService.mobilePage),
                    ),
                    initialSettings: webSettings(
                      userAgent: QuarkConnector.webUa,
                      desktopMode: false,
                    ),
                    onWebViewCreated: (web) => _web = EmbeddedLoginPage(web),
                    onLoadStop: (web, url) {
                      if (!_active ||
                          !QuarkSmsVerification.trustedPage(url?.toString())) {
                        return;
                      }
                      _web = EmbeddedLoginPage(web);
                      _restartPolling();
                      unawaited(_capture());
                    },
                    onReceivedError: (_, request, _) {
                      if (_active && request.isForMainFrame == true) {
                        setState(() => _error = '安全验证加载失败，请返回重试或切换网页登录');
                      }
                    },
                    shouldOverrideUrlLoading: (_, action) async =>
                        _active &&
                            (!action.isForMainFrame ||
                                QuarkSmsVerification.trustedPage(
                                  action.request.url?.toString(),
                                ))
                        ? NavigationActionPolicy.ALLOW
                        : NavigationActionPolicy.CANCEL,
                  ),
          ),
          TextButton.icon(
            onPressed: _ready || _error.isNotEmpty ? _reload : null,
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 18),
            label: const Text('重新加载安全验证'),
          ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
}

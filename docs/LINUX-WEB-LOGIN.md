# Linux 网页登录（WebKitGTK 窗口）

网盘登录在 Android / Windows 上是**内嵌**的：`flutter_inappwebview` 把 WebView 作为平台视图嵌进 Flutter 树里，
业务代码拿到 `InAppWebViewController` 直接读 Cookie、跑 JS。

Linux 没有这条路：

* Flutter 官方 Linux embedder **没有平台视图**（engine 的 PR #23985 / #24169 未合入），
  内嵌一个原生 GtkWidget 没有渲染载体；
* `flutter_inappwebview` 本身**没有 Linux 实现**（6.1.5 只依赖 android / ios / macos / web / windows），
  于是 `InAppWebViewPlatform.instance == null`，`CookieManager.instance()` 直接抛异常 ——
  这就是 Linux 上每个「网页登录」入口都报「网页登录组件初始化失败 / 验证页面不可用」的原因，与网盘厂商无关。

## 方案：独立 GTK 窗口 + 通道驱动

`vendor_plugins/asterlink_webview_linux` 是一个自写的最小插件（C++/GTK3 + WebKitGTK 4.1）：

| 项 | 实现 |
|---|---|
| 窗口 | 每个会话一个 `GtkWindow` + `WebKitWebView`，`transient_for` 主窗口 |
| 与 Dart 交互 | `MethodChannel asterlink/webview_linux`（命令）+ `EventChannel .../events`（事件） |
| Cookie | 每个插件实例一个 `WebKitWebContext`（持久化到 `$XDG_DATA_HOME/asterlink/webview`），所有窗口共用一个 jar；`incognito` 走 `webkit_web_context_new_ephemeral()` |
| 脚本注入 | `WebKitUserContentManager`，document-start |
| 导航裁决 | `decide-policy` 把决定权交给 Dart（等价于 `shouldOverrideUrlLoading`），8 秒未答复则放行 |
| 弹窗 | `create` 信号：同一 context 里再开一个窗口（cookie 共享，登录态能带回来） |

Dart 侧统一抽象在 `lib/platform/login_browser.dart`：

* `LoginBrowserPage` —— `getUrl / evaluateJavascript / reload / loadUrl / stopLoading`，两个实现：
  `EmbeddedLoginPage`（包 `InAppWebViewController`）与 `DetachedLoginPage`（包 Linux 会话）。
* `LoginCookieJar` —— `getCookies / deleteAllCookies`，两个实现同上。
* `loginBrowserIsDetached` —— 唯一的平台分支点，登录页据此决定「内嵌 webview」还是「独立窗口面板」。

登录页（`lib/ui/login_page.dart`、`quark_sms_verification_page.dart`、`ctfile_verification_page.dart`、
`guangya_verification_page.dart`）在 Linux 上显示一条「登录页面已在独立窗口中打开」的面板，
真正的页面在系统窗口里；加载完成、URL 变化、导航裁决、窗口关闭都由事件流驱动，走的还是同一套登录检测逻辑。

## 依赖

**编译期**（CI 的 `linux` job 已经装上，本机不需要）：

```
libwebkit2gtk-4.1-dev  libjavascriptcoregtk-4.1-dev
```

**运行期**（写进 deb 的 `Depends`，由 dpkg 安装）：

```
libwebkit2gtk-4.1-0  libjavascriptcoregtk-4.1-0  libsoup-3.0-0
```

对应 `tool/package_linux.py` 的 `SONAME_PACKAGES` 三个新条目。不打包、不编译 WebKit 本体。

## 已知限制

* **窗口是独立的**：不能和 Flutter 组件叠放。Linux 上登录页显示的是说明面板，不是网页。
* **弹窗**（`window.open` 的 SSO / 授权页）开成新的系统窗口，共用同一个 cookie jar；Dart 侧不再有
  `_windows` 栈，浏览器自己管理。
* **脚本无法按 origin 限定**：WebKitGTK 的 user script 没有 `allowedOriginRules`，`guardedScript()`
  把规则改写成 `location.origin / location.hostname` 判断包在脚本外面。顶层 `var` / `function`
  在块内仍然提升到全局（sloppy mode），与 `allowedOriginRules` 的效果基本一致。
* **百度手机号面板**（`baiduNativeLogin`）在 Linux 上关闭，直接走网页登录 —— 那个面板靠往隐藏页面注入
  脚本工作，独立窗口下体验会很怪，而官网页面本来就提供短信登录。
* **玲珑（.layer）层没有 WebKit**：`org.deepin.base/25.2.2` 不含 webkit，`collect_runtime_libs`
  会把 `libwebkit2gtk-4.1.so.0` 拷进去，但 `libexec/webkit2gtk-4.1/` 下的
  `WebKitWebProcess` / `WebKitNetworkProcess` 不是库，不会被带上，所以**层里的网页登录暂时不可用**。
  要支持得再把 helper 进程目录一起收进组合层，或让玲珑版明确只用手动登录。
* **在线预览 / 搜索安全验证**这两处仍需要内嵌浏览器，Linux 上改成提示文案（改为下载文件 / 换平台完成）。

## 手动验证（在桌面会话里跑）

```bash
# 1) 引擎可用性（不装本项目的任何东西）
/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/MiniBrowser https://pan.quark.cn

# 2) 应用内：网盘管理 → 添加账号 → 网页登录
#    应弹出独立窗口；在窗口里完成登录，回来点「检测登录」
```

如果窗口打不开而 `MiniBrowser` 正常，先看 `journalctl --user -f` 或终端里的
`asterlink_webview_linux:` 前缀告警。

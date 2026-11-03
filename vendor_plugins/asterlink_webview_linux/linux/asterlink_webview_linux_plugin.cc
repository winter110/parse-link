// Linux web login browser for 文析助手.
//
// The Flutter Linux embedder has no platform-view support, so a WebKitGTK web
// view cannot be embedded inside the Flutter widget tree. This plugin therefore
// hosts each browser "session" in its own native GTK window and exposes the
// small command surface the Dart login flow needs (navigate, evaluate JS,
// cookies, load/title/progress events) over a method + event channel pair.
//
// Everything links against the WebKitGTK 4.1 ABI the distribution ships
// (libwebkit2gtk-4.1-0); no part of WebKit is built from source here.

#include <asterlink_webview_linux/asterlink_webview_linux_plugin.h>

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// JavaScriptCore value helpers.
//
// `webkit_web_view_evaluate_javascript_finish` returns a JSCValue, but the
// JSCore umbrella header lives in a different include directory than the WebKit
// one depending on the distribution. The handful of entry points used here are
// stable ABI, so declare them directly instead of guessing a header path. All
// of them resolve against libjavascriptcoregtk-4.1 at link time.
// ---------------------------------------------------------------------------
extern "C" {
gboolean jsc_value_is_undefined(JSCValue* value);
gboolean jsc_value_is_null(JSCValue* value);
gboolean jsc_value_is_string(JSCValue* value);
gchar* jsc_value_to_string(JSCValue* value);
gchar* jsc_value_to_json(JSCValue* value, guint indent);
}

namespace {

constexpr char kChannelName[] = "asterlink/webview_linux";
constexpr char kEventChannelName[] = "asterlink/webview_linux/events";

// Well past any redirect chain a login page produces; the fallback keeps a
// dropped Dart isolate from freezing the page.
constexpr guint kNavigationArbitrationTimeoutMs = 8000;

constexpr int kDefaultWidth = 1120;
constexpr int kDefaultHeight = 780;

struct Session {
  std::string id;
  GtkWidget* window = nullptr;
  GtkWidget* view = nullptr;
  WebKitWebContext* context = nullptr;
  Session* opener = nullptr;
  bool closed = false;
  bool arbitrate = false;

  // A navigation decision Dart must answer. WebKit blocks the navigation until
  // the policy decision is used or ignored.
  WebKitNavigationPolicyDecision* pending = nullptr;
  std::string pending_token;
  guint pending_timeout = 0;
};

struct Plugin {
  FlMethodChannel* channel = nullptr;
  FlEventChannel* events = nullptr;
  GtkWindow* parent_window = nullptr;
  WebKitWebContext* context = nullptr;
  WebKitWebContext* ephemeral_context = nullptr;
  std::map<std::string, std::unique_ptr<Session>> sessions;
  std::string data_directory;
  bool listening = false;
  guint64 next_id = 0;
};

Plugin* g_plugin = nullptr;

std::string NextId(const char* prefix) {
  return std::string(prefix) + "-" + std::to_string(++g_plugin->next_id);
}

// ---------------------------------------------------------------------------
// FlValue helpers.
// ---------------------------------------------------------------------------

FlValue* Arg(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(args, key);
}

std::string ArgString(FlValue* args, const char* key,
                      const std::string& fallback = std::string()) {
  FlValue* value = Arg(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return fallback;
  }
  return std::string(fl_value_get_string(value));
}

bool ArgBool(FlValue* args, const char* key, bool fallback = false) {
  FlValue* value = Arg(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_BOOL) {
    return fallback;
  }
  return fl_value_get_bool(value) != FALSE;
}

double ArgDouble(FlValue* args, const char* key, double fallback) {
  FlValue* value = Arg(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_FLOAT) {
    return fallback;
  }
  return fl_value_get_float(value);
}

void RespondError(FlMethodCall* call, const char* code, const std::string& msg) {
  fl_method_call_respond_error(call, code, msg.c_str(), nullptr, nullptr);
}

void RespondString(FlMethodCall* call, const std::string& value) {
  g_autoptr(FlValue) result = fl_value_new_string(value.c_str());
  fl_method_call_respond_success(call, result, nullptr);
}

void RespondNull(FlMethodCall* call) {
  fl_method_call_respond_success(call, nullptr, nullptr);
}

bool CanEmit() {
  return g_plugin != nullptr && g_plugin->events != nullptr &&
         g_plugin->listening;
}

// ---------------------------------------------------------------------------
// Events to Dart.
// ---------------------------------------------------------------------------

FlValue* NewEvent(const char* type, Session* session) {
  FlValue* event = fl_value_new_map();
  fl_value_set_string_take(event, "type", fl_value_new_string(type));
  fl_value_set_string_take(event, "id",
                           fl_value_new_string(session->id.c_str()));
  return event;
}

void Send(FlValue* event) {
  g_autoptr(GError) error = nullptr;
  if (!fl_event_channel_send(g_plugin->events, event, nullptr, &error)) {
    g_warning("asterlink_webview_linux: event send failed: %s",
              error != nullptr ? error->message : "unknown error");
  }
  fl_value_unref(event);
}

void Emit(const char* type, Session* session) {
  if (!CanEmit()) return;
  Send(NewEvent(type, session));
}

void EmitUrl(const char* type, Session* session, const gchar* url) {
  if (!CanEmit()) return;
  FlValue* event = NewEvent(type, session);
  fl_value_set_string_take(event, "url",
                           fl_value_new_string(url != nullptr ? url : ""));
  Send(event);
}

void EmitText(const char* type, Session* session, const std::string& text) {
  if (!CanEmit()) return;
  FlValue* event = NewEvent(type, session);
  fl_value_set_string_take(event, "message", fl_value_new_string(text.c_str()));
  const gchar* uri = session->view != nullptr
                         ? webkit_web_view_get_uri(WEBKIT_WEB_VIEW(session->view))
                         : nullptr;
  fl_value_set_string_take(event, "url",
                           fl_value_new_string(uri != nullptr ? uri : ""));
  Send(event);
}

void EmitProgress(Session* session, double progress) {
  if (!CanEmit()) return;
  FlValue* event = NewEvent("progress", session);
  fl_value_set_string_take(event, "progress", fl_value_new_float(progress));
  Send(event);
}

// ---------------------------------------------------------------------------
// Session lifetime.
// ---------------------------------------------------------------------------

void ResolvePending(Session* session, bool allow);

gboolean RemoveClosedSession(gpointer user_data) {
  std::string* id = static_cast<std::string*>(user_data);
  if (g_plugin != nullptr) {
    auto it = g_plugin->sessions.find(*id);
    if (it != g_plugin->sessions.end() && it->second->closed) {
      g_plugin->sessions.erase(it);
    }
  }
  delete id;
  return G_SOURCE_REMOVE;
}

void OnWindowDestroy(GtkWidget* widget, gpointer user_data) {
  Session* session = static_cast<Session*>(user_data);
  session->closed = true;
  session->window = nullptr;
  session->view = nullptr;
  if (session->pending_timeout != 0) {
    g_source_remove(session->pending_timeout);
    session->pending_timeout = 0;
  }
  if (session->pending != nullptr) {
    webkit_policy_decision_ignore(
        WEBKIT_POLICY_DECISION(session->pending));
    g_object_unref(session->pending);
    session->pending = nullptr;
  }
  Emit("closed", session);
  // The Session object stays alive until the idle runs so the "closed" event
  // above can still read its id.
  g_idle_add(RemoveClosedSession, new std::string(session->id));
}

// ---------------------------------------------------------------------------
// WebView signals.
// ---------------------------------------------------------------------------

gboolean OnLoadFailed(WebKitWebView* view, WebKitLoadEvent load_event,
                      gchar* failing_uri, GError* error, gpointer user_data) {
  Session* session = static_cast<Session*>(user_data);
  if (session->closed) return FALSE;
  if (load_event == WEBKIT_LOAD_STARTED) {
    // A provisional load that fails is usually a redirect the site recovers
    // from; only surface failures after the document committed.
    return FALSE;
  }
  EmitText("loadFailed", session,
           error != nullptr && error->message != nullptr ? error->message
                                                         : "load failed");
  return FALSE;
}

void OnLoadChanged(WebKitWebView* view, WebKitLoadEvent load_event,
                   gpointer user_data) {
  Session* session = static_cast<Session*>(user_data);
  if (session->closed) return;
  const gchar* uri = webkit_web_view_get_uri(view);
  switch (load_event) {
    case WEBKIT_LOAD_STARTED:
      EmitUrl("loadStarted", session, uri);
      break;
    case WEBKIT_LOAD_REDIRECTED:
    case WEBKIT_LOAD_COMMITTED:
      EmitUrl("urlChanged", session, uri);
      break;
    case WEBKIT_LOAD_FINISHED:
      EmitUrl("loadFinished", session, uri);
      break;
  }
}

void OnTitleChanged(GObject* object, GParamSpec* spec, gpointer user_data) {
  Session* session = static_cast<Session*>(user_data);
  if (session->closed || !CanEmit()) return;
  FlValue* event = NewEvent("titleChanged", session);
  const gchar* title = webkit_web_view_get_title(WEBKIT_WEB_VIEW(object));
  fl_value_set_string_take(event, "title",
                           fl_value_new_string(title != nullptr ? title : ""));
  Send(event);
}

void OnUriChanged(GObject* object, GParamSpec* spec, gpointer user_data) {
  Session* session = static_cast<Session*>(user_data);
  if (session->closed) return;
  EmitUrl("urlChanged", session,
          webkit_web_view_get_uri(WEBKIT_WEB_VIEW(object)));
}

void OnProgressChanged(GObject* object, GParamSpec* spec, gpointer user_data) {
  Session* session = static_cast<Session*>(user_data);
  if (session->closed) return;
  EmitProgress(session, webkit_web_view_get_estimated_load_progress(
                            WEBKIT_WEB_VIEW(object)));
}

gboolean OnWebProcessTerminated(WebKitWebView* view,
                                WebKitWebProcessTerminationReason reason,
                                gpointer user_data) {
  Session* session = static_cast<Session*>(user_data);
  if (session->closed) return FALSE;
  EmitText("processTerminated", session,
           reason == WEBKIT_WEB_PROCESS_CRASHED ? "crashed" : "terminated");
  return FALSE;
}

// ---------------------------------------------------------------------------
// Navigation arbitration (mirrors shouldOverrideUrlLoading from the other
// platforms so provider-specific redirect handling keeps working).
// ---------------------------------------------------------------------------

gboolean OnArbitrationTimeout(gpointer user_data) {
  Session* session = static_cast<Session*>(user_data);
  session->pending_timeout = 0;
  // Never leave the page frozen: an unanswered request is allowed.
  ResolvePending(session, true);
  return G_SOURCE_REMOVE;
}

void ResolvePending(Session* session, bool allow) {
  if (session->pending == nullptr) return;
  WebKitNavigationPolicyDecision* decision = session->pending;
  session->pending = nullptr;
  session->pending_token.clear();
  if (session->pending_timeout != 0) {
    g_source_remove(session->pending_timeout);
    session->pending_timeout = 0;
  }
  if (allow) {
    webkit_policy_decision_use(WEBKIT_POLICY_DECISION(decision));
  } else {
    webkit_policy_decision_ignore(WEBKIT_POLICY_DECISION(decision));
  }
  g_object_unref(decision);
}

gboolean OnDecidePolicy(WebKitWebView* view, WebKitPolicyDecision* decision,
                        WebKitPolicyDecisionType decision_type,
                        gpointer user_data) {
  Session* session = static_cast<Session*>(user_data);
  if (session->closed) return FALSE;
  if (decision_type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
    return FALSE;
  }
  if (!session->arbitrate || !CanEmit()) return FALSE;
  // A second decision while one is outstanding keeps the default handling: a
  // redirect storm must not deadlock the page.
  if (session->pending != nullptr) return FALSE;

  WebKitNavigationPolicyDecision* navigation_decision =
      WEBKIT_NAVIGATION_POLICY_DECISION(decision);
  WebKitNavigationAction* action =
      webkit_navigation_policy_decision_get_navigation_action(
          navigation_decision);
  if (action == nullptr) return FALSE;
  WebKitURIRequest* request = webkit_navigation_action_get_request(action);
  const gchar* uri =
      request != nullptr ? webkit_uri_request_get_uri(request) : nullptr;
  const gchar* frame_name = webkit_navigation_action_get_frame_name(action);
  // WebKitGTK exposes no isForMainFrame(); an unnamed frame is the top frame
  // unless the page gave it a window name.
  const bool main_frame = frame_name == nullptr || *frame_name == '\0';

  session->pending = navigation_decision;
  g_object_ref(navigation_decision);
  session->pending_token = NextId("nav");
  session->pending_timeout =
      g_timeout_add(kNavigationArbitrationTimeoutMs, OnArbitrationTimeout,
                    session);

  if (!CanEmit()) {
    ResolvePending(session, true);
    return TRUE;
  }
  FlValue* event = NewEvent("navigation", session);
  fl_value_set_string_take(event, "url",
                           fl_value_new_string(uri != nullptr ? uri : ""));
  fl_value_set_string_take(event, "token",
                           fl_value_new_string(session->pending_token.c_str()));
  fl_value_set_string_take(event, "mainFrame", fl_value_new_bool(main_frame));
  Send(event);
  return TRUE;
}

// ---------------------------------------------------------------------------
// Contexts and session creation.
// ---------------------------------------------------------------------------

WebKitWebContext* ContextFor(bool ephemeral, const std::string& data_dir,
                             std::string* error) {
  if (ephemeral) {
    if (g_plugin->ephemeral_context == nullptr) {
      g_plugin->ephemeral_context = webkit_web_context_new_ephemeral();
      webkit_web_context_set_cache_model(g_plugin->ephemeral_context,
                                         WEBKIT_CACHE_MODEL_DOCUMENT_VIEWER);
    }
    return g_plugin->ephemeral_context;
  }
  if (g_plugin->context != nullptr) return g_plugin->context;

  const std::string base =
      !data_dir.empty() ? data_dir : g_plugin->data_directory;
  if (base.empty()) {
    *error = "no data directory configured";
    return nullptr;
  }
  const std::string cache = base + "/cache";
  if (g_mkdir_with_parents(base.c_str(), 0700) != 0) {
    *error = "cannot create " + base;
    return nullptr;
  }
  g_mkdir_with_parents(cache.c_str(), 0700);

  // Keep the login jar persistent like the WebView2 profile on Windows, but
  // turn Intelligent Tracking Prevention off: it drops the cross-site cookies
  // SSO redirects depend on.
  WebKitWebsiteDataManager* manager = webkit_website_data_manager_new(
      "base-data-directory", base.c_str(), "base-cache-directory",
      cache.c_str(), nullptr);
  webkit_website_data_manager_set_itp_enabled(manager, FALSE);
  g_plugin->context =
      webkit_web_context_new_with_website_data_manager(manager);
  g_object_unref(manager);
  webkit_web_context_set_cache_model(g_plugin->context,
                                     WEBKIT_CACHE_MODEL_DOCUMENT_VIEWER);
  return g_plugin->context;
}

void ApplySettings(Session* session, FlValue* args) {
  WebKitSettings* settings = webkit_settings_new();
  const std::string user_agent = ArgString(args, "userAgent");
  if (!user_agent.empty()) {
    webkit_settings_set_user_agent(settings, user_agent.c_str());
  }
  webkit_settings_set_enable_javascript(settings, TRUE);
  webkit_settings_set_enable_html5_local_storage(settings, TRUE);
  webkit_settings_set_enable_html5_database(settings, TRUE);
  webkit_settings_set_javascript_can_open_windows_automatically(settings, TRUE);
  webkit_settings_set_javascript_can_access_clipboard(settings, TRUE);
  webkit_settings_set_allow_universal_access_from_file_urls(settings, FALSE);
  webkit_settings_set_enable_developer_extras(settings, FALSE);
  webkit_web_view_set_settings(WEBKIT_WEB_VIEW(session->view), settings);
  g_object_unref(settings);
}

void ApplyInitScripts(Session* session, FlValue* scripts) {
  if (scripts == nullptr || fl_value_get_type(scripts) != FL_VALUE_TYPE_LIST) {
    return;
  }
  WebKitUserContentManager* manager =
      webkit_web_view_get_user_content_manager(WEBKIT_WEB_VIEW(session->view));
  for (size_t index = 0; index < fl_value_get_length(scripts); index++) {
    FlValue* entry = fl_value_get_list_value(scripts, index);
    const std::string source = ArgString(entry, "source");
    if (source.empty()) continue;
    const bool at_end = ArgString(entry, "injectionTime") == "documentEnd";
    // WebKitGTK user scripts cannot be scoped to an origin; Dart wraps the
    // provider scripts in a host guard instead.
    WebKitUserScript* script = webkit_user_script_new(
        source.c_str(), WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
        at_end ? WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END
               : WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
        nullptr, nullptr);
    webkit_user_content_manager_add_script(manager, script);
    webkit_user_script_unref(script);
  }
}

void AttachWebViewSignal(Session* session);

Session* CreateSession(const std::string& id, const std::string& url,
                       FlValue* args, Session* opener, std::string* error) {
  auto session = std::make_unique<Session>();
  session->id = id;
  session->opener = opener;
  session->arbitrate = ArgBool(args, "arbitrateNavigation", true);
  const bool ephemeral = ArgBool(args, "ephemeral", false);

  session->context =
      opener != nullptr
          ? opener->context
          : ContextFor(ephemeral, ArgString(args, "dataDirectory"), error);
  if (session->context == nullptr) {
    return nullptr;
  }

  session->view = webkit_web_view_new_with_context(session->context);
  ApplySettings(session.get(), args);
  ApplyInitScripts(session.get(), Arg(args, "initScripts"));

  const std::string title = ArgString(args, "title", "网页登录");
  GtkWidget* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), title.c_str());
  gtk_window_set_default_size(
      GTK_WINDOW(window),
      static_cast<int>(ArgDouble(args, "width", kDefaultWidth)),
      static_cast<int>(ArgDouble(args, "height", kDefaultHeight)));
  if (g_plugin->parent_window != nullptr) {
    gtk_window_set_transient_for(GTK_WINDOW(window), g_plugin->parent_window);
  }
  gtk_container_add(GTK_CONTAINER(window), session->view);
  session->window = window;
  g_signal_connect(window, "destroy", G_CALLBACK(OnWindowDestroy),
                   session.get());

  AttachWebViewSignal(session.get());

  Session* raw = session.get();
  g_plugin->sessions[id] = std::move(session);
  gtk_widget_show_all(window);
  if (!url.empty()) {
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(raw->view), url.c_str());
  }
  return raw;
}

GtkWidget* OnCreateWebView(WebKitWebView* view, WebKitNavigationAction* action,
                           gpointer user_data) {
  Session* parent = static_cast<Session*>(user_data);
  if (parent->closed || g_plugin == nullptr) return nullptr;

  // Keep the popup in the opener's context so authorization cookies land in the
  // same jar the main window reads back.
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "arbitrateNavigation",
                           fl_value_new_bool(parent->arbitrate));
  std::string error;
  Session* child =
      CreateSession(NextId("popup"), std::string(), args, parent, &error);
  if (child == nullptr) {
    g_warning("asterlink_webview_linux: popup failed: %s", error.c_str());
    return nullptr;
  }
  WebKitURIRequest* request = webkit_navigation_action_get_request(action);
  EmitUrl("newWindow", child,
          request != nullptr ? webkit_uri_request_get_uri(request) : nullptr);
  return child->view;
}

void AttachWebViewSignal(Session* session) {
  WebKitWebView* view = WEBKIT_WEB_VIEW(session->view);
  g_signal_connect(view, "load-changed", G_CALLBACK(OnLoadChanged), session);
  g_signal_connect(view, "load-failed", G_CALLBACK(OnLoadFailed), session);
  g_signal_connect(view, "notify::title", G_CALLBACK(OnTitleChanged), session);
  g_signal_connect(view, "notify::uri", G_CALLBACK(OnUriChanged), session);
  g_signal_connect(view, "notify::estimated-load-progress",
                   G_CALLBACK(OnProgressChanged), session);
  g_signal_connect(view, "decide-policy", G_CALLBACK(OnDecidePolicy), session);
  g_signal_connect(view, "create", G_CALLBACK(OnCreateWebView), session);
  g_signal_connect(view, "web-process-terminated",
                   G_CALLBACK(OnWebProcessTerminated), session);
}

// ---------------------------------------------------------------------------
// Cookie helpers.
// ---------------------------------------------------------------------------

WebKitCookieManager* CookieManagerFor(FlValue* args) {
  const std::string id = ArgString(args, "id");
  if (!id.empty()) {
    auto it = g_plugin->sessions.find(id);
    if (it != g_plugin->sessions.end() && it->second->context != nullptr) {
      return webkit_web_context_get_cookie_manager(it->second->context);
    }
  }
  if (ArgBool(args, "ephemeral", false) &&
      g_plugin->ephemeral_context != nullptr) {
    return webkit_web_context_get_cookie_manager(g_plugin->ephemeral_context);
  }
  if (g_plugin->context != nullptr) {
    return webkit_web_context_get_cookie_manager(g_plugin->context);
  }
  return nullptr;
}

/// The login flow clears the jar *before* the first window exists, so get or
/// delete must be able to create the profile on demand.
WebKitCookieManager* CookieManagerForOrCreate(FlValue* args) {
  WebKitCookieManager* manager = CookieManagerFor(args);
  if (manager != nullptr) return manager;
  std::string error;
  WebKitWebContext* context = ContextFor(false, std::string(), &error);
  if (context == nullptr) return nullptr;
  return webkit_web_context_get_cookie_manager(context);
}

void FinishCookieRead(FlMethodCall* call, GList* cookies) {
  g_autoptr(FlValue) list = fl_value_new_list();
  for (GList* item = cookies; item != nullptr; item = item->next) {
    SoupCookie* cookie = static_cast<SoupCookie*>(item->data);
    if (cookie == nullptr) continue;
    FlValue* entry = fl_value_new_map();
    const gchar* name = soup_cookie_get_name(cookie);
    const gchar* value = soup_cookie_get_value(cookie);
    const gchar* domain = soup_cookie_get_domain(cookie);
    const gchar* path = soup_cookie_get_path(cookie);
    fl_value_set_string_take(entry, "name",
                             fl_value_new_string(name != nullptr ? name : ""));
    fl_value_set_string_take(
        entry, "value", fl_value_new_string(value != nullptr ? value : ""));
    fl_value_set_string_take(
        entry, "domain", fl_value_new_string(domain != nullptr ? domain : ""));
    fl_value_set_string_take(
        entry, "path", fl_value_new_string(path != nullptr ? path : "/"));
    fl_value_set_string_take(
        entry, "secure",
        fl_value_new_bool(soup_cookie_get_secure(cookie) != FALSE));
    fl_value_set_string_take(
        entry, "httpOnly",
        fl_value_new_bool(soup_cookie_get_http_only(cookie) != FALSE));
    fl_value_append_take(list, entry);
  }
  for (GList* item = cookies; item != nullptr; item = item->next) {
    soup_cookie_free(static_cast<SoupCookie*>(item->data));
  }
  g_list_free(cookies);
  fl_method_call_respond_success(call, list, nullptr);
}

void OnCookiesRead(GObject* source, GAsyncResult* result, gpointer user_data) {
  FlMethodCall* call = static_cast<FlMethodCall*>(user_data);
  FlValue* args = fl_method_call_get_args(call);
  const std::string url = ArgString(args, "url");
  g_autoptr(GError) error = nullptr;
  GList* cookies =
      url.empty()
          ? webkit_cookie_manager_get_all_cookies_finish(
                WEBKIT_COOKIE_MANAGER(source), result, &error)
          : webkit_cookie_manager_get_cookies_finish(
                WEBKIT_COOKIE_MANAGER(source), result, &error);
  if (error != nullptr) {
    RespondError(call, "cookies", error->message);
    g_object_unref(call);
    return;
  }
  FinishCookieRead(call, cookies);
  g_object_unref(call);
}

// ---------------------------------------------------------------------------
// JS evaluation.
// ---------------------------------------------------------------------------

void OnEvaluateFinished(GObject* source, GAsyncResult* result,
                        gpointer user_data) {
  FlMethodCall* call = static_cast<FlMethodCall*>(user_data);
  g_autoptr(GError) error = nullptr;
  JSCValue* value = webkit_web_view_evaluate_javascript_finish(
      WEBKIT_WEB_VIEW(source), result, &error);
  if (error != nullptr || value == nullptr) {
    RespondError(call, "javascript",
                 error != nullptr ? error->message : "no result");
    g_object_unref(call);
    return;
  }

  g_autoptr(FlValue) response = fl_value_new_map();
  if (jsc_value_is_undefined(value) != FALSE) {
    fl_value_set_string_take(response, "kind",
                             fl_value_new_string("undefined"));
    fl_value_set_string_take(response, "value", fl_value_new_string(""));
  } else if (jsc_value_is_null(value) != FALSE) {
    fl_value_set_string_take(response, "kind", fl_value_new_string("null"));
    fl_value_set_string_take(response, "value", fl_value_new_string(""));
  } else if (jsc_value_is_string(value) != FALSE) {
    g_autofree gchar* text = jsc_value_to_string(value);
    fl_value_set_string_take(response, "kind", fl_value_new_string("string"));
    fl_value_set_string_take(response, "value",
                             fl_value_new_string(text != nullptr ? text : ""));
  } else {
    g_autofree gchar* json = jsc_value_to_json(value, 0);
    if (json != nullptr) {
      fl_value_set_string_take(response, "kind", fl_value_new_string("json"));
      fl_value_set_string_take(response, "value", fl_value_new_string(json));
    } else {
      g_autofree gchar* text = jsc_value_to_string(value);
      fl_value_set_string_take(response, "kind",
                               fl_value_new_string("string"));
      fl_value_set_string_take(response, "value",
                               fl_value_new_string(text != nullptr ? text : ""));
    }
  }
  fl_method_call_respond_success(call, response, nullptr);
  g_object_unref(call);
}

// ---------------------------------------------------------------------------
// Method dispatch.
// ---------------------------------------------------------------------------

Session* SessionFrom(FlValue* args, FlMethodCall* call) {
  const std::string id = ArgString(args, "id");
  auto it = g_plugin->sessions.find(id);
  if (it == g_plugin->sessions.end() || it->second->closed) {
    RespondError(call, "session", "网页登录窗口已关闭");
    return nullptr;
  }
  return it->second.get();
}

void CloseWindows(const std::function<void(Session*)>& each) {
  std::vector<std::string> ids;
  for (auto& entry : g_plugin->sessions) ids.push_back(entry.first);
  for (const auto& id : ids) {
    auto it = g_plugin->sessions.find(id);
    if (it == g_plugin->sessions.end()) continue;
    Session* session = it->second.get();
    if (each) each(session);
    if (session->window != nullptr) {
      GtkWidget* window = session->window;
      session->window = nullptr;
      gtk_widget_destroy(window);
    }
  }
}

void OnMethodCall(FlMethodChannel* channel, FlMethodCall* method_call,
                  gpointer user_data) {
  // Every handler below reaches for g_plugin; a null one used to be a
  // segfault on the platform thread, which killed the whole app.
  if (g_plugin == nullptr) {
    RespondError(method_call, "plugin", "网页登录组件尚未就绪");
    return;
  }
  const gchar* name = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (g_strcmp0(name, "create") == 0) {
    const std::string requested = ArgString(args, "id");
    if (requested.empty()) {
      RespondError(method_call, "id", "缺少窗口标识");
      return;
    }
    if (g_plugin->sessions.find(requested) != g_plugin->sessions.end()) {
      RespondError(method_call, "session", "窗口标识已被占用");
      return;
    }
    std::string error;
    Session* session = CreateSession(requested, ArgString(args, "url"), args,
                                     nullptr, &error);
    if (session == nullptr) {
      RespondError(method_call, "context",
                   error.empty() ? "网页登录组件初始化失败" : error);
      return;
    }
    RespondString(method_call, session->id);
    return;
  }
  if (g_strcmp0(name, "close") == 0) {
    const std::string id = ArgString(args, "id");
    auto it = g_plugin->sessions.find(id);
    if (it != g_plugin->sessions.end() && it->second->window != nullptr) {
      GtkWidget* window = it->second->window;
      it->second->window = nullptr;
      gtk_widget_destroy(window);
    }
    RespondNull(method_call);
    return;
  }
  if (g_strcmp0(name, "closeAll") == 0) {
    CloseWindows(nullptr);
    RespondNull(method_call);
    return;
  }
  if (g_strcmp0(name, "dispose") == 0) {
    CloseWindows(nullptr);
    if (g_plugin->context != nullptr) {
      g_object_unref(g_plugin->context);
      g_plugin->context = nullptr;
    }
    if (g_plugin->ephemeral_context != nullptr) {
      g_object_unref(g_plugin->ephemeral_context);
      g_plugin->ephemeral_context = nullptr;
    }
    RespondNull(method_call);
    return;
  }
  if (g_strcmp0(name, "present") == 0) {
    Session* session = SessionFrom(args, method_call);
    if (session == nullptr) return;
    if (session->window != nullptr) {
      gtk_window_present(GTK_WINDOW(session->window));
    }
    RespondNull(method_call);
    return;
  }
  if (g_strcmp0(name, "currentUrl") == 0) {
    Session* session = SessionFrom(args, method_call);
    if (session == nullptr) return;
    const gchar* uri = session->view != nullptr
                           ? webkit_web_view_get_uri(
                                 WEBKIT_WEB_VIEW(session->view))
                           : nullptr;
    if (uri == nullptr) {
      RespondNull(method_call);
    } else {
      RespondString(method_call, uri);
    }
    return;
  }
  if (g_strcmp0(name, "title") == 0) {
    Session* session = SessionFrom(args, method_call);
    if (session == nullptr) return;
    const gchar* title = session->view != nullptr
                             ? webkit_web_view_get_title(
                                   WEBKIT_WEB_VIEW(session->view))
                             : nullptr;
    RespondString(method_call, title != nullptr ? title : "");
    return;
  }
  if (g_strcmp0(name, "loadUrl") == 0) {
    Session* session = SessionFrom(args, method_call);
    if (session == nullptr) return;
    const std::string url = ArgString(args, "url");
    if (url.empty() || session->view == nullptr) {
      RespondError(method_call, "url", "登录地址无效");
      return;
    }
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(session->view), url.c_str());
    RespondNull(method_call);
    return;
  }
  if (g_strcmp0(name, "reload") == 0) {
    Session* session = SessionFrom(args, method_call);
    if (session == nullptr) return;
    if (session->view != nullptr) {
      webkit_web_view_reload(WEBKIT_WEB_VIEW(session->view));
    }
    RespondNull(method_call);
    return;
  }
  if (g_strcmp0(name, "stop") == 0) {
    Session* session = SessionFrom(args, method_call);
    if (session == nullptr) return;
    if (session->view != nullptr) {
      webkit_web_view_stop_loading(WEBKIT_WEB_VIEW(session->view));
    }
    RespondNull(method_call);
    return;
  }
  if (g_strcmp0(name, "evaluate") == 0) {
    Session* session = SessionFrom(args, method_call);
    if (session == nullptr) return;
    const std::string script = ArgString(args, "script");
    if (session->view == nullptr) {
      RespondError(method_call, "session", "网页登录窗口已关闭");
      return;
    }
    g_object_ref(method_call);
    webkit_web_view_evaluate_javascript(
        WEBKIT_WEB_VIEW(session->view), script.c_str(), -1, nullptr, nullptr,
        nullptr, OnEvaluateFinished, method_call);
    return;
  }
  if (g_strcmp0(name, "resolveNavigation") == 0) {
    Session* session = SessionFrom(args, method_call);
    if (session == nullptr) return;
    if (ArgString(args, "token") != session->pending_token) {
      RespondNull(method_call);
      return;
    }
    ResolvePending(session, ArgBool(args, "allow", false));
    RespondNull(method_call);
    return;
  }
  if (g_strcmp0(name, "getCookies") == 0) {
    WebKitCookieManager* manager = CookieManagerForOrCreate(args);
    if (manager == nullptr) {
      RespondError(method_call, "cookies", "网页登录组件尚未启动");
      return;
    }
    const std::string url = ArgString(args, "url");
    g_object_ref(method_call);
    if (url.empty()) {
      webkit_cookie_manager_get_all_cookies(manager, nullptr, OnCookiesRead,
                                            method_call);
    } else {
      webkit_cookie_manager_get_cookies(manager, url.c_str(), nullptr,
                                        OnCookiesRead, method_call);
    }
    return;
  }
  if (g_strcmp0(name, "deleteAllCookies") == 0 ||
      g_strcmp0(name, "clearWebsiteData") == 0) {
    WebKitCookieManager* manager = CookieManagerForOrCreate(args);
    if (manager == nullptr) {
      RespondError(method_call, "cookies", "网页登录组件尚未启动");
      return;
    }
    webkit_cookie_manager_delete_all_cookies(manager);
    g_autoptr(FlValue) ok = fl_value_new_bool(TRUE);
    fl_method_call_respond_success(method_call, ok, nullptr);
    return;
  }

  fl_method_call_respond_not_implemented(method_call, nullptr);
}

FlMethodErrorResponse* OnListen(FlEventChannel* channel, FlValue* args,
                                gpointer user_data) {
  if (g_plugin == nullptr) return nullptr;
  g_plugin->listening = true;
  return nullptr;
}

FlMethodErrorResponse* OnCancel(FlEventChannel* channel, FlValue* args,
                                gpointer user_data) {
  if (g_plugin == nullptr) return nullptr;
  g_plugin->listening = false;
  return nullptr;
}

// The plugin state is process wide on purpose.
//
// `fl_plugin_registry_get_registrar_for_plugin` returns a *fresh* registrar and
// the generated registrant releases it with `g_autoptr` the moment
// `..._register_with_registrar` returns. Hanging the cleanup off the registrar
// (`g_object_set_data_full`) therefore ran a few microseconds after
// registration: it cleared `g_plugin` and deleted the state while the method
// channel was still live, so the first call from Dart — clearing cookies before
// a web login — dereferenced null and the platform thread took SIGSEGV, which
// kills the GTK process outright.
//
// The channels outlive the registrar, so they are what the state must follow.
// Since the channels themselves are owned by the binary messenger for as long
// as the engine exists, keeping the state alive until the process exits is both
// simpler and safer than racing the engine teardown order.

}  // namespace

void asterlink_webview_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  auto plugin = std::make_unique<Plugin>();
  const gchar* data_home = g_get_user_data_dir();
  plugin->data_directory =
      data_home != nullptr ? std::string(data_home) + "/asterlink/webview"
                           : std::string();

  FlView* view = fl_plugin_registrar_get_view(registrar);
  if (view != nullptr) {
    GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
    if (GTK_IS_WINDOW(toplevel)) {
      plugin->parent_window = GTK_WINDOW(toplevel);
    }
  }

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  plugin->channel =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
  plugin->events =
      fl_event_channel_new(messenger, kEventChannelName, FL_METHOD_CODEC(codec));

  g_plugin = plugin.release();
  fl_method_channel_set_method_call_handler(g_plugin->channel, OnMethodCall,
                                            g_plugin, nullptr);
  fl_event_channel_set_stream_handlers(g_plugin->events, OnListen, OnCancel,
                                       g_plugin, nullptr);
}

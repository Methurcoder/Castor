#include "CDesktopUI.h"
#ifdef _WIN32
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <dwmapi.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "../vendor/WebView2.h"

// The creation window: a top-level window hosting WebView2 (BSD-3-Clause SDK
// headers in vendor/). WebView2Loader.dll is loaded from beside the
// executable at run time, so nothing links against it; without the Evergreen
// runtime the window reports failure and the caller explains how to get it.
//
// UI files come from a local folder mapped to https://castor.app/; every
// other navigation is cancelled. Messages from the page reach the host on
// the UI thread; castor_webview_post is safe from any thread.

static const UINT kPostMessage = WM_APP + 41;
static HWND web_window = nullptr;
static ICoreWebView2Controller *web_controller = nullptr;
static ICoreWebView2 *web_view = nullptr;
static castor_web_message web_callback = nullptr;
static void *web_context = nullptr;
static int web_state = 0;  // 0 loading, 1 ready, -1 failed

static WCHAR *web_wide(const char *text) {
    int n = MultiByteToWideChar(CP_UTF8, 0, text, -1, nullptr, 0);
    if (n < 1) return nullptr;
    WCHAR *wide = (WCHAR *)malloc((size_t)n * sizeof(WCHAR));
    if (wide) MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, n);
    return wide;
}
static char *web_utf8(const WCHAR *text) {
    int n = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
    if (n < 1) return nullptr;
    char *utf8 = (char *)malloc((size_t)n);
    if (utf8) WideCharToMultiByte(CP_UTF8, 0, text, -1, utf8, n, nullptr, nullptr);
    return utf8;
}

// Minimal COM completion/event handler around a lambda.
template <typename Interface, typename Function, typename... Args>
class WebHandler : public Interface {
    LONG references = 1;
    Function function;
public:
    explicit WebHandler(Function f) : function(f) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **object) override {
        if (riid == __uuidof(IUnknown) || riid == __uuidof(Interface)) { *object = this; AddRef(); return S_OK; }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&references); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG left = InterlockedDecrement(&references);
        if (!left) delete this;
        return (ULONG)left;
    }
    HRESULT STDMETHODCALLTYPE Invoke(Args... args) override { return function(args...); }
};
template <typename Interface, typename... Args, typename Function>
static Interface *web_handler(Function f) { return new WebHandler<Interface, Function, Args...>(f); }

static void web_resize(void) {
    if (!web_controller || !web_window) return;
    RECT bounds;
    GetClientRect(web_window, &bounds);
    web_controller->put_Bounds(bounds);
}

static LRESULT CALLBACK web_window_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_SIZE:
        web_resize();
        return 0;
    case WM_GETMINMAXINFO: {
        MINMAXINFO *info = (MINMAXINFO *)lparam;
        UINT dpi = GetDpiForWindow(hwnd);
        info->ptMinTrackSize.x = MulDiv(760, (int)dpi, 96);
        info->ptMinTrackSize.y = MulDiv(560, (int)dpi, 96);
        return 0;
    }
    case kPostMessage: {
        WCHAR *json = (WCHAR *)lparam;
        if (web_view && json) web_view->PostWebMessageAsJson(json);
        free(json);
        return 0;
    }
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        if (web_controller) { web_controller->Close(); web_controller->Release(); web_controller = nullptr; }
        if (web_view) { web_view->Release(); web_view = nullptr; }
        web_window = nullptr;
        web_state = 0;
        if (web_callback) web_callback("{\"type\":\"closed\"}", web_context);
        return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

static void web_configure(const WCHAR *folder) {
    ICoreWebView2Settings *settings = nullptr;
    if (SUCCEEDED(web_view->get_Settings(&settings)) && settings) {
#ifdef NDEBUG
        settings->put_AreDevToolsEnabled(FALSE);
#endif
        settings->put_AreDefaultContextMenusEnabled(FALSE);
        settings->put_IsStatusBarEnabled(FALSE);
        settings->put_IsZoomControlEnabled(FALSE);
        settings->Release();
    }
    ICoreWebView2_3 *view3 = nullptr;
    if (SUCCEEDED(web_view->QueryInterface(__uuidof(ICoreWebView2_3), (void **)&view3)) && view3) {
        view3->SetVirtualHostNameToFolderMapping(L"castor.app", folder, COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS);
        view3->Release();
    }
    EventRegistrationToken token;
    web_view->add_NavigationStarting(
        web_handler<ICoreWebView2NavigationStartingEventHandler, ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *>(
            [](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args) -> HRESULT {
                LPWSTR uri = nullptr;
                if (SUCCEEDED(args->get_Uri(&uri)) && uri) {
                    if (wcsncmp(uri, L"https://castor.app/", 19) != 0) args->put_Cancel(TRUE);
                    CoTaskMemFree(uri);
                }
                return S_OK;
            }),
        &token);
    web_view->add_NewWindowRequested(
        web_handler<ICoreWebView2NewWindowRequestedEventHandler, ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *>(
            [](ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *args) -> HRESULT {
                args->put_Handled(TRUE);  // never open popups
                return S_OK;
            }),
        &token);
    web_view->add_WebMessageReceived(
        web_handler<ICoreWebView2WebMessageReceivedEventHandler, ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *>(
            [](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args) -> HRESULT {
                LPWSTR source = nullptr;
                if (SUCCEEDED(args->get_Source(&source)) && source) {
                    bool trusted = wcsncmp(source, L"https://castor.app/", 19) == 0;
                    CoTaskMemFree(source);
                    if (!trusted) return S_OK;
                }
                LPWSTR json = nullptr;
                if (SUCCEEDED(args->get_WebMessageAsJson(&json)) && json) {
                    char *utf8 = web_utf8(json);
                    CoTaskMemFree(json);
                    if (utf8 && web_callback) web_callback(utf8, web_context);
                    free(utf8);
                }
                return S_OK;
            }),
        &token);
    web_view->Navigate(L"https://castor.app/index.html");
}

typedef HRESULT(STDAPICALLTYPE *CreateEnvironment)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions *,
                                                   ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);

static long web_last_error = 0;
long castor_webview_last_error(void) { return web_last_error; }

int castor_webview_open(const char *title, const char *ui_folder, const char *data_folder, int width, int height,
                        int dark, castor_web_message callback, void *context) {
    if (web_window) {
        ShowWindow(web_window, IsIconic(web_window) ? SW_RESTORE : SW_SHOW);
        SetForegroundWindow(web_window);
        return 1;
    }
    // WebView2 lives on a single-threaded apartment; the hosts call this from a worker thread.
    HRESULT apartment = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (apartment == RPC_E_CHANGED_MODE) { web_last_error = apartment; return -1; }
    WCHAR module_path[MAX_PATH];
    DWORD length = GetModuleFileNameW(nullptr, module_path, MAX_PATH);
    if (!length || length >= MAX_PATH) return -1;
    WCHAR *slash = wcsrchr(module_path, L'\\');
    if (!slash) return -1;
    wcscpy_s(slash + 1, MAX_PATH - (size_t)(slash + 1 - module_path), L"WebView2Loader.dll");
    HMODULE loader = LoadLibraryExW(module_path, nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!loader) { web_last_error = HRESULT_FROM_WIN32(GetLastError()); return -1; }
    CreateEnvironment create = (CreateEnvironment)(void *)GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions");
    if (!create) return -1;

    HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSEXW cls = {sizeof(cls)};
    cls.lpfnWndProc = web_window_proc;
    cls.hInstance = instance;
    cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    cls.hbrBackground = CreateSolidBrush(dark ? RGB(15, 15, 19) : RGB(247, 247, 249));
    cls.lpszClassName = L"CastorCreationWindow";
    // The app icon ships as Castor.ico beside the executable.
    wcscpy_s(slash + 1, MAX_PATH - (size_t)(slash + 1 - module_path), L"Castor.ico");
    cls.hIcon = (HICON)LoadImageW(nullptr, module_path, IMAGE_ICON, GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_LOADFROMFILE);
    cls.hIconSm = (HICON)LoadImageW(nullptr, module_path, IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_LOADFROMFILE);
    RegisterClassExW(&cls);

    WCHAR *wide_title = web_wide(title);
    UINT dpi = GetDpiForSystem();
    HWND hwnd = CreateWindowExW(0, cls.lpszClassName, wide_title ? wide_title : L"Castor",
                                WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                                MulDiv(width, (int)dpi, 96), MulDiv(height, (int)dpi, 96),
                                nullptr, nullptr, instance, nullptr);
    free(wide_title);
    if (!hwnd) return -1;
    BOOL use_dark = dark ? TRUE : FALSE;
    DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &use_dark, sizeof(use_dark));
    web_window = hwnd;
    web_callback = callback;
    web_context = context;
    web_state = 0;

    WCHAR *folder = web_wide(ui_folder);
    WCHAR *data = web_wide(data_folder);
    if (!folder || !data) { free(folder); free(data); DestroyWindow(hwnd); return -1; }
    COLORREF background = dark ? RGB(15, 15, 19) : RGB(247, 247, 249);
    HRESULT status = create(nullptr, data, nullptr,
        web_handler<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, HRESULT, ICoreWebView2Environment *>(
            [folder, background](HRESULT result, ICoreWebView2Environment *environment) -> HRESULT {
                if (FAILED(result) || !environment || !web_window) { web_last_error = result; web_state = -1; free(folder); return S_OK; }
                environment->CreateCoreWebView2Controller(web_window,
                    web_handler<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, HRESULT, ICoreWebView2Controller *>(
                        [folder, background](HRESULT result, ICoreWebView2Controller *controller) -> HRESULT {
                            if (FAILED(result) || !controller || !web_window) { web_last_error = result; web_state = -1; free(folder); return S_OK; }
                            web_controller = controller;
                            web_controller->AddRef();
                            ICoreWebView2Controller2 *controller2 = nullptr;
                            if (SUCCEEDED(controller->QueryInterface(__uuidof(ICoreWebView2Controller2), (void **)&controller2)) && controller2) {
                                COREWEBVIEW2_COLOR color = {255, GetRValue(background), GetGValue(background), GetBValue(background)};
                                controller2->put_DefaultBackgroundColor(color);
                                controller2->Release();
                            }
                            controller->get_CoreWebView2(&web_view);
                            web_resize();
                            if (web_view) web_configure(folder);
                            web_state = web_view ? 1 : -1;
                            free(folder);
                            return S_OK;
                        }));
                return S_OK;
            }));
    free(data);
    if (FAILED(status)) { web_last_error = status; free(folder); DestroyWindow(hwnd); return -1; }
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    return 1;
}

int castor_system_dark(void) {
    DWORD light = 0, size = sizeof(light);
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                     L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size) != ERROR_SUCCESS) return 1;
    return light ? 0 : 1;
}

int castor_webview_state(void) { return web_window ? web_state : -2; }

int castor_webview_post(const char *json) {
    HWND hwnd = web_window;
    if (!hwnd || !json) return 0;
    WCHAR *wide = web_wide(json);
    if (!wide) return 0;
    if (!PostMessageW(hwnd, kPostMessage, 0, (LPARAM)wide)) { free(wide); return 0; }
    return 1;
}

void castor_webview_close(void) {
    if (web_window) PostMessageW(web_window, WM_CLOSE, 0, 0);
}
#else
int castor_webview_open(const char *, const char *, const char *, int, int, int, castor_web_message, void *) { return -1; }
int castor_webview_state(void) { return -2; }
long castor_webview_last_error(void) { return 0; }
int castor_system_dark(void) { return 1; }
int castor_webview_post(const char *) { return 0; }
void castor_webview_close(void) {}
#endif

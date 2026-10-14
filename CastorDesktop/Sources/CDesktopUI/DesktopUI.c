#include "CDesktopUI.h"
#ifdef _WIN32
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <windowsx.h>
#include <commdlg.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <wchar.h>

int castor_choose_file(int save, const char *kind, char *output, size_t capacity) {
    WCHAR file[32768] = {0};
    const WCHAR *filter = save ? L"Arils avatar (*.arils)\0*.arils\0\0" :
        strcmp(kind, "pet") == 0 ? L"Castor / Arils (*.json;*.arils)\0*.json;*.arils\0\0" : L"PNG image (*.png)\0*.png\0\0";
    OPENFILENAMEW dialog = {0}; dialog.lStructSize = sizeof(dialog);
    dialog.lpstrFile = file; dialog.nMaxFile = 32768; dialog.lpstrFilter = filter;
    dialog.lpstrDefExt = save ? L"arils" : NULL;
    dialog.lpstrTitle = save ? L"Castor - リグを保存" : L"Castor - ファイルを選択";
    dialog.Flags = OFN_EXPLORER | OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST |
        (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
    BOOL ok = save ? GetSaveFileNameW(&dialog) : GetOpenFileNameW(&dialog);
    if (!ok) return CommDlgExtendedError() ? -1 : 0;
    return WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, file, -1, output, (int)capacity, NULL, NULL) ? 1 : -1;
}

typedef struct {
    int width, height, selected, dragging, accepted;
    float *rectangles, startX, startY;
    float scale, left, top;
    uint8_t *bgra;
    HWND edits[16];
} MarkerEditor;

static void update_edits(MarkerEditor *state) {
    for (int i = 0; i < 16; ++i) {
        WCHAR value[40]; swprintf(value, 40, L"%.1f", state->rectangles[i]);
        SetWindowTextW(state->edits[i], value);
    }
}
static int read_edits(MarkerEditor *state) {
    for (int i = 0; i < 16; ++i) {
        WCHAR value[40], *end; GetWindowTextW(state->edits[i], value, 40);
        float parsed = wcstof(value, &end);
        if (end == value || *end || !isfinite(parsed)) return 0;
        state->rectangles[i] = parsed;
    }
    for (int i = 0; i < 4; ++i) {
        float *r = state->rectangles + i * 4;
        if (r[0] < 0 || r[1] < 0 || r[2] < 1 || r[3] < 1 || r[0] + r[2] > state->width || r[1] + r[3] > state->height) return 0;
        if (i && (r[0] < state->rectangles[0] || r[1] < state->rectangles[1] ||
                  r[0]+r[2] > state->rectangles[0]+state->rectangles[2] ||
                  r[1]+r[3] > state->rectangles[1]+state->rectangles[3])) return 0;
    }
    return state->rectangles[4]+state->rectangles[6]/2 < state->rectangles[8]+state->rectangles[10]/2;
}
static LRESULT CALLBACK marker_proc(HWND hwnd, UINT message, WPARAM w, LPARAM l) {
    MarkerEditor *s = (MarkerEditor *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (message == WM_NCCREATE) {
        s = (MarkerEditor *)((CREATESTRUCTW *)l)->lpCreateParams;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)s);
    }
    if (!s) return DefWindowProcW(hwnd, message, w, l);
    switch (message) {
    case WM_PAINT: {
        PAINTSTRUCT paint; HDC dc = BeginPaint(hwnd, &paint);
        BITMAPINFO info = {0}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth = s->width; info.bmiHeader.biHeight = -s->height;
        info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32;
        StretchDIBits(dc, (int)s->left, (int)s->top, (int)(s->width*s->scale), (int)(s->height*s->scale),
                     0, 0, s->width, s->height, s->bgra, &info, DIB_RGB_COLORS, SRCCOPY);
        COLORREF colors[4] = {RGB(250,90,40), RGB(30,170,80), RGB(30,100,240), RGB(210,50,200)};
        HGDIOBJ brush = SelectObject(dc, GetStockObject(HOLLOW_BRUSH));
        for (int i=0;i<4;++i) {
            float *r=s->rectangles+i*4; HPEN pen=CreatePen(PS_SOLID, i==s->selected ? 3 : 1, colors[i]);
            HGDIOBJ previous=SelectObject(dc,pen);
            Rectangle(dc,(int)(s->left+r[0]*s->scale),(int)(s->top+r[1]*s->scale),
                      (int)(s->left+(r[0]+r[2])*s->scale),(int)(s->top+(r[1]+r[3])*s->scale));
            SelectObject(dc,previous); DeleteObject(pen);
        }
        SelectObject(dc,brush); EndPaint(hwnd,&paint); return 0;
    }
    case WM_LBUTTONDOWN: {
        float x=(GET_X_LPARAM(l)-s->left)/s->scale, y=(GET_Y_LPARAM(l)-s->top)/s->scale;
        if(x>=0 && y>=0 && x<s->width && y<s->height) {
            s->dragging=1;s->startX=x;s->startY=y;SetCapture(hwnd);
        }
        return 0;
    }
    case WM_MOUSEMOVE:
        if(s->dragging) {
            float x=fmaxf(0,fminf((GET_X_LPARAM(l)-s->left)/s->scale,(float)s->width));
            float y=fmaxf(0,fminf((GET_Y_LPARAM(l)-s->top)/s->scale,(float)s->height));
            float *r=s->rectangles+s->selected*4;
            r[0]=fminf(s->startX,x);r[1]=fminf(s->startY,y);r[2]=fabsf(x-s->startX);r[3]=fabsf(y-s->startY);
            update_edits(s);InvalidateRect(hwnd,NULL,FALSE);
        }
        return 0;
    case WM_LBUTTONUP: if(s->dragging){s->dragging=0;ReleaseCapture();} return 0;
    case WM_COMMAND: {
        int id=LOWORD(w);
        if(id>=300 && id<304){s->selected=id-300;InvalidateRect(hwnd,NULL,FALSE);return 0;}
        if(id==IDOK) {
            if(!read_edits(s)){MessageBoxW(hwnd,L"頭・目・口の範囲を確認してください。目と口は頭の内側、左右は見る側基準です。",L"Castor",MB_OK|MB_ICONWARNING);return 0;}
            s->accepted=1;DestroyWindow(hwnd);return 0;
        }
        if(id==IDCANCEL){DestroyWindow(hwnd);return 0;}
        if(HIWORD(w)==EN_KILLFOCUS){read_edits(s);InvalidateRect(hwnd,NULL,FALSE);}
        return 0;
    }
    case WM_CLOSE: DestroyWindow(hwnd);return 0;
    default:return DefWindowProcW(hwnd,message,w,l);
    }
}

int castor_review_markers(const uint8_t *rgba,int width,int height,float *rectangles) {
    if(!rgba || !rectangles || width<=0 || height<=0 || width>4096 || height>4096) return -1;
    MarkerEditor state={0}; state.width=width;state.height=height;state.rectangles=rectangles;
    state.scale=fminf(620.0f/width,620.0f/height);state.left=20+(620-width*state.scale)/2;state.top=20+(620-height*state.scale)/2;
    state.bgra=malloc((size_t)width*height*4); if(!state.bgra) return -1;
    for(size_t i=0;i<(size_t)width*height;++i) {
        int alpha=rgba[i*4+3], shade=((i%width)/16+(i/width)/16)%2?235:255;
        for(int c=0;c<3;++c)state.bgra[i*4+c]=(uint8_t)((rgba[i*4+2-c]*alpha+shade*(255-alpha)+127)/255);
        state.bgra[i*4+3]=255;
    }
    HINSTANCE instance=GetModuleHandleW(NULL);WNDCLASSW cls={0};cls.hInstance=instance;cls.lpfnWndProc=marker_proc;
    cls.lpszClassName=L"CastorMarkerEditor";cls.hCursor=LoadCursorW(NULL,IDC_ARROW);cls.hbrBackground=(HBRUSH)(COLOR_WINDOW+1);
    if(!RegisterClassW(&cls) && GetLastError()!=ERROR_CLASS_ALREADY_EXISTS){free(state.bgra);return -1;}
    HWND hwnd=CreateWindowExW(0,cls.lpszClassName,L"Castor - 顔マーカー補正（2D試作）",WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX,
        CW_USEDEFAULT,CW_USEDEFAULT,1000,730,NULL,NULL,instance,&state);
    if(!hwnd){free(state.bgra);return -1;}
    CreateWindowW(L"STATIC",L"顔マーカーはテンプレートです。\n部位を選び、画像上でドラッグして\n範囲を指定してください。\n\nMac同等の自動リギングは開発中。",WS_CHILD|WS_VISIBLE,665,20,300,105,hwnd,NULL,instance,NULL);
    const WCHAR *names[4]={L"頭",L"見る側の左目",L"見る側の右目",L"口"};
    const WCHAR *labels[4]={L"X",L"Y",L"幅",L"高さ"};
    for(int row=0;row<4;++row) {
        HWND radio=CreateWindowW(L"BUTTON",names[row],WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_AUTORADIOBUTTON|(row==0?WS_GROUP:0),665,140+row*90,270,24,hwnd,(HMENU)(INT_PTR)(300+row),instance,NULL);
        if(row==0)SendMessageW(radio,BM_SETCHECK,BST_CHECKED,0);
        for(int c=0;c<4;++c) {
            CreateWindowW(L"STATIC",labels[c],WS_CHILD|WS_VISIBLE,665+c*72,170+row*90,65,18,hwnd,NULL,instance,NULL);
            state.edits[row*4+c]=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"",WS_CHILD|WS_VISIBLE|WS_TABSTOP|ES_AUTOHSCROLL,665+c*72,190+row*90,65,24,hwnd,(HMENU)(INT_PTR)(400+row*4+c),instance,NULL);
        }
    }
    CreateWindowW(L"BUTTON",L"この位置で作成",WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_DEFPUSHBUTTON,665,545,170,35,hwnd,(HMENU)IDOK,instance,NULL);
    CreateWindowW(L"BUTTON",L"キャンセル",WS_CHILD|WS_VISIBLE|WS_TABSTOP,840,545,115,35,hwnd,(HMENU)IDCANCEL,instance,NULL);
    update_edits(&state);ShowWindow(hwnd,SW_SHOW);UpdateWindow(hwnd);
    MSG message;
    while(IsWindow(hwnd)) {
        int status=GetMessageW(&message,NULL,0,0);
        if(status<=0){if(status==0)PostQuitMessage((int)message.wParam);break;}
        if(!IsDialogMessageW(hwnd,&message)){TranslateMessage(&message);DispatchMessageW(&message);}
    }
    if(IsWindow(hwnd))DestroyWindow(hwnd);
    free(state.bgra);return state.accepted;
}
#else
int castor_choose_file(int save,const char *kind,char *output,size_t capacity){return -1;}
int castor_review_markers(const uint8_t *rgba,int width,int height,float *rectangles){return -1;}
#endif

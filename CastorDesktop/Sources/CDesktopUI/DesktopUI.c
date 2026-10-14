#include "CDesktopUI.h"
static int castor_ui_japanese=1;
void castor_set_ui_language(int japanese) {castor_ui_japanese=japanese!=0;}
#define UI_TEXT(ja,en) (castor_ui_japanese ? (ja) : (en))
#ifdef _WIN32
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <windowsx.h>
#include <commdlg.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <wchar.h>

int castor_open_microphone_settings(void) {return (INT_PTR)ShellExecuteW(NULL,L"open",L"ms-settings:privacy-microphone",NULL,NULL,SW_SHOWNORMAL)>32 ? 1:-1;}

int castor_choose_file(int save, const char *kind, char *output, size_t capacity) {
    WCHAR file[32768] = {0};
    const WCHAR *filter = save ? (strcmp(kind,"gif")==0 ? L"GIF image (*.gif)\0*.gif\0\0" : strcmp(kind,"json")==0 ? L"Castor pet (*.json)\0*.json\0\0" : L"Arils avatar (*.arils)\0*.arils\0\0") :
        strcmp(kind, "pet") == 0 ? L"Castor / Arils (*.json;*.arils)\0*.json;*.arils\0\0" : L"Images (*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.bmp;*.gif)\0*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.bmp;*.gif\0\0";
    OPENFILENAMEW dialog = {0}; dialog.lStructSize = sizeof(dialog);
    dialog.lpstrFile = file; dialog.nMaxFile = 32768; dialog.lpstrFilter = filter;
    dialog.lpstrDefExt = save ? (strcmp(kind,"gif")==0 ? L"gif" : strcmp(kind,"json")==0 ? L"json" : L"arils") : NULL;
    dialog.lpstrTitle = save ? UI_TEXT(L"Castor - リグを保存",L"Castor - Save") : UI_TEXT(L"Castor - ファイルを選択",L"Castor - Choose a file");
    dialog.Flags = OFN_EXPLORER | OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST |
        (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
    BOOL ok = save ? GetSaveFileNameW(&dialog) : GetOpenFileNameW(&dialog);
    if (!ok) return CommDlgExtendedError() ? -1 : 0;
    return WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, file, -1, output, (int)capacity, NULL, NULL) ? 1 : -1;
}

typedef struct {
    int width, height, selected, dragging, accepted, count;
    float *rectangles, startX, startY;
    float scale, left, top;
    uint8_t *bgra;
    HWND edits[16];
} MarkerEditor;

static void update_edits(MarkerEditor *state) {
    for (int i = 0; i < state->count*4; ++i) {
        WCHAR value[40]; swprintf(value, 40, L"%.1f", state->rectangles[i]);
        SetWindowTextW(state->edits[i], value);
    }
}
static int read_edits(MarkerEditor *state) {
    for (int i = 0; i < state->count*4; ++i) {
        WCHAR value[40], *end; GetWindowTextW(state->edits[i], value, 40);
        float parsed = wcstof(value, &end);
        if (end == value || *end || !isfinite(parsed)) return 0;
        state->rectangles[i] = parsed;
    }
    for (int i = 0; i < state->count; ++i) {
        float *r = state->rectangles + i * 4;
        if (r[0] < 0 || r[1] < 0 || r[2] < 1 || r[3] < 1 || r[0] + r[2] > state->width || r[1] + r[3] > state->height) return 0;
        if (state->count==4 && i && (r[0] < state->rectangles[0] || r[1] < state->rectangles[1] ||
                  r[0]+r[2] > state->rectangles[0]+state->rectangles[2] ||
                  r[1]+r[3] > state->rectangles[1]+state->rectangles[3])) return 0;
    }
    return state->count==1 || state->rectangles[4]+state->rectangles[6]/2 < state->rectangles[8]+state->rectangles[10]/2;
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
        for (int i=0;i<s->count;++i) {
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
        if(id>=300 && id<300+s->count){s->selected=id-300;InvalidateRect(hwnd,NULL,FALSE);return 0;}
        if(id==IDOK) {
            if(!read_edits(s)){MessageBoxW(hwnd,s->count==1 ? UI_TEXT(L"範囲が画像の内側に収まるように指定してください。",L"Keep the rectangle within the image.") : UI_TEXT(L"頭・目・口の範囲を確認してください。目と口は頭の内側、左右は見る側基準です。",L"Check the head, eyes and mouth. Keep the eyes and mouth inside the head."),L"Castor",MB_OK|MB_ICONWARNING);return 0;}
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

static int castor_review_rectangles(const uint8_t *rgba,int width,int height,float *rectangles,int count) {
    if(!rgba || !rectangles || width<=0 || height<=0 || width>4096 || height>4096) return -1;
    MarkerEditor state={0}; state.count=count; state.width=width;state.height=height;state.rectangles=rectangles;
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
    HWND owner=GetActiveWindow();
    HWND hwnd=CreateWindowExW(0,cls.lpszClassName,count==1 ? UI_TEXT(L"Castor - 手動リグの部位範囲",L"Castor - Manual part rectangle") : UI_TEXT(L"Castor - 顔マーカー補正",L"Castor - Review face markers"),WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX,
        CW_USEDEFAULT,CW_USEDEFAULT,1000,730,owner,NULL,instance,&state);
    if(!hwnd){free(state.bgra);return -1;}
    if(owner)EnableWindow(owner,FALSE);
    CreateWindowW(L"STATIC",UI_TEXT(L"推定結果を確認・補正してください。\n部位を選び、画像上でドラッグして\n範囲を指定できます。\n\n左右は見る側基準です。",L"Review the suggested markers.\nChoose a part and drag on the image\nto set its rectangle.\n\nLeft and right mean the viewer's sides."),WS_CHILD|WS_VISIBLE,665,20,300,105,hwnd,NULL,instance,NULL);
    const WCHAR *names[4]={UI_TEXT(L"頭",L"Head"),UI_TEXT(L"見る側の左目",L"Viewer-left eye"),UI_TEXT(L"見る側の右目",L"Viewer-right eye"),UI_TEXT(L"口",L"Mouth")};
    const WCHAR *labels[4]={L"X",L"Y",UI_TEXT(L"幅",L"Width"),UI_TEXT(L"高さ",L"Height")};
    for(int row=0;row<count;++row) {
        HWND radio=CreateWindowW(L"BUTTON",count==1 ? UI_TEXT(L"編集中の部位",L"Selected part") : names[row],WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_AUTORADIOBUTTON|(row==0?WS_GROUP:0),665,140+row*90,270,24,hwnd,(HMENU)(INT_PTR)(300+row),instance,NULL);
        if(row==0)SendMessageW(radio,BM_SETCHECK,BST_CHECKED,0);
        for(int c=0;c<4;++c) {
            CreateWindowW(L"STATIC",labels[c],WS_CHILD|WS_VISIBLE,665+c*72,170+row*90,65,18,hwnd,NULL,instance,NULL);
            state.edits[row*4+c]=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"",WS_CHILD|WS_VISIBLE|WS_TABSTOP|ES_AUTOHSCROLL,665+c*72,190+row*90,65,24,hwnd,(HMENU)(INT_PTR)(400+row*4+c),instance,NULL);
        }
    }
    CreateWindowW(L"BUTTON",UI_TEXT(L"この位置で作成",L"Build with these markers"),WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_DEFPUSHBUTTON,665,545,170,35,hwnd,(HMENU)IDOK,instance,NULL);
    CreateWindowW(L"BUTTON",UI_TEXT(L"キャンセル",L"Cancel"),WS_CHILD|WS_VISIBLE|WS_TABSTOP,840,545,115,35,hwnd,(HMENU)IDCANCEL,instance,NULL);
    update_edits(&state);ShowWindow(hwnd,SW_SHOW);UpdateWindow(hwnd);
    MSG message;
    while(IsWindow(hwnd)) {
        int status=GetMessageW(&message,NULL,0,0);
        if(status<=0){if(status==0)PostQuitMessage((int)message.wParam);break;}
        if(!IsDialogMessageW(hwnd,&message)){TranslateMessage(&message);DispatchMessageW(&message);}
    }
    if(IsWindow(hwnd))DestroyWindow(hwnd);
    if(owner&&IsWindow(owner)){EnableWindow(owner,TRUE);SetActiveWindow(owner);}
    free(state.bgra);return state.accepted;
}
int castor_review_markers(const uint8_t *rgba,int width,int height,float *rectangles) { return castor_review_rectangles(rgba,width,height,rectangles,4); }
int castor_review_part_rectangle(const uint8_t *rgba,int width,int height,float *rectangle) { return castor_review_rectangles(rgba,width,height,rectangle,1); }
typedef struct { int selected, accepted, cancelled; HWND list; } CastorChoice;
static WCHAR *castor_wide(const char *text) {
    int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,NULL,0);
    if(count<=0 || count>65536)return NULL;
    WCHAR *wide=malloc((size_t)count*sizeof(WCHAR));
    if(wide && !MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,wide,count)){free(wide);return NULL;}
    return wide;
}
static LRESULT CALLBACK choice_proc(HWND hwnd,UINT message,WPARAM w,LPARAM l) {
    CastorChoice *s=(CastorChoice*)GetWindowLongPtrW(hwnd,GWLP_USERDATA);
    if(message==WM_NCCREATE){s=(CastorChoice*)((CREATESTRUCTW*)l)->lpCreateParams;SetWindowLongPtrW(hwnd,GWLP_USERDATA,(LONG_PTR)s);}
    if(!s)return DefWindowProcW(hwnd,message,w,l);
    if(message==WM_COMMAND) {
        if(LOWORD(w)==IDOK || (LOWORD(w)==10 && HIWORD(w)==LBN_DBLCLK)) {
            LRESULT selected=SendMessageW(s->list,LB_GETCURSEL,0,0);
            if(selected==LB_ERR)return 0;
            s->selected=(int)selected;s->accepted=1;DestroyWindow(hwnd);return 0;
        }
        if(LOWORD(w)==IDCANCEL){s->cancelled=1;DestroyWindow(hwnd);return 0;}
    }
    if(message==WM_CLOSE){s->cancelled=1;DestroyWindow(hwnd);return 0;}
    return DefWindowProcW(hwnd,message,w,l);
}
/* General native choice UI. Newline-separated UTF-8 items; returns index+1. */
int castor_choose_option(const char *title,const char *options) {
    WCHAR *caption=castor_wide(title),*items=castor_wide(options);
    if(!caption || !items){free(caption);free(items);return -1;}
    HINSTANCE instance=GetModuleHandleW(NULL);WNDCLASSW cls={0};
    cls.hInstance=instance;cls.lpfnWndProc=choice_proc;cls.lpszClassName=L"CastorChoice";
    cls.hbrBackground=(HBRUSH)(COLOR_WINDOW+1);cls.hCursor=LoadCursorW(NULL,IDC_ARROW);
    if(!RegisterClassW(&cls)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS){free(caption);free(items);return -1;}
    CastorChoice s={0};HWND owner=GetActiveWindow();
    HWND hwnd=CreateWindowExW(0,cls.lpszClassName,caption,WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU,
        CW_USEDEFAULT,CW_USEDEFAULT,720,340,owner,NULL,instance,&s);
    free(caption);if(!hwnd){free(items);return -1;}
    if(owner)EnableWindow(owner,FALSE);
    s.list=CreateWindowExW(WS_EX_CLIENTEDGE,L"LISTBOX",L"",WS_CHILD|WS_VISIBLE|WS_TABSTOP|WS_VSCROLL|LBS_NOTIFY,
        20,20,665,210,hwnd,(HMENU)10,instance,NULL);
    WCHAR *begin=items;
    for(WCHAR *p=items;;++p)if(*p==L'\n'||*p==0){WCHAR end=*p;*p=0;SendMessageW(s.list,LB_ADDSTRING,0,(LPARAM)begin);if(!end)break;begin=p+1;}
    free(items);SendMessageW(s.list,LB_SETCURSEL,0,0);
    CreateWindowW(L"BUTTON",UI_TEXT(L"選択",L"Choose"),WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_DEFPUSHBUTTON,435,245,120,35,hwnd,(HMENU)IDOK,instance,NULL);
    CreateWindowW(L"BUTTON",UI_TEXT(L"キャンセル",L"Cancel"),WS_CHILD|WS_VISIBLE|WS_TABSTOP,565,245,120,35,hwnd,(HMENU)IDCANCEL,instance,NULL);
    ShowWindow(hwnd,SW_SHOW);MSG message;
    while(IsWindow(hwnd)){int status=GetMessageW(&message,NULL,0,0);if(status<=0){if(status==0)PostQuitMessage((int)message.wParam);break;}
        if(!IsDialogMessageW(hwnd,&message)){TranslateMessage(&message);DispatchMessageW(&message);}}
    if(IsWindow(hwnd))DestroyWindow(hwnd);if(owner&&IsWindow(owner)){EnableWindow(owner,TRUE);SetActiveWindow(owner);}
    return s.accepted?s.selected+1:0;
}
static HWND castor_work_label=NULL;
void castor_update_work_text(const char *text) {
    if(!castor_work_label||!IsWindow(castor_work_label))return;
    WCHAR *wide=castor_wide(text);if(wide){SetWindowTextW(castor_work_label,wide);free(wide);}
}
/* Polling only reads the host's locked completion state. Work runs off-thread. */
int castor_wait_work(const char *text,int (*poll)(void*),void *context) {
    WCHAR *caption=castor_wide(text);if(!caption||!poll){free(caption);return -1;}
    HINSTANCE instance=GetModuleHandleW(NULL);WNDCLASSW cls={0};cls.hInstance=instance;
    cls.lpfnWndProc=choice_proc;cls.lpszClassName=L"CastorProgress";cls.hbrBackground=(HBRUSH)(COLOR_WINDOW+1);
    if(!RegisterClassW(&cls)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS){free(caption);return -1;}
    CastorChoice s={0};HWND owner=GetActiveWindow();
    HWND hwnd=CreateWindowExW(0,cls.lpszClassName,UI_TEXT(L"Castor - 作成中",L"Castor - Working"),WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU,
        CW_USEDEFAULT,CW_USEDEFAULT,650,190,owner,NULL,instance,&s);
    if(!hwnd){free(caption);return -1;}if(owner)EnableWindow(owner,FALSE);
    castor_work_label=CreateWindowW(L"STATIC",caption,WS_CHILD|WS_VISIBLE,20,20,600,65,hwnd,NULL,instance,NULL);free(caption);
    CreateWindowW(L"BUTTON",UI_TEXT(L"キャンセル",L"Cancel"),WS_CHILD|WS_VISIBLE|WS_TABSTOP,470,95,140,32,hwnd,(HMENU)IDCANCEL,instance,NULL);
    ShowWindow(hwnd,SW_SHOW);UpdateWindow(hwnd);
    while(IsWindow(hwnd)&&!poll(context)) {
        MsgWaitForMultipleObjects(0,NULL,FALSE,50,QS_ALLINPUT);MSG message;
        while(PeekMessageW(&message,NULL,0,0,PM_REMOVE)) {
            if(message.message==WM_QUIT){s.cancelled=1;DestroyWindow(hwnd);PostQuitMessage((int)message.wParam);break;}
            if(!IsDialogMessageW(hwnd,&message)){TranslateMessage(&message);DispatchMessageW(&message);}
        }
    }
    int done=!s.cancelled && poll(context);if(IsWindow(hwnd))DestroyWindow(hwnd);
    castor_work_label=NULL;
    if(owner&&IsWindow(owner)){EnableWindow(owner,TRUE);SetActiveWindow(owner);}return done?1:0;
}

typedef struct { const uint8_t *frames; int count,width,height,index,result; } CastorGIFPreview;
static LRESULT CALLBACK gif_preview_proc(HWND hwnd,UINT message,WPARAM w,LPARAM l) {
    CastorGIFPreview *s=(CastorGIFPreview*)GetWindowLongPtrW(hwnd,GWLP_USERDATA);
    if(message==WM_NCCREATE){s=(CastorGIFPreview*)((CREATESTRUCTW*)l)->lpCreateParams;SetWindowLongPtrW(hwnd,GWLP_USERDATA,(LONG_PTR)s);}
    if(!s)return DefWindowProcW(hwnd,message,w,l);
    if(message==WM_TIMER){s->index=(s->index+1)%s->count;InvalidateRect(hwnd,NULL,FALSE);return 0;}
    if(message==WM_PAINT){
        PAINTSTRUCT paint;HDC dc=BeginPaint(hwnd,&paint);BITMAPINFO info={0};
        info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=s->width;info.bmiHeader.biHeight=-s->height;
        info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;
        const uint8_t *frame=s->frames+(size_t)s->index*s->width*s->height*4;
        StretchDIBits(dc,20,20,384,384,0,0,s->width,s->height,frame,&info,DIB_RGB_COLORS,SRCCOPY);
        EndPaint(hwnd,&paint);return 0;
    }
    if(message==WM_COMMAND){if(LOWORD(w)==IDOK)s->result=2;else if(LOWORD(w)==11)s->result=1;else if(LOWORD(w)!=IDCANCEL)return 0;
        KillTimer(hwnd,1);DestroyWindow(hwnd);return 0;}
    if(message==WM_CLOSE){KillTimer(hwnd,1);DestroyWindow(hwnd);return 0;}
    return DefWindowProcW(hwnd,message,w,l);
}
int castor_preview_gif(const uint8_t *frames,int count,int width,int height,int fps) {
    if(!frames||count<1||count>100||width<1||height<1||width>384||height>384||fps<1||fps>20)return -1;
    HINSTANCE instance=GetModuleHandleW(NULL);WNDCLASSW cls={0};cls.hInstance=instance;cls.lpfnWndProc=gif_preview_proc;
    cls.lpszClassName=L"CastorGIFPreview";cls.hbrBackground=(HBRUSH)(COLOR_WINDOW+1);cls.hCursor=LoadCursorW(NULL,IDC_ARROW);
    if(!RegisterClassW(&cls)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS)return -1;
    CastorGIFPreview s={frames,count,width,height,0,0};HWND owner=GetActiveWindow();
    HWND hwnd=CreateWindowExW(0,cls.lpszClassName,UI_TEXT(L"Castor - GIFプレビュー",L"Castor - GIF Preview"),WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU,
        CW_USEDEFAULT,CW_USEDEFAULT,755,465,owner,NULL,instance,&s);
    if(!hwnd)return -1;if(owner)EnableWindow(owner,FALSE);
    CreateWindowW(L"STATIC",UI_TEXT(L"GIFは自動添付されません。\n保存したGIFをXの投稿画面で\n手動で添付してください。\n\n投稿の確定はXで行います。",L"The GIF is not attached automatically.\nAttach the saved GIF manually in X.\n\nConfirm your post on X."),WS_CHILD|WS_VISIBLE,430,35,300,135,hwnd,NULL,instance,NULL);
    CreateWindowW(L"BUTTON",UI_TEXT(L"GIFを保存してXを開く",L"Save GIF and open X"),WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_DEFPUSHBUTTON,430,190,285,38,hwnd,(HMENU)IDOK,instance,NULL);
    CreateWindowW(L"BUTTON",UI_TEXT(L"GIFだけ保存",L"Save GIF only"),WS_CHILD|WS_VISIBLE|WS_TABSTOP,430,240,285,38,hwnd,(HMENU)11,instance,NULL);
    CreateWindowW(L"BUTTON",UI_TEXT(L"キャンセル",L"Cancel"),WS_CHILD|WS_VISIBLE|WS_TABSTOP,430,290,285,38,hwnd,(HMENU)IDCANCEL,instance,NULL);
    ShowWindow(hwnd,SW_SHOW);SetTimer(hwnd,1,1000/fps,NULL);MSG message;
    while(IsWindow(hwnd)){int status=GetMessageW(&message,NULL,0,0);if(status<=0){if(status==0)PostQuitMessage((int)message.wParam);break;}
        if(!IsDialogMessageW(hwnd,&message)){TranslateMessage(&message);DispatchMessageW(&message);}}
    if(IsWindow(hwnd)){KillTimer(hwnd,1);DestroyWindow(hwnd);}if(owner&&IsWindow(owner)){EnableWindow(owner,TRUE);SetActiveWindow(owner);}return s.result;
}
int castor_open_url(const char *url) {
    if(strncmp(url,"https://",8)!=0)return -1;
    WCHAR *wide=castor_wide(url);if(!wide)return -1;
    INT_PTR result=(INT_PTR)ShellExecuteW(NULL,L"open",wide,NULL,NULL,SW_SHOWNORMAL);free(wide);return result>32?1:-1;
}

typedef struct { HWND edit; int accepted,readonly; } CastorTextDialog;
static LRESULT CALLBACK text_proc(HWND hwnd,UINT message,WPARAM w,LPARAM l) {
    CastorTextDialog *s=(CastorTextDialog*)GetWindowLongPtrW(hwnd,GWLP_USERDATA);
    if(message==WM_NCCREATE){s=(CastorTextDialog*)((CREATESTRUCTW*)l)->lpCreateParams;SetWindowLongPtrW(hwnd,GWLP_USERDATA,(LONG_PTR)s);}
    if(!s)return DefWindowProcW(hwnd,message,w,l);
    if(message==WM_COMMAND&&LOWORD(w)==IDOK){s->accepted=1;ShowWindow(hwnd,SW_HIDE);return 0;}
    if(message==WM_CLOSE||(message==WM_COMMAND&&LOWORD(w)==IDCANCEL)){ShowWindow(hwnd,SW_HIDE);return 0;}
    return DefWindowProcW(hwnd,message,w,l);
}
int castor_edit_text(const char *title,const char *initial,int readonly,char *output,size_t capacity) {
    if(!output||capacity<1||capacity>131072)return -1;
    WCHAR *caption=castor_wide(title),*text=castor_wide(initial);
    if(!caption||!text){free(caption);free(text);return -1;}
    HINSTANCE instance=GetModuleHandleW(NULL);WNDCLASSW cls={0};cls.hInstance=instance;cls.lpfnWndProc=text_proc;
    cls.lpszClassName=L"CastorText";cls.hbrBackground=(HBRUSH)(COLOR_WINDOW+1);cls.hCursor=LoadCursorW(NULL,IDC_ARROW);
    if(!RegisterClassW(&cls)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS){free(caption);free(text);return -1;}
    CastorTextDialog s={0};s.readonly=readonly;HWND owner=GetActiveWindow();
    HWND hwnd=CreateWindowExW(0,cls.lpszClassName,caption,WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU,
        CW_USEDEFAULT,CW_USEDEFAULT,760,450,owner,NULL,instance,&s);free(caption);
    if(!hwnd){free(text);return -1;}if(owner)EnableWindow(owner,FALSE);
    s.edit=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",text,WS_CHILD|WS_VISIBLE|WS_TABSTOP|WS_VSCROLL|
        ES_MULTILINE|ES_AUTOVSCROLL|ES_WANTRETURN|(readonly?ES_READONLY:0),20,20,705,310,hwnd,(HMENU)10,instance,NULL);free(text);
    SendMessageW(s.edit,EM_SETLIMITTEXT,8000,0);
    CreateWindowW(L"BUTTON",readonly?UI_TEXT(L"閉じる",L"Close"):UI_TEXT(L"決定",L"OK"),WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_DEFPUSHBUTTON,470,350,120,35,hwnd,(HMENU)IDOK,instance,NULL);
    CreateWindowW(L"BUTTON",UI_TEXT(L"キャンセル",L"Cancel"),WS_CHILD|WS_VISIBLE|WS_TABSTOP,600,350,120,35,hwnd,(HMENU)IDCANCEL,instance,NULL);
    ShowWindow(hwnd,SW_SHOW);SetFocus(s.edit);MSG message;
    while(IsWindow(hwnd)&&IsWindowVisible(hwnd)){int status=GetMessageW(&message,NULL,0,0);
        if(status<=0){if(status==0)PostQuitMessage((int)message.wParam);break;}
        if(!IsDialogMessageW(hwnd,&message)){TranslateMessage(&message);DispatchMessageW(&message);}}
    int result=0;
    if(s.accepted&&IsWindow(s.edit)) {
        int length=GetWindowTextLengthW(s.edit);WCHAR *value=calloc((size_t)length+1,sizeof(WCHAR));
        if(value){GetWindowTextW(s.edit,value,length+1);result=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,value,-1,output,(int)capacity,NULL,NULL)?1:-1;free(value);}
        else result=-1;
    }
    if(IsWindow(hwnd))DestroyWindow(hwnd);if(owner&&IsWindow(owner)){EnableWindow(owner,TRUE);SetActiveWindow(owner);}return result;
}

typedef struct { CastorWindowMetadata *windows; size_t capacity,count; HWND focused; DWORD self; } CastorWindowList;
static BOOL CALLBACK metadata_window(HWND hwnd,LPARAM param) {
    CastorWindowList *s=(CastorWindowList*)param;
    if(s->count>=s->capacity)return FALSE;
    DWORD pid=0;GetWindowThreadProcessId(hwnd,&pid);
    if(pid==s->self||!IsWindowVisible(hwnd)||IsIconic(hwnd)||GetWindowLongW(hwnd,GWL_EXSTYLE)&WS_EX_TOOLWINDOW)return TRUE;
    RECT r;if(!GetWindowRect(hwnd,&r)||r.right-r.left<=8||r.bottom-r.top<=8)return TRUE;
    CastorWindowMetadata m={(uint32_t)(UINT_PTR)hwnd,(int32_t)pid,r.left,r.top,r.right-r.left,r.bottom-r.top,hwnd==s->focused};
    s->windows[s->count++]=m;return TRUE;
}
int castor_window_metadata(CastorWindowMetadata *windows,size_t capacity) {
    if(!windows||capacity<1||capacity>1024)return -1;
    CastorWindowList state={windows,capacity,0,GetForegroundWindow(),GetCurrentProcessId()};
    EnumWindows(metadata_window,(LPARAM)&state);return (int)state.count;
}
int castor_monitor_bounds(int x,int y,int32_t *screen,int32_t *work) {
    if(!screen||!work)return -1;POINT p={x,y};HMONITOR monitor=MonitorFromPoint(p,MONITOR_DEFAULTTONEAREST);
    MONITORINFO info={0};info.cbSize=sizeof(info);if(!GetMonitorInfoW(monitor,&info))return -1;
    screen[0]=info.rcMonitor.left;screen[1]=info.rcMonitor.top;screen[2]=info.rcMonitor.right-info.rcMonitor.left;screen[3]=info.rcMonitor.bottom-info.rcMonitor.top;
    work[0]=info.rcWork.left;work[1]=info.rcWork.top;work[2]=info.rcWork.right-info.rcWork.left;work[3]=info.rcWork.bottom-info.rcWork.top;return 1;
}

int castor_launch_file(const char *path) {
    WCHAR *wide=castor_wide(path);if(!wide)return -1;
    INT_PTR result=(INT_PTR)ShellExecuteW(NULL,L"open",wide,NULL,NULL,SW_SHOWNORMAL);free(wide);return result>32?1:-1;
}

#else
int castor_open_microphone_settings(void) {return -1;}
int castor_choose_file(int save,const char *kind,char *output,size_t capacity){return -1;}
int castor_review_markers(const uint8_t *rgba,int width,int height,float *rectangles){return -1;}
int castor_review_part_rectangle(const uint8_t *rgba,int width,int height,float *rectangle){return -1;}
int castor_choose_option(const char *title,const char *options){return -1;}
int castor_wait_work(const char *text,int (*poll)(void*),void *context){return -1;}
int castor_preview_gif(const uint8_t *frames,int count,int width,int height,int fps){return -1;}
int castor_open_url(const char *url){return -1;}
int castor_edit_text(const char *title,const char *initial,int readonly,char *output,size_t capacity){return -1;}
void castor_update_work_text(const char *text){}

int castor_window_metadata(CastorWindowMetadata *windows,size_t capacity){return -1;}
int castor_monitor_bounds(int x,int y,int32_t *screen,int32_t *work){return -1;}

int castor_launch_file(const char *path){return -1;}

#endif

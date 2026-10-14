#include "CDesktopUI.h"
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <vector>
extern "C" int castor_recycle_directory(const char *path) {
    if (!path) return -1;
    int size=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,nullptr,0);
    if (size<=1 || size>32768) return -1;
    std::vector<wchar_t> wide(size);
    if (!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,wide.data(),size)) return -1;
    HRESULT init=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    if (FAILED(init) && init!=RPC_E_CHANGED_MODE) return -1;
    IFileOperation *operation=nullptr; IShellItem *item=nullptr;
    HRESULT result=CoCreateInstance(CLSID_FileOperation,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&operation));
    if (SUCCEEDED(result)) result=operation->SetOperationFlags(
        FOFX_RECYCLEONDELETE | FOFX_ADDUNDORECORD | FOFX_EARLYFAILURE |
        FOF_SILENT | FOF_NOERRORUI | FOF_WANTNUKEWARNING);
    if (SUCCEEDED(result)) result=SHCreateItemFromParsingName(wide.data(),nullptr,IID_PPV_ARGS(&item));
    if (SUCCEEDED(result)) result=operation->DeleteItem(item,nullptr);
    if (SUCCEEDED(result)) result=operation->PerformOperations();
    BOOL aborted=TRUE;
    if (SUCCEEDED(result)) result=operation->GetAnyOperationsAborted(&aborted);
    if (item) item->Release();if (operation) operation->Release();
    if (SUCCEEDED(init)) CoUninitialize();
    return SUCCEEDED(result) && !aborted ? 1:-1;
}
#else
extern "C" int castor_recycle_directory(const char *path) {return -1;}
#endif

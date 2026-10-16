#include "CDesktopUI.h"
#ifdef _WIN32
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <objbase.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <string>
#include <vector>

static std::wstring install_wide(const char *text) {
    int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,nullptr,0);
    if(n<1||n>32768)return {};
    std::vector<WCHAR> result((size_t)n);
    if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,result.data(),n))return {};
    return std::wstring(result.data());
}
static std::wstring canonical_path(const std::wstring &path) {
    DWORD n=GetFullPathNameW(path.c_str(),0,nullptr,nullptr);
    if(!n||n>32768)return {};
    std::vector<WCHAR> buffer(n);
    DWORD written=GetFullPathNameW(path.c_str(),n,buffer.data(),nullptr);
    return written&&written<n ? std::wstring(buffer.data()):std::wstring();
}
static std::wstring quote_arg(const std::wstring &value) {
    std::wstring out=L"\"";size_t slashes=0;
    for(WCHAR c:value) {
        if(c==L'\\'){++slashes;continue;}
        if(c==L'\"'){out.append(slashes*2+1,L'\\');out+=c;}
        else {out.append(slashes,L'\\');out+=c;}
        slashes=0;
    }
    out.append(slashes*2,L'\\');out+=L'\"';return out;
}
int castor_expand_zip(const char *archive,const char *destination,int (*cancelled)(void*),void *context) {
    WCHAR system[32768];UINT length=GetSystemDirectoryW(system,32768);if(!length||length>=32768)return -1;
    std::wstring executable=std::wstring(system)+L"\\WindowsPowerShell\\v1.0\\powershell.exe";
    std::wstring zip=install_wide(archive),folder=install_wide(destination);
    if(zip.empty()||folder.empty())return -1;
    auto literal=[](const std::wstring &path) {
        std::wstring value=L"'";
        for (WCHAR c:path) {value+=c;if (c==L'\'')value+=c;}
        return value+L"'";
    };
    // A fixed command uses PowerShell's built-in ZIP module, with paths as
    // single-quoted literals. No script file or ExecutionPolicy override.
    std::wstring expression=L"$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';Expand-Archive -LiteralPath "+literal(zip)+L" -DestinationPath "+literal(folder);
    std::wstring command=quote_arg(executable)+L" -NoProfile -NonInteractive -Command "+quote_arg(expression);
    std::vector<WCHAR> buffer(command.begin(),command.end());buffer.push_back(0);
    STARTUPINFOW start={};start.cb=sizeof(start);PROCESS_INFORMATION process={};
    if(!CreateProcessW(executable.c_str(),buffer.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&start,&process))return -1;
    int result=1;
    while(WaitForSingleObject(process.hProcess,100)==WAIT_TIMEOUT) {
        if(cancelled&&cancelled(context)){TerminateProcess(process.hProcess,1);WaitForSingleObject(process.hProcess,INFINITE);result=0;break;}
    }
    DWORD exit=1;if(!GetExitCodeProcess(process.hProcess,&exit)||exit!=0)result=result==0?0:-1;
    CloseHandle(process.hThread);CloseHandle(process.hProcess);return result;
}
/// One Start menu entry for CastorPet.exe. Only an entry that already points
/// at a Castor-* install under root is replaced or removed.
static int pet_link(const std::wstring& file,const std::wstring& executable,const std::wstring& root,
                    const wchar_t *arguments,const wchar_t *description,int remove) {
    HRESULT com=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    if(FAILED(com)&&com!=RPC_E_CHANGED_MODE)return -1;
    IShellLinkW *link=nullptr;IPersistFile *persist=nullptr;int result=-1;
    HRESULT status=CoCreateInstance(__uuidof(ShellLink),nullptr,CLSCTX_INPROC_SERVER,__uuidof(IShellLinkW),(void**)&link);
    if(SUCCEEDED(status))status=link->QueryInterface(__uuidof(IPersistFile),(void**)&persist);
    if(SUCCEEDED(status)) {
        bool existing=GetFileAttributesW(file.c_str())!=INVALID_FILE_ATTRIBUTES;
        bool owned=!existing;
        if(existing && SUCCEEDED(persist->Load(file.c_str(),STGM_READ))) {
            WCHAR previous[32768];if(SUCCEEDED(link->GetPath(previous,32768,nullptr,SLGP_RAWPATH))) {
                std::wstring target=canonical_path(previous);
                std::wstring prefix=canonical_path(root)+L"\\Castor-";
                owned=target.size()>prefix.size() && _wcsnicmp(target.c_str(),prefix.c_str(),prefix.size())==0 &&
                    target.size()>=13 && _wcsicmp(target.c_str()+target.size()-13,L"CastorPet.exe")==0;
                if(remove) owned=_wcsicmp(target.c_str(),executable.c_str())==0;
            }
        }
        if(owned) {
            if(remove)result=!existing||DeleteFileW(file.c_str())?1:-1;
            else {
                status=link->SetPath(executable.c_str());
                if(SUCCEEDED(status))status=link->SetArguments(arguments);
                if(SUCCEEDED(status))status=link->SetDescription(description);
                auto split=executable.find_last_of(L"\\/");
                if(SUCCEEDED(status)&&split!=std::wstring::npos)status=link->SetWorkingDirectory(executable.substr(0,split).c_str());
                // The app icon ships as Castor.ico beside the executable.
                if(SUCCEEDED(status)&&split!=std::wstring::npos) {
                    std::wstring icon=executable.substr(0,split)+L"\\Castor.ico";
                    if(GetFileAttributesW(icon.c_str())!=INVALID_FILE_ATTRIBUTES)link->SetIconLocation(icon.c_str(),0);
                }
                if(SUCCEEDED(status)) {
                    std::wstring stage=file+L".new";
                    if(GetFileAttributesW(stage.c_str())==INVALID_FILE_ATTRIBUTES && SUCCEEDED(persist->Save(stage.c_str(),TRUE))) {
                        result=MoveFileExW(stage.c_str(),file.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)?1:-1;
                        if(result<0)DeleteFileW(stage.c_str());
                    }
                }
            }
        }
    }
    if(persist)persist->Release();if(link)link->Release();if(SUCCEEDED(com))CoUninitialize();return result;
}
int castor_pet_shortcut(const char *executablePath,const char *rootPath,int remove) {
    std::wstring executable=install_wide(executablePath),root=install_wide(rootPath);
    for(WCHAR& c:executable)if(c==L'/')c=L'\\';for(WCHAR& c:root)if(c==L'/')c=L'\\';
    if(executable.empty()||root.empty())return -1;
    WCHAR programs[MAX_PATH];if(FAILED(SHGetFolderPathW(nullptr,CSIDL_PROGRAMS,nullptr,SHGFP_TYPE_CURRENT,programs)))return -1;
    int result=pet_link(std::wstring(programs)+L"\\Castor.lnk",executable,root,L"",L"Castor",remove);
    // A second entry opens straight to the settings page, so searching "Castor" finds both, as on the Mac.
    if(result>0)pet_link(std::wstring(programs)+L"\\Castor Settings.lnk",executable,root,L"--settings",L"Castor settings",remove);
    return result;
}
int castor_native_windows_x64(void) {
    typedef BOOL(WINAPI *MachineQuery)(HANDLE,USHORT*,USHORT*);
    MachineQuery query=(MachineQuery)GetProcAddress(GetModuleHandleW(L"kernel32.dll"),"IsWow64Process2");
    if(!query)return 0;USHORT process=0,native=0;
    return query(GetCurrentProcess(),&process,&native)&&native==IMAGE_FILE_MACHINE_AMD64?1:0;
}
#else
int castor_pet_shortcut(const char *executablePath,const char *rootPath,int remove){return -1;}
int castor_expand_zip(const char *archive,const char *destination,int (*cancelled)(void*),void *context){return -1;}
int castor_native_windows_x64(void){return 0;}
#endif

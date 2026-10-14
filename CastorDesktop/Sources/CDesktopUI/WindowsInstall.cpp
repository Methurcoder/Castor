#include "CDesktopUI.h"
#ifdef _WIN32
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <string>
#include <vector>

static std::wstring install_wide(const char *text) {
    int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,nullptr,0);
    if(n<1||n>32768)return {};
    std::vector<WCHAR> result((size_t)n);
    if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,result.data(),n))return {};
    return std::wstring(result.data());
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
int castor_native_windows_x64(void) {
    typedef BOOL(WINAPI *MachineQuery)(HANDLE,USHORT*,USHORT*);
    MachineQuery query=(MachineQuery)GetProcAddress(GetModuleHandleW(L"kernel32.dll"),"IsWow64Process2");
    if(!query)return 0;USHORT process=0,native=0;
    return query(GetCurrentProcess(),&process,&native)&&native==IMAGE_FILE_MACHINE_AMD64?1:0;
}
#else
int castor_expand_zip(const char *archive,const char *destination,int (*cancelled)(void*),void *context){return -1;}
int castor_native_windows_x64(void){return 0;}
#endif

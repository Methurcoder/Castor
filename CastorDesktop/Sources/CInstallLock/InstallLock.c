#include "CInstallLock.h"
#include <stdlib.h>
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
void *castor_install_lock(const char *path) {
    int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,NULL,0);
    if (!count) return NULL;
    wchar_t *wide=(wchar_t *)calloc((size_t)count,sizeof(wchar_t));
    if (!wide) return NULL;
    MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,wide,count);
    HANDLE file=CreateFileW(wide,GENERIC_READ|GENERIC_WRITE,0,NULL,OPEN_ALWAYS,
                          FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,NULL);
    free(wide);
    if (file==INVALID_HANDLE_VALUE) return NULL;
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle(file,&info) || (info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)) {CloseHandle(file);return NULL;}
    return file;
}
void castor_install_unlock(void *lease) { if (lease) CloseHandle((HANDLE)lease); }
#else
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
void *castor_install_lock(const char *path) {
    int descriptor=open(path,O_RDWR|O_CREAT|O_NOFOLLOW,0600);
    if (descriptor<0) return NULL;
    if (flock(descriptor,LOCK_EX|LOCK_NB)!=0) {close(descriptor);return NULL;}
    int *owned=malloc(sizeof(int));
    if (!owned) {close(descriptor);return NULL;}
    *owned=descriptor;return owned;
}
void castor_install_unlock(void *lease) {
    if (lease) {int descriptor=*(int *)lease;flock(descriptor,LOCK_UN);close(descriptor);free(lease);}
}
#endif

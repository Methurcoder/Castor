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
static wchar_t *castor_wide(const char *path) {
    int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,NULL,0);
    if (!count) return NULL;
    wchar_t *wide=(wchar_t *)calloc((size_t)count,sizeof(wchar_t));
    if (wide && !MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,wide,count)) {free(wide);return NULL;}
    return wide;
}
int castor_flush_path(const char *path) {
    wchar_t *wide=castor_wide(path);
    if (!wide) return 0;
    DWORD attributes=GetFileAttributesW(wide);
    if (attributes!=INVALID_FILE_ATTRIBUTES && (attributes&FILE_ATTRIBUTE_DIRECTORY)) {free(wide);return 1;}
    HANDLE file=CreateFileW(wide,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,
                            FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,NULL);
    free(wide);
    if (file==INVALID_HANDLE_VALUE) return 0;
    BOOL flushed=FlushFileBuffers(file);
    CloseHandle(file);
    return flushed ? 1:0;
}
int castor_durable_replace(const char *from, const char *to) {
    if (!castor_flush_path(from)) return 0;
    wchar_t *source=castor_wide(from),*target=castor_wide(to);
    BOOL moved=source && target && MoveFileExW(source,target,MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH);
    free(source);free(target);
    return moved ? 1:0;
}
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
#include <stdio.h>
#include <string.h>
int castor_flush_path(const char *path) {
    int descriptor=open(path,O_RDONLY|O_NOFOLLOW);
    if (descriptor<0) return 0;
    int flushed=fsync(descriptor)==0;
    close(descriptor);
    return flushed;
}
int castor_durable_replace(const char *from, const char *to) {
    if (!castor_flush_path(from) || rename(from,to)!=0) return 0;
    /* The new name must reach the disk too: flush the containing directory. */
    char *folder=strdup(to);
    if (!folder) return 1;
    char *slash=strrchr(folder,'/');
    if (slash) {*(slash==folder ? slash+1:slash)=0;castor_flush_path(folder);}
    free(folder);
    return 1;
}
#endif

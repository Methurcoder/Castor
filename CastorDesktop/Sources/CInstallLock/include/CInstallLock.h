#ifndef CASTOR_INSTALL_LOCK_H
#define CASTOR_INSTALL_LOCK_H
/* OS-owned lock; released automatically if the process crashes. */
void *castor_install_lock(const char *path);
void castor_install_unlock(void *lease);
/* Replaces `to` with `from` in one step that survives a power cut: the data
   is flushed first and the rename is written through. Returns 1 on success. */
int castor_durable_replace(const char *from, const char *to);
/* Flushes `path` (a file, or on POSIX a directory's entries). Returns 1 on success. */
int castor_flush_path(const char *path);
#endif

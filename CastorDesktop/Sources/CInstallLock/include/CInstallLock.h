#ifndef CASTOR_INSTALL_LOCK_H
#define CASTOR_INSTALL_LOCK_H
/* OS-owned lock; released automatically if the process crashes. */
void *castor_install_lock(const char *path);
void castor_install_unlock(void *lease);
#endif

#ifndef CEMUU_SHIM_H
#define CEMUU_SHIM_H
#include <sys/types.h>

/// Non-variadic wrapper around shm_open(2) (Swift cannot call variadic C functions).
int emuu_shm_open(const char *name, int oflag, mode_t mode);

#endif

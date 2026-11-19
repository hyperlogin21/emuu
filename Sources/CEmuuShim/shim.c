#include "CEmuuShim.h"
#include <sys/mman.h>

int emuu_shm_open(const char *name, int oflag, mode_t mode) {
    return shm_open(name, oflag, mode);
}

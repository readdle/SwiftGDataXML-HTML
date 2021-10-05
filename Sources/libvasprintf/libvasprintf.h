#ifndef	_LIBVASPRINTF_H_
#define	_LIBVASPRINTF_H_

#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>

inline static int
vasprintf(char **strp, const char *fmt, va_list args) {
    *strp = NULL;

    va_list vsnprintf_args;
    va_copy(vsnprintf_args, args);
    int length = vsnprintf(NULL, 0, fmt, vsnprintf_args);
    va_end(vsnprintf_args);

    if (length < 0) {
        return -1;
    }

    char *buffer = malloc(length + 1);
    if (buffer == NULL) {
        return -1;
    }

    int result = vsnprintf(buffer, length + 1, fmt, args);
    if (result < 0) {
        free(buffer);
        return -1;
    }

    *strp = buffer;
    
    return result;
}

#endif // _LIBVASPRINTF_H_

/* The precompiled Metal display shader, embedded in libps1shaders.a by
   ps1-macos/Shaders/embed.zig. Declared here rather than in ps1-capi's ps1.h
   because that header is the portable emulator ABI and a Metal shader is not
   part of it. */
#ifndef PS1_DISPLAY_METALLIB_H
#define PS1_DISPLAY_METALLIB_H

#include <stddef.h>

const unsigned char *ps1_display_metallib_ptr(void);
size_t ps1_display_metallib_len(void);

#endif

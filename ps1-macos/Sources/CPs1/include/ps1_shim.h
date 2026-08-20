/* The real contract lives in ps1-capi/include/ps1.h. This shim exists so
   SwiftPM's own include directory stays the module's header root while the
   header of record stays next to the Zig that implements it. */
#include "../../../../ps1-capi/include/ps1.h"

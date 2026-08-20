/* ps1.h — the C ABI for ps1-core.
 *
 * CONTRACT RULES. These three are stated here because getting them wrong is
 * silent rather than loud.
 *
 * 1. The caller owns every buffer that crosses this boundary, with one
 *    exception: ps1_load_disc BORROWS the .bin data and does not copy it. Those
 *    bytes must outlive the handle, or the next ps1_load_disc call. The cue
 *    bytes are parsed immediately and are NOT borrowed.
 *
 * 2. Nothing traps across this boundary. Every failure is a negative code.
 *
 * 3. ps1_reset keeps the loaded BIOS and disc. It is the front-panel reset
 *    button, not a teardown. Running with no disc is valid and boots to the
 *    BIOS shell, so it is not an error condition.
 */
#ifndef PS1_H
#define PS1_H

#include <stdint.h>
#include <stddef.h>

typedef struct Ps1 Ps1;

/* Error codes. 0 is success; all failures are negative. */
#define PS1_OK                  0
#define PS1_ERR_BAD_BIOS_SIZE  (-1)
#define PS1_ERR_BAD_CUE        (-2)
#define PS1_ERR_MULTI_FILE_CUE (-3)
#define PS1_ERR_OOM            (-4)

/* Returns NULL on allocation failure. */
Ps1*    ps1_create(void);
/* Tolerates NULL. */
void    ps1_destroy(Ps1*);
void    ps1_reset(Ps1*);

/* len must be exactly 524288, or PS1_ERR_BAD_BIOS_SIZE. */
int32_t ps1_load_bios(Ps1*, const uint8_t* bytes, size_t len);

#endif /* PS1_H */

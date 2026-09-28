#ifndef TH09_SIDE_KEY_AUTH_H
#define TH09_SIDE_KEY_AUTH_H
#include <windows.h>
#include <wchar.h>

#define TH09_SIDE_KEY_ENVIRONMENT L"TH09_AI_SIDE_KEY"

#ifdef __cplusplus
extern "C" {
#endif

/* Verify the exact UTF-16 input, without normalization or a trailing NUL.
 * Embedded NULs are rejected because the environment transport cannot carry
 * them, and short HMAC keys with trailing zero bytes are otherwise equivalent.
 * The caller owns (and must clear) its input buffer. This is a local gate;
 * a rebuilt or patched program can replace it. Call outside DllMain. */
BOOL Th09VerifySideKey(const wchar_t *key, unsigned int utf16_length);

/* Side 2 needs no key or KDF; side 1 requires the process environment key.
 * Invalid sides fail. If erase_env is TRUE, remove the variable on every
 * path, including rejection. An environment-removal failure also rejects.
 * Call outside DllMain, before permitting any 1P-controlled operation. */
BOOL Th09AuthorizeSideFromEnvironment(int side, BOOL erase_env);

#ifdef __cplusplus
}
#endif
#endif

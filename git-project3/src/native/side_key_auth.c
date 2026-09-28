#include "side_key_auth.h"
#include <string.h>

/* The bundled TinyCC SDK omits the NLS declarations and bcrypt import lib.
 * Resolve CNG from the absolute Windows system directory, never a local DLL.
 * There is no alternate algorithm or authorization result in the environment. */
#ifndef CP_UTF8
#define CP_UTF8 65001
#endif
#ifndef WC_ERR_INVALID_CHARS
#define WC_ERR_INVALID_CHARS 0x00000080
#endif
__declspec(dllimport) int WINAPI WideCharToMultiByte(UINT, DWORD, LPCWSTR, int,
    LPSTR, int, LPCSTR, LPBOOL);

typedef LONG (WINAPI *Th09CngOpen)(PVOID *, LPCWSTR, LPCWSTR, ULONG);
typedef LONG (WINAPI *Th09CngDerive)(PVOID, unsigned char *, ULONG,
    unsigned char *, ULONG, unsigned long long, unsigned char *, ULONG, ULONG);
typedef LONG (WINAPI *Th09CngClose)(PVOID, ULONG);
typedef struct {
    HMODULE module;
    Th09CngOpen open;
    Th09CngDerive derive;
    Th09CngClose close;
} Th09CngApi;

/* v1, PBKDF2-HMAC-SHA256, 600000 iterations. Public salt and verifier only. */
static const unsigned char th09_side_key_salt[16] = {
    0xb8,0x0a,0x77,0xd3,0x44,0x1a,0xe6,0xa4,
    0x92,0xc5,0x61,0xba,0x10,0xef,0xb6,0x06
};
static const unsigned char th09_side_key_expected[32] = {
    0xb7,0xe4,0xe8,0x17,0xef,0xfb,0xc8,0xb2,
    0xbe,0xe0,0x31,0x64,0xde,0x37,0x05,0x0a,
    0xd7,0x50,0x0a,0x86,0x4c,0x8c,0x0c,0xfb,
    0x2b,0x7e,0x27,0x00,0xc3,0x77,0xdc,0x22
};

static void Th09Wipe(void *buffer, unsigned int length)
{
    volatile unsigned char *p = (volatile unsigned char *)buffer;
    while (length--) *p++ = 0;
}

static BOOL Th09Equal32(const unsigned char *a, const unsigned char *b)
{
    unsigned int difference = 0, i;
    /* Inspect every byte; no content-dependent early return. */
    for (i = 0; i < 32; ++i) difference |= (unsigned int)(a[i] ^ b[i]);
    return difference == 0;
}

static BOOL Th09LoadCng(Th09CngApi *api)
{
    wchar_t path[MAX_PATH + 1];
    static const wchar_t suffix[] = L"\\bcrypt.dll";
    UINT length = GetSystemDirectoryW(path, sizeof(path) / sizeof(path[0]));
    memset(api, 0, sizeof(*api));
    if (!length || length >= sizeof(path) / sizeof(path[0]) ||
        length + sizeof(suffix) / sizeof(suffix[0]) > sizeof(path) / sizeof(path[0]))
        return FALSE;
    memcpy(path + length, suffix, sizeof(suffix));
    api->module = LoadLibraryW(path);
    if (!api->module) return FALSE;
    api->open = (Th09CngOpen)GetProcAddress(api->module, "BCryptOpenAlgorithmProvider");
    api->derive = (Th09CngDerive)GetProcAddress(api->module, "BCryptDeriveKeyPBKDF2");
    api->close = (Th09CngClose)GetProcAddress(api->module, "BCryptCloseAlgorithmProvider");
    if (!api->open || !api->derive || !api->close) {
        FreeLibrary(api->module);
        memset(api, 0, sizeof(*api));
        return FALSE;
    }
    return TRUE;
}

/* Fixed profile shared by verification and independent known-answer tests. */
static BOOL Th09DeriveSideKey(const unsigned char *utf8, unsigned int length,
    unsigned char output[32])
{
    Th09CngApi api;
    PVOID algorithm = NULL;
    BOOL success = FALSE;
    unsigned char salt[16];
    memset(output, 0, 32);
    memcpy(salt, th09_side_key_salt, sizeof(salt));
    if (!Th09LoadCng(&api)) goto done;
    /* BCRYPT_ALG_HANDLE_HMAC_FLAG is 0x00000008. NT_SUCCESS means >= 0. */
    if (api.open(&algorithm, L"SHA256", NULL, 0x00000008) < 0 || !algorithm)
        goto close_algorithm;
    if (api.derive(algorithm, (unsigned char *)utf8, (ULONG)length,
        salt, sizeof(salt), 600000ULL, output, 32, 0) < 0)
        goto close_algorithm;
    success = TRUE;
close_algorithm:
    if (algorithm && api.close(algorithm, 0) < 0) success = FALSE;
    FreeLibrary(api.module);
done:
    Th09Wipe(salt, sizeof(salt));
    if (!success) Th09Wipe(output, 32);
    return success;
}

BOOL Th09VerifySideKey(const wchar_t *key, unsigned int utf16_length)
{
    unsigned char utf8[1024], derived[32];
    unsigned int i;
    int bytes;
    BOOL authorized = FALSE;
    memset(utf8, 0, sizeof(utf8));
    memset(derived, 0, sizeof(derived));
    if (!key || utf16_length < 1 || utf16_length > 256) goto done;
    /* Environment values cannot carry NUL. Reject them explicitly instead
     * of truncating, or accepting HMAC's equivalent trailing zero padding. */
    for (i = 0; i < utf16_length; ++i) if (!key[i]) goto done;
    /* Invalid UTF-16 fails instead of being normalized or replaced. */
    bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, key,
        (int)utf16_length, (char *)utf8, sizeof(utf8), NULL, NULL);
    if (bytes < 1 || bytes > (int)sizeof(utf8)) goto done;
    if (!Th09DeriveSideKey(utf8, (unsigned int)bytes, derived)) goto done;
    authorized = Th09Equal32(derived, th09_side_key_expected);
done:
    Th09Wipe(derived, sizeof(derived));
    Th09Wipe(utf8, sizeof(utf8));
    return authorized;
}

BOOL Th09AuthorizeSideFromEnvironment(int side, BOOL erase_env)
{
    wchar_t key[257];
    DWORD length;
    BOOL authorized = FALSE;
    memset(key, 0, sizeof(key));
    if (side == 2) authorized = TRUE;
    else if (side == 1) {
        length = GetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, key,
            sizeof(key) / sizeof(key[0]));
        if (length >= 1 && length <= 256)
            authorized = Th09VerifySideKey(key, (unsigned int)length);
    }
    if (erase_env && !SetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, NULL))
        authorized = FALSE;
    Th09Wipe(key, sizeof(key));
    return authorized;
}

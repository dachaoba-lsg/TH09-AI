/* No game launch, injection, foreign process access, or private key literals.
 * Compile this file alone: it includes the production implementation under
 * local API shims. Production side_key_auth.c has no failure/testing switch. */
#include "side_key_auth.h"
#include <stdio.h>
#include <string.h>

static UINT WINAPI AuthTestSystemDirectory(LPWSTR, UINT);
static HMODULE WINAPI AuthTestLoadLibrary(LPCWSTR);
static FARPROC WINAPI AuthTestGetProcAddress(HMODULE, LPCSTR);
static BOOL WINAPI AuthTestSetEnvironment(LPCWSTR, LPCWSTR);

#define GetSystemDirectoryW AuthTestSystemDirectory
#define LoadLibraryW AuthTestLoadLibrary
#define GetProcAddress AuthTestGetProcAddress
#define SetEnvironmentVariableW AuthTestSetEnvironment
#include "side_key_auth.c"
#undef GetSystemDirectoryW
#undef LoadLibraryW
#undef GetProcAddress
#undef SetEnvironmentVariableW

enum {
    TEST_NORMAL, TEST_SYSTEM_MISSING, TEST_SYSTEM_LONG, TEST_LIBRARY_MISSING,
    TEST_OPEN_MISSING, TEST_DERIVE_MISSING, TEST_CLOSE_MISSING,
    TEST_OPEN_FAILURE, TEST_OPEN_NULL, TEST_OPEN_FAILURE_HANDLE,
    TEST_DERIVE_FAILURE, TEST_CLOSE_FAILURE,
    TEST_ERASE_FAILURE
};
static int mode, checks, failures, load_calls, open_calls, derive_calls, close_calls;
static Th09CngOpen real_open;
static Th09CngDerive real_derive;
static Th09CngClose real_close;

static void check(int condition, const char *description)
{
    ++checks;
    if (!condition) { ++failures; printf("FAIL %s\n", description); }
}

static UINT WINAPI AuthTestSystemDirectory(LPWSTR output, UINT capacity)
{
    if (mode == TEST_SYSTEM_MISSING) return 0;
    if (mode == TEST_SYSTEM_LONG) return capacity + 1;
    return GetSystemDirectoryW(output, capacity);
}

static HMODULE WINAPI AuthTestLoadLibrary(LPCWSTR path)
{
    wchar_t expected[MAX_PATH + 1];
    UINT length = GetSystemDirectoryW(expected, sizeof(expected) / sizeof(expected[0]));
    ++load_calls;
    check(length > 0 && length + 12 < sizeof(expected) / sizeof(expected[0]),
        "system directory fits absolute path");
    if (length > 0 && length + 12 < sizeof(expected) / sizeof(expected[0])) {
        memcpy(expected + length, L"\\bcrypt.dll", sizeof(L"\\bcrypt.dll"));
        check(wcscmp(path, expected) == 0, "CNG uses exact absolute system path");
    }
    if (mode == TEST_LIBRARY_MISSING) return NULL;
    return LoadLibraryW(path);
}

static LONG WINAPI AuthTestOpen(PVOID *algorithm, LPCWSTR name, LPCWSTR provider,
    ULONG flags)
{
    ++open_calls;
    check(wcscmp(name, L"SHA256") == 0 && provider == NULL && flags == 8,
        "CNG explicitly pins SHA256 and HMAC mode");
    if (mode == TEST_OPEN_FAILURE) return (LONG)0xc0000001;
    if (mode == TEST_OPEN_NULL) { *algorithm = NULL; return 0; }
    if (mode == TEST_OPEN_FAILURE_HANDLE) {
        LONG status = real_open(algorithm, name, provider, flags);
        return status < 0 ? status : (LONG)0xc0000001;
    }
    return real_open(algorithm, name, provider, flags);
}

static LONG WINAPI AuthTestDerive(PVOID algorithm, unsigned char *password,
    ULONG password_length, unsigned char *salt, ULONG salt_length,
    unsigned long long iterations, unsigned char *output, ULONG output_length,
    ULONG flags)
{
    ++derive_calls;
    check(salt_length == 16 && memcmp(salt, th09_side_key_salt, 16) == 0 &&
        iterations == 600000ULL && output_length == 32 && flags == 0,
        "CNG pins public salt, cost, output length and flags");
    if (mode == TEST_DERIVE_FAILURE) {
        memset(output, 0xa5, output_length);
        return (LONG)0xc0000001;
    }
    return real_derive(algorithm, password, password_length, salt, salt_length,
        iterations, output, output_length, flags);
}

static LONG WINAPI AuthTestClose(PVOID algorithm, ULONG flags)
{
    LONG status;
    ++close_calls;
    status = real_close(algorithm, flags);
    if (mode == TEST_CLOSE_FAILURE) return (LONG)0xc0000001;
    return status;
}

static FARPROC WINAPI AuthTestGetProcAddress(HMODULE module, LPCSTR name)
{
    if (strcmp(name, "BCryptOpenAlgorithmProvider") == 0) {
        if (mode == TEST_OPEN_MISSING) return NULL;
        real_open = (Th09CngOpen)GetProcAddress(module, name);
        return real_open ? (FARPROC)AuthTestOpen : NULL;
    }
    if (strcmp(name, "BCryptDeriveKeyPBKDF2") == 0) {
        if (mode == TEST_DERIVE_MISSING) return NULL;
        real_derive = (Th09CngDerive)GetProcAddress(module, name);
        return real_derive ? (FARPROC)AuthTestDerive : NULL;
    }
    if (strcmp(name, "BCryptCloseAlgorithmProvider") == 0) {
        if (mode == TEST_CLOSE_MISSING) return NULL;
        real_close = (Th09CngClose)GetProcAddress(module, name);
        return real_close ? (FARPROC)AuthTestClose : NULL;
    }
    check(FALSE, "only required CNG symbols are requested");
    return NULL;
}

static BOOL WINAPI AuthTestSetEnvironment(LPCWSTR name, LPCWSTR value)
{
    if (mode == TEST_ERASE_FAILURE && value == NULL) return FALSE;
    return SetEnvironmentVariableW(name, value);
}

static int all_zero(const unsigned char *bytes, unsigned int length)
{
    unsigned int i;
    for (i = 0; i < length; ++i) if (bytes[i]) return 0;
    return 1;
}

static void known_answer(const unsigned char *input, unsigned int length,
    const char *hex)
{
    unsigned char actual[32], expected[32];
    unsigned int i, value;
    for (i = 0; i < 32; ++i) {
        value = 0;
        sscanf(hex + i * 2, "%2x", &value);
        expected[i] = (unsigned char)value;
    }
    check(Th09DeriveSideKey(input, length, actual), "real CNG KDF succeeds");
    check(Th09Equal32(actual, expected), "CNG agrees with Python hashlib KAT");
    Th09Wipe(actual, sizeof(actual));
    Th09Wipe(expected, sizeof(expected));
}

static void encoding_and_crypto_tests(void)
{
    static const wchar_t unicode[] = {0x4e2d,0xd83d,0xde42,0,L'Z'};
    static const wchar_t valid_unicode[] = {0x4e2d,0xd83d,0xde42,L'Z'};
    static const unsigned char unicode_utf8[] = {0xe4,0xb8,0xad,0xf0,0x9f,0x99,0x82,0,0x5a};
    static const wchar_t bad[][3] = {{0xd800,0,0},{0xdc00,0,0},
        {0xd800,L'A',0},{0xdc00,0xd800,0}};
    unsigned char bytes[1024], expected[32], different[32];
    wchar_t longest[257];
    unsigned int i;
    int count, before;
    /* Python: hashlib.pbkdf2_hmac('sha256', value, salt, 600000, 32). */
    known_answer((const unsigned char *)"native-kat-3.6.1", 16,
        "6068d825a1fe4e7f3df82a0db1397ce853656be4a3c62fcb9906ce894789a0f6");
    count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, unicode, 5,
        (char *)bytes, sizeof(bytes), NULL, NULL);
    check(count == 9 && memcmp(bytes, unicode_utf8, 9) == 0,
        "UTF16 pair, CJK and embedded NUL encode exactly");
    known_answer(bytes, count,
        "d03514f00bfffd105a014188506c1f345dafecf2f72d660a1a8f979671ac9615");
    memset(bytes, 'A', 256);
    known_answer(bytes, 256,
        "cebaf3070b06d144fe0a01a6f254da99b42fe00e2e5063a13c8a4549e79f3a7d");
    for (i = 0; i < 256; ++i) longest[i] = 0x4e2d;
    longest[256] = 0;
    count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, longest, 256,
        (char *)bytes, sizeof(bytes), NULL, NULL);
    check(count == 768, "256 UTF16 units fit 1024-byte bound");
    known_answer(bytes, count,
        "a9e7f8a35716eb113c1edffd38959ca01fb333d5d9114d4f69e35359f3de4f64");
    before = derive_calls;
    check(!Th09VerifySideKey(NULL, 1), "NULL key denied");
    check(!Th09VerifySideKey(L"", 0), "empty key denied");
    check(!Th09VerifySideKey(longest, 257), "257 UTF16 units denied before read");
    check(!Th09VerifySideKey(L"A", 0xffffffffU), "unsigned oversized length denied");
    for (i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i)
        check(!Th09VerifySideKey(bad[i], i < 2 ? 1 : 2), "malformed UTF16 denied");
    check(derive_calls == before, "invalid inputs do not call KDF");
    check(!Th09VerifySideKey(longest, 256), "valid maximum-length wrong key denied");
    check(derive_calls == before + 1, "valid maximum-length key reaches KDF");
    before = derive_calls;
    check(!Th09VerifySideKey(unicode, 5), "embedded NUL key denied");
    check(derive_calls == before, "embedded NUL denied before KDF");
    check(!Th09VerifySideKey(valid_unicode, 4), "valid Unicode wrong key denied");
    check(derive_calls == before + 1, "valid surrogate pair reaches KDF");
    memcpy(expected, th09_side_key_expected, 32);
    check(Th09Equal32(expected, expected), "equal verifier accepted");
    for (i = 0; i < 32; ++i) {
        memcpy(different, expected, 32);
        different[i] ^= 1;
        check(!Th09Equal32(expected, different), "every verifier byte mismatch denied");
    }
    memset(bytes, 0xa5, sizeof(bytes));
    Th09Wipe(bytes, sizeof(bytes));
    check(all_zero(bytes, sizeof(bytes)), "volatile wipe clears whole buffer");
    Th09Wipe(expected, sizeof(expected));
    Th09Wipe(different, sizeof(different));
    Th09Wipe(longest, sizeof(longest));
}

static void failure_tests(void)
{
    int failure_mode, before, expected_closed;
    unsigned char output[32];
    for (failure_mode = TEST_SYSTEM_MISSING; failure_mode <= TEST_CLOSE_FAILURE;
        ++failure_mode) {
        mode = failure_mode;
        before = close_calls;
        memset(output, 0xa5, sizeof(output));
        check(!Th09DeriveSideKey((const unsigned char *)"synthetic", 9, output),
            "CNG/system/API failure rejects");
        check(all_zero(output, sizeof(output)), "failed derivation wipes output");
        expected_closed = failure_mode == TEST_DERIVE_FAILURE || failure_mode == TEST_CLOSE_FAILURE ||
            failure_mode == TEST_OPEN_FAILURE_HANDLE;
        check(close_calls == before + expected_closed, "provider closed whenever opened");
    }
    mode = TEST_NORMAL;
}

static void environment_tests(void)
{
    wchar_t value[300];
    int before;
    unsigned int i;
    check(SetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, NULL), "test env starts absent");
    before = derive_calls;
    check(Th09AuthorizeSideFromEnvironment(2, TRUE), "2P allowed with no key");
    check(!Th09AuthorizeSideFromEnvironment(1, TRUE), "1P missing key denied");
    check(!Th09AuthorizeSideFromEnvironment(0, TRUE), "invalid side zero denied");
    check(!Th09AuthorizeSideFromEnvironment(3, TRUE), "invalid side three denied");
    check(!Th09AuthorizeSideFromEnvironment(-1, TRUE), "invalid negative side denied");
    check(derive_calls == before, "2P and missing or invalid sides never use KDF");
    for (i = 0; i < 299; ++i) value[i] = L'A';
    value[299] = 0;
    check(SetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, value), "set oversized synthetic key");
    check(!Th09AuthorizeSideFromEnvironment(1, TRUE), "oversized env key denied");
    check(GetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, value, 300) == 0,
        "oversized env key erased on rejection");
    check(derive_calls == before, "oversized env key never uses KDF");
    check(SetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, L"synthetic-wrong"), "set synthetic wrong key");
    check(!Th09AuthorizeSideFromEnvironment(1, FALSE), "wrong env key denied without erasure");
    check(GetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, value, 300) > 0,
        "erase false preserves env for intended inheritance");
    check(!Th09AuthorizeSideFromEnvironment(1, TRUE), "wrong env key denied with erasure");
    check(GetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, value, 300) == 0,
        "wrong env key erased on rejection");
    check(SetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, L"synthetic-wrong"), "set side2 synthetic key");
    before = derive_calls;
    check(Th09AuthorizeSideFromEnvironment(2, TRUE), "2P ignores wrong key");
    check(derive_calls == before, "2P never pays KDF cost");
    check(GetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, value, 300) == 0,
        "2P erases unnecessary key");
    check(SetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, L"synthetic-wrong"), "set erasure fixture");
    mode = TEST_ERASE_FAILURE;
    check(!Th09AuthorizeSideFromEnvironment(2, TRUE), "erasure failure rejects");
    mode = TEST_NORMAL;
    check(SetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, NULL), "remove erasure fixture");
    Th09Wipe(value, sizeof(value));
}

static void private_environment_tests(void)
{
    wchar_t value[258], copy[258];
    DWORD length = GetEnvironmentVariableW(L"TH09_TEST_SIDE_KEY", value, 258);
    int before;
    unsigned int i;
    if (!length) {
        puts("Private key tests skipped (TH09_TEST_SIDE_KEY not set).");
    } else {
        check(length <= 256, "private key input fits bound");
        if (length <= 256) {
            check(Th09VerifySideKey(value, length), "current private key accepted by native KDF");
            memcpy(copy, value, (length + 1) * sizeof(wchar_t));
            copy[0] ^= 1;
            check(!Th09VerifySideKey(copy, length), "changed private key denied");
            memcpy(copy, value, (length + 1) * sizeof(wchar_t));
            copy[length] = L' ';
            check(!Th09VerifySideKey(copy, length + 1), "trailing space never normalized");
            copy[length] = 0;
            check(!Th09VerifySideKey(copy, length + 1), "appended NUL key denied without truncation");
            before = derive_calls;
            for (i = 0; i < length; ++i) {
                memcpy(copy, value, length * sizeof(wchar_t));
                copy[i] = 0;
                check(!Th09VerifySideKey(copy, length), "NUL denied at every key position");
            }
            memcpy(copy, value, length * sizeof(wchar_t));
            copy[length] = 0;
            copy[length + 1] = 0;
            check(!Th09VerifySideKey(copy, length + 2), "repeated trailing NULs denied");
            check(derive_calls == before, "all NUL variants denied before KDF");
            check(SetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, value), "set current private env key");
            check(Th09AuthorizeSideFromEnvironment(1, FALSE), "native env 1P accepts actual current key");
            check(Th09AuthorizeSideFromEnvironment(1, TRUE), "native env 1P accepts and erases");
            check(GetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, copy, 258) == 0,
                "actual current key removed from process env");
            mode = TEST_DERIVE_FAILURE;
            before = derive_calls;
            check(!Th09VerifySideKey(value, length), "actual correct key denied when CNG fails");
            check(derive_calls == before + 1, "correct key failure has no alternate verifier");
            mode = TEST_NORMAL;
        }
    }
    Th09Wipe(value, sizeof(value));
    length = GetEnvironmentVariableW(L"TH09_TEST_RETIRED_SIDE_KEY", value, 258);
    if (!length) {
        puts("Retired key tests skipped (TH09_TEST_RETIRED_SIDE_KEY not set).");
    } else {
        check(length <= 256, "retired key input fits bound");
        if (length <= 256) {
            check(!Th09VerifySideKey(value, length), "actual retired key denied natively");
            check(SetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, value), "set actual retired env key");
            check(!Th09AuthorizeSideFromEnvironment(1, TRUE), "retired env key denied and erased");
            check(GetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, copy, 258) == 0,
                "retired key removed from process env");
        }
    }
    SetEnvironmentVariableW(TH09_SIDE_KEY_ENVIRONMENT, NULL);
    Th09Wipe(value, sizeof(value));
    Th09Wipe(copy, sizeof(copy));
}

int main(void)
{
    encoding_and_crypto_tests();
    failure_tests();
    environment_tests();
    private_environment_tests();
    printf("Native side key auth: %d checks, %d failures; loads=%d open=%d derive=%d close=%d.\n",
        checks, failures, load_calls, open_calls, derive_calls, close_calls);
    return failures ? 1 : 0;
}

/* Isolated native regression for the checked ka_ai_duka 1.7 selectable-side OR-to-MOV
   patch. Reads the original DLL as data; never loads it or accesses a game. */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stddef.h>
#include "../src/native/ai_input_patches.h"

typedef struct {
    unsigned char before[0x2c];
    WORD keys, previous;
    unsigned char gap[2];
    WORD pushed, released;
    unsigned char after[0x8e - 0x36];
} RawKeys;
typedef struct { DWORD vtable, board; RawKeys *keys; } FakeMonitor;
typedef void (__cdecl *ApplyKeys)(FakeMonitor *, unsigned int);
typedef LPWSTR *(WINAPI *ParseWideArguments)(LPCWSTR, int *);

/* Full state/edge tails, verified in the original DLL. 1P has disp8 while
 * 2P uses disp32 because the RawKeys stride is 0x8e. */
static const unsigned char expected_tail_1p[] = {
    0x8b,0x47,0x08,0x66,0x09,0x70,0x2c,
    0x8b,0x57,0x08,0x0f,0xb7,0x4a,0x2c,
    0x0f,0xb7,0x42,0x2e,0x66,0x33,0xc1,
    0x0f,0xb7,0xf0,0x23,0xce,0x66,0x89,0x4a,0x32,
    0x8b,0x4f,0x08,0x0f,0xb7,0x41,0x2c,
    0x66,0xf7,0xd0,0x66,0x23,0xc6,0x66,0x89,0x41,0x34
};
static const unsigned char expected_tail_2p[] = {
    0x8b,0x47,0x08,0x66,0x09,0xb0,0xba,0x00,0x00,0x00,
    0x8b,0x57,0x08,0x0f,0xb7,0x8a,0xba,0x00,0x00,0x00,
    0x0f,0xb7,0x82,0xbc,0x00,0x00,0x00,0x66,0x33,0xc1,
    0x0f,0xb7,0xf0,0x23,0xce,0x66,0x89,0x8a,0xc0,0x00,0x00,0x00,
    0x8b,0x4f,0x08,0x0f,0xb7,0x81,0xba,0x00,0x00,0x00,
    0x66,0xf7,0xd0,0x66,0x23,0xc6,0x66,0x89,0x81,0xc2,0x00,0x00,0x00
};
static const unsigned char prologue[] = {
    0x56,0x57,                    /* preserve esi,edi */
    0x8b,0x7c,0x24,0x0c,        /* edi = monitor */
    0x8b,0x74,0x24,0x10,        /* esi = argument */
    0x81,0xe6,0xf7,0,0,0        /* same 0xf7 mask as upstream wrapper */
};
static const unsigned char epilogue[] = {0x5f,0x5e,0xc3};

static void make_wrapper(unsigned char *dest, const unsigned char *tail, unsigned int length, int side, int patch)
{
    const Th09AiInputPatch *p = &th09_ai_input_patches[side];
    memcpy(dest, prologue, sizeof(prologue));
    memcpy(dest + sizeof(prologue), tail, length);
    if (patch) memcpy(dest + sizeof(prologue) + 3, p->after, p->length);
    memcpy(dest + sizeof(prologue) + length, epilogue, sizeof(epilogue));
}

static int fail(int code, const char *message)
{
    fprintf(stderr, "FAIL %d: %s (Win32 error %lu)\n", code, message, GetLastError());
    return code;
}

int main(void)
{
    HANDLE file;
    HMODULE shell;
    ParseWideArguments parse_arguments;
    LPWSTR *argv;
    int argc = 0;
    unsigned char tails[2][sizeof(expected_tail_2p)];
    const unsigned char *expected_tails[2] = {expected_tail_1p, expected_tail_2p};
    const unsigned int lengths[2] = {sizeof(expected_tail_1p), sizeof(expected_tail_2p)};
    const DWORD offsets[2] = {0x1ce0b, 0x1ceab};
    unsigned char *code;
    DWORD old_protection, bytes_read;
    RawKeys keys[3], before[3];
    FakeMonitor monitor;
    ApplyKeys original, patched;
    int side;
    unsigned int input, previous, trials = 0;

    if (sizeof(void *) != 4 || sizeof(RawKeys) != 0x8e
        || offsetof(RawKeys, keys) != 0x2c || offsetof(FakeMonitor, keys) != 8)
        return fail(1, "test must be compiled for i386 with the expected struct layout");
    /* Wide command line + CreateFileW handle Chinese paths and [] literally.
       Resolve shell32 dynamically because minimal TCC ships no shell32.def. */
    shell = LoadLibraryW(L"shell32.dll");
    if (!shell) return fail(2, "cannot load Windows argument parser");
    parse_arguments = (ParseWideArguments)GetProcAddress(shell, "CommandLineToArgvW");
    if (!parse_arguments) return fail(2, "cannot locate Windows argument parser");
    argv = parse_arguments(GetCommandLineW(), &argc);
    if (!argv || argc != 2) return fail(2, "usage: native_setkeys_test.exe <original inject.dll>");
    file = CreateFileW(argv[1], GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL, NULL);
    LocalFree(argv);
    FreeLibrary(shell);
    if (file == INVALID_HANDLE_VALUE) return fail(3, "cannot open original DLL for reading");
    /* Checked release .text RVA->raw offset is -0xc00 for both tails. */
    for (side = 0; side < 2; ++side) {
        const Th09AiInputPatch *p = &th09_ai_input_patches[side];
        if (p->rva != offsets[side] + 0xc00 + 3
            || SetFilePointer(file, offsets[side], NULL, FILE_BEGIN) == INVALID_SET_FILE_POINTER
            || !ReadFile(file, tails[side], lengths[side], &bytes_read, NULL)
            || bytes_read != lengths[side]) {
            CloseHandle(file);
            return fail(4, "cannot read instruction tail or incorrect patch RVA");
        }
        if (memcmp(tails[side], expected_tails[side], lengths[side])
            || memcmp(tails[side] + 3, p->before, p->length)) {
            CloseHandle(file);
            return fail(5, "original DLL instructions do not match expected version");
        }
    }
    CloseHandle(file);
    code = (unsigned char *)VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!code) return fail(6, "cannot allocate isolated test code");
    /* Two selected-side configurations; human side stays original in each. */
    make_wrapper(code, tails[0], lengths[0], 0, 1);
    make_wrapper(code + 256, tails[1], lengths[1], 1, 0);
    make_wrapper(code + 512, tails[0], lengths[0], 0, 0);
    make_wrapper(code + 768, tails[1], lengths[1], 1, 1);
    if (!VirtualProtect(code, 4096, PAGE_EXECUTE_READ, &old_protection))
        return fail(7, "cannot enable isolated test execution");
    if (!FlushInstructionCache(GetCurrentProcess(), code, 4096))
        return fail(7, "cannot flush test instruction cache");
    memset(&monitor, 0, sizeof(monitor));
    monitor.keys = keys;

    for (side = 0; side < 2; ++side) {
    patched = (ApplyKeys)(code + side * 768);
    original = (ApplyKeys)(code + 256 + side * 256);
    memset(keys, 0, sizeof(keys));
    keys[1 - side].keys = 3; /* human-side physical Z+X already present */
    original(&monitor, 0);
    if (keys[1 - side].keys != 3) return fail(8, "human-side original OR behavior was not preserved");
    for (input = 0; input < 256; ++input) {
        for (previous = 0; previous < 256; ++previous) {
            WORD desired = (WORD)(input & 0xf5); /* actual AI disallows X */
            WORD delta = (WORD)(desired ^ previous);
            memset(keys, 0xa5, sizeof(keys));
            keys[side].keys = 0xffff; /* all physical/game inputs contaminate state */
            keys[side].previous = (WORD)previous;
            memcpy(before, keys, sizeof(keys));
            patched(&monitor, desired | 0x8000); /* unsupported flag gets masked */
            if (keys[side].keys != desired || keys[side].pushed != (WORD)(delta & desired)
                || keys[side].released != (WORD)(delta & ~desired)
                || keys[side].previous != previous || (keys[side].keys & 2))
                return fail(9, "AI-side state or pressed/released edges changed incorrectly");
            if (memcmp(&keys[1 - side], &before[1 - side], sizeof(RawKeys))
                || memcmp(&keys[2], &before[2], sizeof(RawKeys)))
                return fail(10, "human-side or P3 input was modified");
            before[side].keys = keys[side].keys;
            before[side].pushed = keys[side].pushed;
            before[side].released = keys[side].released;
            if (memcmp(keys, before, sizeof(keys)))
                return fail(11, "unrelated key-state fields were modified");
            ++trials;
        }
    }
    }
    VirtualFree(code, 0, MEM_RELEASE);
    printf("PASS: %u dirty-input cases; exact selected P1/P2 keys and press/release edges; no X; human/P3 unchanged; human-side OR preserved.\n", trials);
    return 0;
}

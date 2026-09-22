#ifndef TH09_AI_SIDE_CONFIG_H
#define TH09_AI_SIDE_CONFIG_H
#include <windows.h>
#include <wchar.h>

/* The bundled minimal TinyCC Windows SDK omits the NLS declarations. */
#ifndef CP_ACP
#define CP_ACP 0
#define CP_UTF8 65001
#define WC_ERR_INVALID_CHARS 0x00000080
#define WC_NO_BEST_FIT_CHARS 0x00000400
__declspec(dllimport) UINT WINAPI GetACP(void);
__declspec(dllimport) int WINAPI WideCharToMultiByte(UINT, DWORD, LPCWSTR, int,
    LPSTR, int, LPCSTR, LPBOOL);
#endif

/* The upstream reader accepts only the exact lowercase string "true".
 * Reject anything except canonical booleans rather than disagree with it.
 * Return the single enabled AI side (1/2), or zero for an invalid INI.
 * The disabled side must have no script so a generated file is unambiguous. */
static int Th09ReadAiSide(const wchar_t *ini)
{
    int i, path_bytes, enabled[2];
    const wchar_t *sections[2] = {L"1P", L"2P"};
    wchar_t value[256];
    DWORD length;
    BOOL used_default;
    for (i = 0; i < 2; ++i) {
        length = GetPrivateProfileStringW(sections[i], L"enabled", L"",
            value, sizeof(value) / sizeof(value[0]), ini);
        if (!length || length >= 255) return 0;
        if (wcscmp(value, L"true") == 0) enabled[i] = 1;
        else if (wcscmp(value, L"false") == 0) enabled[i] = 0;
        else return 0;
        length = GetPrivateProfileStringW(sections[i], L"script_path", L"",
            value, sizeof(value) / sizeof(value[0]), ini);
        if (length >= 255 || (length != 0) != enabled[i]) return 0;
        /* Upstream uses GetPrivateProfileStringA with char[255] and rejects
         * return >=254. Match its 253-byte limit, not only wchar_t length.
         * Refuse lossy ACP fallback so native/upstream see the same path. */
        used_default = FALSE;
        path_bytes = WideCharToMultiByte(CP_ACP,
            GetACP() == CP_UTF8 ? WC_ERR_INVALID_CHARS : WC_NO_BEST_FIT_CHARS,
            value, -1, NULL, 0, NULL, GetACP() == CP_UTF8 ? NULL : &used_default);
        if (!path_bytes || path_bytes > 254 || used_default) return 0;
    }
    if (enabled[0] == enabled[1]) return 0;
    return enabled[0] ? 1 : 2;
}
#endif

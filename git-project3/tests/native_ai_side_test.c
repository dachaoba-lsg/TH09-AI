/* Configuration contract with the upstream ANSI INI reader; no game used. */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include "../src/native/ai_side_config.h"

static wchar_t ini[MAX_PATH];
static int checks;

static int expect(int expected, const char *name)
{
    int actual = Th09ReadAiSide(ini);
    ++checks;
    if (actual == expected) return 1;
    fprintf(stderr, "FAIL: %s: side=%d expected=%d\n", name, actual, expected);
    return 0;
}

static int reset(int side)
{
    HANDLE file;
    WORD bom = 0xfeff;
    DWORD written;
    WritePrivateProfileStringW(NULL, NULL, NULL, ini);
    file = CreateFileW(ini, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    if (!WriteFile(file, &bom, sizeof(bom), &written, NULL) || written != sizeof(bom)) {
        CloseHandle(file); return 0;
    }
    CloseHandle(file);
    return WritePrivateProfileStringW(L"1P", L"enabled", side == 1 ? L"true" : L"false", ini)
        && WritePrivateProfileStringW(L"2P", L"enabled", side == 2 ? L"true" : L"false", ini)
        && WritePrivateProfileStringW(L"1P", L"script_path", side == 1 ? L"main.lua" : L"", ini)
        && WritePrivateProfileStringW(L"2P", L"script_path", side == 2 ? L"main.lua" : L"", ini);
}

int main(void)
{
    wchar_t *slash, path[256];
    wchar_t chinese[2] = {0x4e2d, 0};
    char upstream[255], ini_ansi[MAX_PATH * 3];
    BOOL used_default = FALSE;
    int side, i, bytes, at;
    const wchar_t *section;
    if (!GetModuleFileNameW(NULL, ini, MAX_PATH)) return 1;
    slash = wcsrchr(ini, L'\\');
    if (!slash || slash - ini > MAX_PATH - 30) return 1;
    wcscpy(slash + 1, L"native-ai-side-test.ini");
    if (!WideCharToMultiByte(CP_ACP, 0, ini, -1, ini_ansi, sizeof(ini_ansi), NULL, NULL)) return 1;
    for (side = 1; side <= 2; ++side) {
        section = side == 1 ? L"1P" : L"2P";
        if (!reset(side) || !expect(side, "canonical selection")) return 1;
        for (i = 0; i < 253; ++i) path[i] = L'a';
        path[253] = 0;
        WritePrivateProfileStringW(section, L"script_path", path, ini);
        if (!expect(side, "253 ASCII bytes accepted")) return 1;
        if (GetPrivateProfileStringA(side == 1 ? "1P" : "2P", "script_path", "", upstream,
            sizeof(upstream), ini_ansi) != 253) return 1;
        path[253] = L'a'; path[254] = 0;
        WritePrivateProfileStringW(section, L"script_path", path, ini);
        if (!expect(0, "254 ASCII bytes rejected")) return 1;
        bytes = WideCharToMultiByte(CP_ACP,
            GetACP() == CP_UTF8 ? WC_ERR_INVALID_CHARS : WC_NO_BEST_FIT_CHARS,
            chinese, 1, NULL, 0, NULL, GetACP() == CP_UTF8 ? NULL : &used_default);
        if (bytes > 0 && !used_default) {
            at = 0;
            for (i = 0; i < 253 / bytes; ++i) path[at++] = chinese[0];
            for (i = 0; i < 253 % bytes; ++i) path[at++] = L'a';
            path[at] = 0;
            WritePrivateProfileStringW(section, L"script_path", path, ini);
            if (!expect(side, "253 mixed Chinese ACP bytes accepted")) return 1;
            if (GetPrivateProfileStringA(side == 1 ? "1P" : "2P", "script_path", "", upstream,
                sizeof(upstream), ini_ansi) != 253) return 1;
            path[at++] = L'a'; path[at] = 0;
            WritePrivateProfileStringW(section, L"script_path", path, ini);
            if (!expect(0, "254 mixed Chinese ACP bytes rejected")) return 1;
        } else {
            WritePrivateProfileStringW(section, L"script_path", chinese, ini);
            if (!expect(0, "unrepresentable Chinese path rejected")) return 1;
        }
    }
    if (!reset(0) || !expect(0, "both disabled")) return 1;
    if (!reset(1)) return 1;
    WritePrivateProfileStringW(L"2P", L"enabled", L"true", ini);
    WritePrivateProfileStringW(L"2P", L"script_path", L"main.lua", ini);
    if (!expect(0, "both enabled")) return 1;
    if (!reset(2)) return 1;
    WritePrivateProfileStringW(L"2P", L"enabled", L"TRUE", ini);
    if (!expect(0, "uppercase boolean disagrees with upstream")) return 1;
    WritePrivateProfileStringW(L"2P", L"enabled", L"1", ini);
    if (!expect(0, "numeric boolean disagrees with upstream")) return 1;
    WritePrivateProfileStringW(L"2P", L"enabled", NULL, ini);
    if (!expect(0, "missing enabled")) return 1;
    if (!reset(2)) return 1;
    WritePrivateProfileStringW(L"2P", L"script_path", L"", ini);
    if (!expect(0, "enabled without script")) return 1;
    if (!reset(2)) return 1;
    WritePrivateProfileStringW(L"1P", L"script_path", L"main.lua", ini);
    if (!expect(0, "disabled with script")) return 1;
    if (!reset(2)) return 1;
    WritePrivateProfileStringW(L"2P", L"script_path", L"\xD83D\xDE00.lua", ini);
    /* UTF-8 represents this surrogate pair; legacy ACPs normally cannot. */
    used_default = FALSE;
    bytes = WideCharToMultiByte(CP_ACP,
        GetACP() == CP_UTF8 ? WC_ERR_INVALID_CHARS : WC_NO_BEST_FIT_CHARS,
        L"\xD83D\xDE00.lua", -1, NULL, 0, NULL, GetACP() == CP_UTF8 ? NULL : &used_default);
    if (!expect(bytes > 0 && !used_default ? 2 : 0, "ACP fallback cannot silently change script path")) return 1;
    printf("PASS: %d native AI-side/ACP boundary checks; ACP=%u; no game process used.\n", checks, GetACP());
    return 0;
}

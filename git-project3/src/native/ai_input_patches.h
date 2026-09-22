#ifndef TH09_AI_SIDE_INPUT_PATCHES_H
#define TH09_AI_SIDE_INPUT_PATCHES_H
#include <windows.h>

/* Checked against the original v1.7 inject.dll, SHA256
 * 2BA67F1F80EBE53F978DC6843777764B5EAD911A688C89C9CD68CC8C2D9CAE00.
 * Lua_SendKey1P/2P have distinct encodings for raw[0/1].keys.
 * Change only the selected side's OR to MOV. Edge calculations remain intact.
 * These are AI injection patches, not physical-key mappings. */
typedef struct Th09AiInputPatch {
    DWORD rva;
    unsigned int length;
    unsigned char before[7], after[7];
} Th09AiInputPatch;
static const Th09AiInputPatch th09_ai_input_patches[2] = {
    {0x1DA0E, 4, {0x66,0x09,0x70,0x2C}, {0x66,0x89,0x70,0x2C}},
    {0x1DAAE, 7, {0x66,0x09,0xB0,0xBA,0,0,0}, {0x66,0x89,0xB0,0xBA,0,0,0}}
};
#endif

/* Player-1-only practice gates for original Japanese TH09 v1.50a.
 * Reference: official THprac thprac/src/thprac/thprac_th09.cpp lines 249-260:
 * https://github.com/touhouworldcup/thprac/blob/master/thprac/src/thprac/thprac_th09.cpp
 * THprac invinc skips the hurt call at 41E8EC; its infhealth skips 41E5F9
 * to 41E63C only on HP>1. Our no_damage also protects the HP=1 death branch.
 * Our invincible additionally uses the original combo settlement/reset routine
 * 41D7E0, matching the requested contact-breaks-combo behavior (the original
 * THprac skip alone does not invoke that routine). Neither gate runs for 2P.
 */
#include "practice_patches.h"
#include <stdio.h>
#include <string.h>

static Th09PracticeStats practice_stats;
static Th09PracticeLogFn practice_log;
static LONG practice_installed;

static void emit8(Th09PracticePlan *p, unsigned char value) {
    p->code[p->code_length++] = value;
}
static void emit32(Th09PracticePlan *p, uint32_t value) {
    memcpy(p->code + p->code_length, &value, 4);
    p->code_length += 4;
}
static void relative(Th09PracticePlan *p, unsigned char opcode, uint32_t target) {
    uint32_t displacement = target - (p->code_address + p->code_length + 5);
    emit8(p, opcode); emit32(p, displacement);
}
static void record_call(Th09PracticePlan *p, unsigned char mode, uint32_t recorder) {
    emit8(p, 0x56); /* push esi: player */
    emit8(p, 0x6A); emit8(p, mode); /* push mode */
    relative(p, 0xE8, recorder);
    emit8(p, 0x83); emit8(p, 0xC4); emit8(p, 8); /* caller removes arguments */
}
static void side_compare(Th09PracticePlan *p) {
    emit8(p, 0x83); emit8(p, 0x7E); emit8(p, 8); emit8(p, 0); /* cmp [esi+8],0 */
}
static Th09PracticePatch *start_patch(Th09PracticePlan *p, uint32_t address,
                                     const unsigned char *before, unsigned int length) {
    Th09PracticePatch *patch = &p->patches[p->patch_count++];
    uint32_t displacement = p->code_address + p->code_length - (address + 5);
    patch->address = address; patch->length = length;
    memcpy(patch->before, before, length);
    memset(patch->after, 0x90, length);
    patch->after[0] = 0xE9;
    memcpy(patch->after + 1, &displacement, 4);
    return patch;
}

BOOL Th09PracticeBuildPlan(BOOL no_damage, BOOL invincible, uint32_t code_address,
                          uint32_t recorder_address, Th09PracticePlan *plan) {
    unsigned int branch_byte;
    static const unsigned char health_load[6] = {0x8B,0x86,0xA8,0,0,0};
    static const unsigned char hurt_call[5] = {0xE8,0x2F,0xFB,0xFF,0xFF};
    if (!plan || (!code_address && (no_damage || invincible)) || !recorder_address) return FALSE;
    memset(plan, 0, sizeof(*plan)); plan->code_address = code_address;
    if (no_damage) {
        start_patch(plan, 0x41E46A, health_load, sizeof(health_load));
        memcpy(plan->code + plan->code_length, health_load, sizeof(health_load));
        plan->code_length += sizeof(health_load); /* displaced mov eax,[esi+A8] */
        emit8(plan, 0x9C); /* pushfd */
        side_compare(plan);
        emit8(plan, 0x75); branch_byte = plan->code_length; emit8(plan, 0);
        emit8(plan, 0x60); /* pushad */
        record_call(plan, 1, recorder_address);
        emit8(plan, 0x61); emit8(plan, 0x9D); /* popad; popfd */
        relative(plan, 0xE9, 0x41E63C); /* original hurt reaction, without HP loss/death */
        plan->code[branch_byte] = (unsigned char)(plan->code_length - branch_byte - 1);
        emit8(plan, 0x9D); /* other side: restore flags, original remaining code */
        relative(plan, 0xE9, 0x41E470);
    }
    if (invincible) {
        while (plan->code_length % 16) emit8(plan, 0x90);
        start_patch(plan, 0x41E8EC, hurt_call, sizeof(hurt_call));
        emit8(plan, 0x9C); side_compare(plan);
        emit8(plan, 0x75); branch_byte = plan->code_length; emit8(plan, 0);
        emit8(plan, 0x60);
        record_call(plan, 2, recorder_address);
        emit8(plan, 0x8D); emit8(plan, 0x8E); emit32(plan, 0x30410); /* original combo object */
        relative(plan, 0xE8, 0x41D7E0); /* normal settlement/reset; no hurt state */
        emit8(plan, 0x61); emit8(plan, 0x9D);
        relative(plan, 0xE9, 0x41E8F1);
        plan->code[branch_byte] = (unsigned char)(plan->code_length - branch_byte - 1);
        emit8(plan, 0x9D);
        relative(plan, 0xE8, 0x41E420); /* 2P retains the original hurt call */
        relative(plan, 0xE9, 0x41E8F1);
    }
    return TRUE;
}

static void __cdecl record_contact(unsigned int mode, unsigned char *player) {
    char message[192]; unsigned long count;
    if (*(unsigned long *)(player + 8) != 0) return;
    practice_stats.last_hp = *(unsigned long *)(player + 0xA8);
    practice_stats.last_side = *(unsigned long *)(player + 8);
    practice_stats.last_mode = mode;
    if (mode == 1) count = ++practice_stats.no_damage_contacts;
    else count = ++practice_stats.invincible_contacts;
    /* A few useful diagnostic samples without per-contact disk I/O. */
    if (practice_log && (count <= 3 || (count & (count - 1)) == 0)) {
        _snprintf(message, sizeof(message) - 1,
                  "practice: mode=%s side=%lu hp=%lu contacts=%lu",
                  mode == 1 ? "no_damage" : "invincible", practice_stats.last_side,
                  practice_stats.last_hp, count);
        message[sizeof(message) - 1] = 0;
        practice_log(message);
    }
}

void Th09PracticeGetStats(Th09PracticeStats *stats) {
    if (stats) *stats = practice_stats;
}

BOOL Th09PracticeInstall(BOOL no_damage, BOOL invincible, Th09PracticeLogFn logfn) {
    Th09PracticePlan plan; void *code; DWORD previous, unused;
    unsigned int i; BOOL success = FALSE;
    if (InterlockedCompareExchange(&practice_installed, 1, 0) != 0) return FALSE;
    practice_log = logfn;
    memset(&practice_stats, 0, sizeof(practice_stats));
    if (!no_damage && !invincible) {
        if (practice_log) practice_log("practice: both player-1 options disabled");
        return TRUE;
    }
    code = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!code) goto finish;
    if (!Th09PracticeBuildPlan(no_damage, invincible, (uint32_t)(uintptr_t)code,
                             (uint32_t)(uintptr_t)record_contact, &plan)) goto finish;
    /* Validate every enabled instruction before writing any game code. */
    for (i = 0; i < plan.patch_count; ++i) {
        if (memcmp((void *)(uintptr_t)plan.patches[i].address,
                   plan.patches[i].before, plan.patches[i].length) != 0) goto finish;
    }
    memcpy(code, plan.code, plan.code_length);
    if (!VirtualProtect(code, 4096, PAGE_EXECUTE_READ, &previous)) goto finish;
    if (!FlushInstructionCache(GetCurrentProcess(), code, plan.code_length)) goto finish;
    for (i = 0; i < plan.patch_count; ++i) {
        Th09PracticePatch *p = &plan.patches[i];
        void *target = (void *)(uintptr_t)p->address;
        if (!VirtualProtect(target, p->length, PAGE_EXECUTE_READWRITE, &previous)) goto finish;
        memcpy(target, p->after, p->length);
        if (!FlushInstructionCache(GetCurrentProcess(), target, p->length)) goto finish;
        if (!VirtualProtect(target, p->length, previous, &unused)) goto finish;
        if (memcmp(target, p->after, p->length) != 0) goto finish;
    }
    success = TRUE;
finish:
    /* Keep the code allocation even on failure: a partially installed gate
       must not reference freed memory. The caller must stop an unsafe launch. */
    if (practice_log) {
        char message[192];
        _snprintf(message, sizeof(message) - 1,
                  "practice: install=%s player=1 no_damage=%d invincible=%d precedence=invincible",
                  success ? "ok" : "FAILED", !!no_damage, !!invincible);
        message[sizeof(message) - 1] = 0; practice_log(message);
    }
    return success;
}

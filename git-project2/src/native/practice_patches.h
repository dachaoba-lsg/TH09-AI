#ifndef TH09_AI_PRACTICE_PATCHES_H
#define TH09_AI_PRACTICE_PATCHES_H
#include <windows.h>
#include <stdint.h>

typedef void (*Th09PracticeLogFn)(const char *message);
typedef struct Th09PracticeStats {
    unsigned long no_damage_contacts;
    unsigned long invincible_contacts;
    unsigned long last_hp;
    unsigned long last_side;
    unsigned long last_mode; /* 1=no_damage, 2=invincible */
} Th09PracticeStats;

/* Call once before gameplay, including when the window feature is disabled.
 * Only the known Japanese 1.50a image is supported. Failure must be reported;
 * do not continue a game after partial installation. Game files are untouched.
 * If both options are true, invincible takes precedence on collision.
 */
BOOL Th09PracticeInstall(BOOL no_damage, BOOL invincible, Th09PracticeLogFn logfn);
void Th09PracticeGetStats(Th09PracticeStats *stats);

/* Pure code-generation interface used by the offline machine-code tests. */
typedef struct Th09PracticePatch {
    uint32_t address;
    unsigned int length;
    unsigned char before[6];
    unsigned char after[6];
} Th09PracticePatch;
typedef struct Th09PracticePlan {
    Th09PracticePatch patches[2];
    unsigned int patch_count;
    uint32_t code_address;
    unsigned int code_length;
    unsigned char code[160];
} Th09PracticePlan;
BOOL Th09PracticeBuildPlan(BOOL no_damage, BOOL invincible, uint32_t code_address,
                          uint32_t recorder_address, Th09PracticePlan *plan);
#endif

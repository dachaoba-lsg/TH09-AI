#ifndef TH09_PLAYER_SENSOR_H
#define TH09_PLAYER_SENSOR_H
#include <windows.h>
#include <stdint.h>
#include <stddef.h>

#define TH09_PLAYER_SENSOR_API 1
#define TH09_PLAYER_SENSOR_MAX_CLOUDS 256
#define TH09_PLAYER_FIELDS_RVA 0x1E100u
#define TH09_PLAYER_FIELDS_SIZE 0x521u

typedef void (*Th09PlayerSensorLogFn)(const char *message);
typedef BOOL (*Th09PlayerSensorReadFn)(uint32_t address, void *out, size_t size, void *context);
typedef struct {
    float x,y,age,frames_left;
    int age_int,active;
} Th09PoisonCloud;
typedef struct {
    int valid,state,can_charge,cut_in,movement_enabled,cloud_count;
    float base_x,base_y,move_x,move_y,protection,charge_block,charge_warmup,time_scale;
    Th09PoisonCloud clouds[TH09_PLAYER_SENSOR_MAX_CLOUDS];
} Th09PlayerSnapshot;
typedef struct {
    unsigned char code[160],patch[5];
    size_t code_length;
    uint32_t patch_address,gateway_address,bridge_address;
} Th09PlayerSensorPlan;

/* Read-only snapshot. Timer values are game timer units, NOT wall seconds.
 * protection is raw state-3 remaining time; callers must allow for the next
 * pre-movement decrement (do not count its last unit as safe). State 4 is not
 * represented as a C protection duration. charge_block excludes Z warm-up. */
BOOL Th09PlayerSensorCollect(uint32_t raw_player, Th09PlayerSensorReadFn reader,
                            void *context, Th09PlayerSnapshot *out);
BOOL Th09PlayerSensorBuildPlan(uint32_t module_base,uint32_t code_address,
                              uint32_t helper_address,Th09PlayerSensorPlan *out);
BOOL Th09PlayerSensorInstall(Th09PlayerSensorLogFn logfn);

/* Exposed to the offline selftest only; this writes Lua-owned tables, never
 * game memory. APIs are the statically linked Lua 5.1 C ABI in verified DLL. */
typedef struct {
    void (__cdecl *push_string)(void *,const char *);
    void (__cdecl *push_number)(void *,double);
    void (__cdecl *push_boolean)(void *,int);
    void (__cdecl *create_table)(void *,int,int);
    void (__cdecl *set_table)(void *,int);
} Th09PlayerSensorLuaApi;
void Th09PlayerSensorWriteTable(void *ls,const Th09PlayerSensorLuaApi *api,
                                const Th09PlayerSnapshot *snapshot);
#endif

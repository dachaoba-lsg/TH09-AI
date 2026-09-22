#ifndef TH09_PLAYER_SENSOR_H
#define TH09_PLAYER_SENSOR_H
#include <windows.h>
#include <stdint.h>
#include <stddef.h>

#define TH09_PLAYER_SENSOR_API 1
#define TH09_PLAYER_FOLLOWUP_API 1
#define TH09_PLAYER_SENSOR_MAX_CLOUDS 256
#define TH09_PLAYER_SENSOR_MAX_WAVES 512
#define TH09_PLAYER_SENSOR_MAX_C1_SHOTS 128
#define TH09_PLAYER_FIELDS_RVA 0x1E100u
#define TH09_PLAYER_FIELDS_SIZE 0x521u
#define TH09_ENEMY_FIELDS_RVA 0x1E630u
#define TH09_ENEMY_FIELDS_SIZE 0x44Eu

typedef void (*Th09PlayerSensorLogFn)(const char *message);
typedef BOOL (*Th09PlayerSensorReadFn)(uint32_t address, void *out, size_t size, void *context);
typedef struct {
    float x,y,age,frames_left;
    int age_int,active;
} Th09PoisonCloud;
typedef struct {
    int slot_id,type,life,delay,enabled,listed;
    float x,y,radius,growth;
} Th09CommonWave;
typedef struct {
    int spawn_tick,damage,type,supported,piercing,motion_model;
    float offset_x,offset_y,width,height,angle,speed;
    uint32_t template_address;
} Th09C1Shot;
typedef struct {
    int slot_id,type,damage,supported,piercing,damage_ready,motion_model,age_int;
    float x,y,width,height,vx,vy,age,speed;
} Th09C1ActiveShot;
typedef struct {
    int valid,state,can_charge,cut_in,movement_enabled,cloud_count;
    int can_press_z,c1_action_active,waves_valid,wave_count;
    int c1_valid,c1_limited,c1_count,c1_active_valid,c1_active_count;
    float base_x,base_y,move_x,move_y,protection,charge_block,charge_warmup,time_scale;
    float c1_action_age,c1_action_duration;
    int c1_homing_valid,c1_homing_state_valid;
    float c1_homing_x,c1_homing_y;
    Th09PoisonCloud clouds[TH09_PLAYER_SENSOR_MAX_CLOUDS];
    Th09CommonWave waves[TH09_PLAYER_SENSOR_MAX_WAVES];
    Th09C1Shot c1_shots[TH09_PLAYER_SENSOR_MAX_C1_SHOTS];
    Th09C1ActiveShot c1_active[TH09_PLAYER_SENSOR_MAX_C1_SHOTS];
} Th09PlayerSnapshot;

typedef struct {
    int valid,health,shot_damageable,shot_collision_enabled,shot_damage_divisor,damage_model_limited;
    float hit_x,hit_y,hit_width,hit_height;
} Th09EnemySnapshot;
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
BOOL Th09EnemySensorCollect(uint32_t raw_enemy,Th09PlayerSensorReadFn reader,
                           void *context,Th09EnemySnapshot *out);
BOOL Th09EnemySensorBuildPlan(uint32_t module_base,uint32_t code_address,
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
void Th09EnemySensorWriteTable(void *ls,const Th09PlayerSensorLuaApi *api,
                               const Th09EnemySnapshot *snapshot);
#endif

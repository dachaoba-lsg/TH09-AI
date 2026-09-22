#ifndef TH09_ENEMY_SENSOR_H
#define TH09_ENEMY_SENSOR_H
#include "player_sensor.h"
#define TH09_ENEMY_COMBAT_API 1
#define TH09_ENEMY_FIELDS_RVA 0x1E630u
#define TH09_ENEMY_FIELDS_SIZE 0x44Eu
typedef struct {
    int valid,side,slot_index,hp,protection_ticks;
    int blocks_shots,secondary_blocks_shots,damageable,shot_damage_divisor,shot_can_ignite;
    uint32_t id,flags,flags2;
    float x,y,width,height,secondary_width,secondary_height;
} Th09EnemySnapshot;
typedef Th09PlayerSensorPlan Th09EnemySensorPlan;
BOOL Th09EnemySensorCollect(uint32_t managed_enemy,Th09PlayerSensorReadFn reader,
    void *context,Th09EnemySnapshot *out);
void Th09EnemySensorWriteTable(void *ls,const Th09PlayerSensorLuaApi *api,
    const Th09EnemySnapshot *snapshot);
BOOL Th09EnemySensorBuildPlan(uint32_t module_base,uint32_t code_address,
    uint32_t helper_address,Th09EnemySensorPlan *out);
BOOL Th09EnemySensorInstall(Th09PlayerSensorLogFn logfn);
#endif

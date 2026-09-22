#ifndef TH09_AI_LASER_SENSOR_H
#define TH09_AI_LASER_SENSOR_H
#include <windows.h>
#include <stdint.h>

typedef void (*Th09LaserSensorLogFn)(const char *message);

/* Install once, only while the launcher-owned game's main thread is suspended.
 * The original inject.dll must already be loaded and verified by the launcher.
 * Failure must fail the support-ready handshake; do not resume a partial patch.
 * Only managed sensor geometry changes, never raw game state or collision data.
 */
BOOL Th09LaserSensorInstall(Th09LaserSensorLogFn logfn);

#define TH09_LASER_UPDATE_RVA 0x20510u
#define TH09_LASER_UPDATE_SIZE 0x4Au
#define TH09_LASER_VTABLE_RVA 0x61C74u
#define TH09_LASER_HALF_RVA 0x62BBCu
#define TH09_LASER_PATCH_SIZE 7u

/* Pure interfaces for tests and documentation of the exported geometry.
 * body.x/y are the start of the currently occupied segment, not its emitter.
 * body.width remains length2-length1, body.height remains raw thickness / 2.
 * Bullet.x/y and Bullet.vx/vy retain the upstream contract (emitter and zero).
 */
BOOL Th09LaserSensorProject(float origin_x, float origin_y, float length1,
                           float angle, float *start_x, float *start_y);
void __cdecl Th09LaserSensorCorrectManaged(void *managed_laser);

typedef struct Th09LaserSensorPlan {
    uint32_t patch_address;
    uint32_t gateway_address;
    uint32_t bridge_address;
    unsigned int code_length;
    unsigned char expected[TH09_LASER_UPDATE_SIZE];
    unsigned char patch[TH09_LASER_PATCH_SIZE];
    unsigned char code[128];
} Th09LaserSensorPlan;

BOOL Th09LaserSensorBuildPlan(uint32_t module_base, uint32_t code_address,
                             uint32_t helper_address, Th09LaserSensorPlan *plan);
#endif

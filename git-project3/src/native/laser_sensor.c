/* Correct only ka_ai_duka v1.7's managed Laser::Update sensor output.
 * Original game evidence (Japanese TH09 1.50a): 414B6E..414BC1 advances
 * length2 and length1; 414BF1..414C11 forms the collision rectangle center
 * at emitter.x + length1 + (length2-length1)/2. 414DC2..414DEC registers
 * that rectangle with emitter as rotation pivot and raw angle. The true
 * segment start is therefore emitter + length1 * (cos(angle), sin(angle)).
 * Upstream Bullet.cpp omits length1. Its thickness / 2 convention is correct:
 * the game halves raw thickness at 414BD7 and again at 4128D9 for half-width.
 */
#define WIN32_LEAN_AND_MEAN
#include "laser_sensor.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static LONG sensor_install_attempted;

static BOOL finite_float(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return (bits & 0x7F800000u) != 0x7F800000u;
}

BOOL Th09LaserSensorProject(float origin_x, float origin_y, float length1,
                           float angle, float *start_x, float *start_y) {
    float x, y;
    if (!start_x || !start_y || !finite_float(origin_x) || !finite_float(origin_y) ||
        !finite_float(length1) || !finite_float(angle)) return FALSE;
    /* Most growing beams have length1 == 0; avoid unnecessary trig work and
     * preserve their upstream origin exactly, including signed zero. */
    if (length1 == 0.0f) { x = origin_x; y = origin_y; }
    else {
        x = (float)((double)origin_x + (double)length1 * cos((double)angle));
        y = (float)((double)origin_y + (double)length1 * sin((double)angle));
    }
    if (!finite_float(x) || !finite_float(y)) return FALSE;
    *start_x = x; *start_y = y;
    return TRUE;
}

static float read_float(const unsigned char *address) {
    float result; memcpy(&result, address, sizeof(result)); return result;
}

void __cdecl Th09LaserSensorCorrectManaged(void *managed_laser) {
    unsigned char *object = (unsigned char *)managed_laser;
    unsigned char *raw, *body, *position;
    float x, y;
    if (!object || sizeof(void *) != 4) return;
    /* Checked original Update: +8 is Bullet::position&, +C raw Laser&,
     * +10 shared_ptr's managed HittableRotatableRect*. The original routine
     * has already dereferenced these pointers successfully before this call. */
    memcpy(&position, object + 8, sizeof(position));
    memcpy(&raw, object + 0x0C, sizeof(raw));
    memcpy(&body, object + 0x10, sizeof(body));
    if (!raw || !body || position != raw + 0x548) return;
    if (!Th09LaserSensorProject(read_float(raw + 0x548), read_float(raw + 0x54C),
            read_float(raw + 0x558), read_float(raw + 0x554), &x, &y)) return;
    /* These are upstream-allocated C++ sensor fields, not game physics. */
    memcpy(body + 4, &x, sizeof(x));
    memcpy(body + 8, &y, sizeof(y));
}

static void emit8(Th09LaserSensorPlan *plan, unsigned char value) {
    plan->code[plan->code_length++] = value;
}
static void emit32(Th09LaserSensorPlan *plan, uint32_t value) {
    memcpy(plan->code + plan->code_length, &value, 4); plan->code_length += 4;
}
static void emit_relative(Th09LaserSensorPlan *plan, unsigned char opcode,
                          uint32_t code_address, uint32_t target) {
    emit8(plan, opcode);
    emit32(plan, target - (code_address + plan->code_length + 4));
}

BOOL Th09LaserSensorBuildPlan(uint32_t module_base, uint32_t code_address,
                             uint32_t helper_address, Th09LaserSensorPlan *plan) {
    static const unsigned char original[TH09_LASER_UPDATE_SIZE] = {
        0x8B,0x51,0x08,0x56,0x8B,0x71,0x10,0x8B,0x02,0x89,0x46,0x04,
        0x8B,0x42,0x04,0x89,0x46,0x08,0x8B,0x41,0x0C,0xF3,0x0F,0x10,
        0x80,0x5C,0x05,0x00,0x00,0xF3,0x0F,0x5C,0x80,0x58,0x05,0x00,
        0x00,0xF3,0x0F,0x11,0x46,0x0C,0xF3,0x0F,0x10,0x80,0x64,0x05,
        0x00,0x00,0xF3,0x0F,0x59,0x05,0xBC,0x2B,0x06,0x10,0xF3,0x0F,
        0x11,0x46,0x10,0x8B,0x80,0x54,0x05,0x00,0x00,0x89,0x46,0x14,
        0x5E,0xC3
    };
    uint32_t pointer, displacement;
    if (!plan || !module_base || !code_address || !helper_address) return FALSE;
    memset(plan, 0, sizeof(*plan));
    plan->patch_address = module_base + TH09_LASER_UPDATE_RVA;
    plan->gateway_address = code_address;
    memcpy(plan->expected, original, sizeof(original));
    pointer = module_base + TH09_LASER_HALF_RVA;
    /* The complete function has exactly one HIGHLOW relocation, at +0x36. */
    memcpy(plan->expected + 0x36, &pointer, 4);

    /* Original seven bytes (three whole instructions): mov edx,[ecx+8]; push esi;
     * mov esi,[ecx+10]. The gateway finishes the original routine and returns
     * to our bridge, so its dimensions and angle remain byte-for-byte native. */
    memcpy(plan->code, plan->expected, TH09_LASER_PATCH_SIZE);
    plan->code_length = TH09_LASER_PATCH_SIZE;
    emit_relative(plan, 0xE9, code_address, plan->patch_address + TH09_LASER_PATCH_SIZE);
    while (plan->code_length < 16) emit8(plan, 0x90);
    plan->bridge_address = code_address + plan->code_length;
    emit8(plan, 0x51); /* push ecx: preserve this below the gateway return */
    emit_relative(plan, 0xE8, code_address, plan->gateway_address);
    emit8(plan, 0x9C); emit8(plan, 0x60); /* pushfd; pushad */
    emit8(plan, 0x89); emit8(plan, 0xE3); /* mov ebx,esp: saved-register frame */
    emit8(plan, 0x81); emit8(plan, 0xEC); emit32(plan, 0x210);
    emit8(plan, 0x83); emit8(plan, 0xE4); emit8(plan, 0xF0); /* align scratch */
    emit8(plan, 0x0F); emit8(plan, 0xAE); emit8(plan, 0x04); emit8(plan, 0x24); /* fxsave [esp] */
    emit8(plan, 0x8B); emit8(plan, 0x43); emit8(plan, 0x24); /* mov eax,[ebx+36]: this */
    emit8(plan, 0x50);
    emit_relative(plan, 0xE8, code_address, helper_address);
    emit8(plan, 0x83); emit8(plan, 0xC4); emit8(plan, 0x04);
    emit8(plan, 0x0F); emit8(plan, 0xAE); emit8(plan, 0x0C); emit8(plan, 0x24); /* fxrstor [esp] */
    emit8(plan, 0x89); emit8(plan, 0xDC); /* mov esp,ebx */
    emit8(plan, 0x61); emit8(plan, 0x9D); /* popad; popfd */
    emit8(plan, 0x8D); emit8(plan, 0x64); emit8(plan, 0x24); emit8(plan, 0x04);
    emit8(plan, 0xC3);

    plan->patch[0] = 0xE9;
    displacement = plan->bridge_address - (plan->patch_address + 5);
    memcpy(plan->patch + 1, &displacement, 4);
    plan->patch[5] = plan->patch[6] = 0x90;
    return TRUE;
}

BOOL Th09LaserSensorInstall(Th09LaserSensorLogFn logfn) {
    HMODULE module;
    Th09LaserSensorPlan plan;
    unsigned char actual[TH09_LASER_UPDATE_SIZE];
    unsigned char *code = NULL, *target;
    uint32_t vtable_update = 0, half_bits = 0;
    SIZE_T received = 0;
    DWORD previous, unused;
    BOOL success = FALSE;
    const char *reason = "already attempted or wrong architecture";
    if (sizeof(void *) != 4 || InterlockedCompareExchange(&sensor_install_attempted, 1, 0))
        goto finish;
    module = GetModuleHandleW(L"inject.dll");
    reason = "verified upstream inject.dll is not loaded";
    if (!module) goto finish;
    code = (unsigned char *)VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    reason = "gateway allocation failed";
    if (!code) goto finish;
    Th09LaserSensorBuildPlan((uint32_t)(uintptr_t)module, (uint32_t)(uintptr_t)code,
                            (uint32_t)(uintptr_t)Th09LaserSensorCorrectManaged, &plan);
    target = (unsigned char *)(uintptr_t)plan.patch_address;
    reason = "upstream Laser::Update, vtable or constant mismatch";
    if (!ReadProcessMemory(GetCurrentProcess(), target, actual, sizeof(actual), &received) ||
        received != sizeof(actual) || memcmp(actual, plan.expected, sizeof(actual))) goto finish;
    if (!ReadProcessMemory(GetCurrentProcess(), (unsigned char *)module + TH09_LASER_VTABLE_RVA + 5 * 4,
            &vtable_update, 4, &received) || received != 4 || vtable_update != plan.patch_address) goto finish;
    if (!ReadProcessMemory(GetCurrentProcess(), (unsigned char *)module + TH09_LASER_HALF_RVA,
            &half_bits, 4, &received) || received != 4 || half_bits != 0x3F000000u) goto finish;
    memcpy(code, plan.code, plan.code_length);
    reason = "gateway memory protection/cache flush failed";
    if (!VirtualProtect(code, 4096, PAGE_EXECUTE_READ, &previous) ||
        !FlushInstructionCache(GetCurrentProcess(), code, plan.code_length)) goto finish;
    reason = "target memory protection/write/cache flush failed";
    if (!VirtualProtect(target, TH09_LASER_PATCH_SIZE, PAGE_EXECUTE_READWRITE, &previous)) goto finish;
    memcpy(target, plan.patch, TH09_LASER_PATCH_SIZE);
    if (!FlushInstructionCache(GetCurrentProcess(), target, TH09_LASER_PATCH_SIZE) ||
        !VirtualProtect(target, TH09_LASER_PATCH_SIZE, previous, &unused) ||
        memcmp(target, plan.patch, TH09_LASER_PATCH_SIZE)) goto finish;
    success = TRUE;
finish:
    /* Keep allocated code on failure: a partial hook must never jump to freed
     * memory. Caller must reject the startup handshake and terminate its child. */
    if (logfn) {
        char message[256];
        if (success) strcpy(message, "laser_sensor: install=ok managed segment anchor corrected; game physics unchanged");
        else {
            _snprintf(message, sizeof(message) - 1, "laser_sensor: install=FAILED reason=%s", reason);
            message[sizeof(message) - 1] = 0;
        }
        logfn(message);
    }
    return success;
}

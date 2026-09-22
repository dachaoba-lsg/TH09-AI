#include "laser_sensor.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static int failures;
static void check(int condition, const char *what) {
    if (!condition) { printf("FAIL: %s\n", what); ++failures; }
}
static void hexbytes(const unsigned char *bytes, unsigned int count) {
    unsigned int i; for (i = 0; i < count; ++i) printf("%02x", bytes[i]);
}
static void put_float(unsigned char *address, float value) { memcpy(address, &value, 4); }
static float get_float(unsigned char *address) { float value; memcpy(&value, address, 4); return value; }
static void test_native_bridge(float angle, float length1) {
    unsigned char raw[0x59C], original_raw[0x59C], object[24], body[24], expected_body[24];
    unsigned char *image = NULL, *gate = NULL, *pointer, *stub;
    uint32_t value;
    DWORD previous;
    Th09LaserSensorPlan plan;
    float x, y;
    void (__cdecl *run)(void);
    image = (unsigned char *)VirtualAlloc(NULL, 0x70000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    gate = (unsigned char *)VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    check(image != NULL && gate != NULL, "isolated bridge allocations");
    if (!image || !gate) goto cleanup;
    Th09LaserSensorBuildPlan((uint32_t)(uintptr_t)image, (uint32_t)(uintptr_t)gate,
                            (uint32_t)(uintptr_t)Th09LaserSensorCorrectManaged, &plan);
    memcpy(image + TH09_LASER_UPDATE_RVA, plan.expected, sizeof(plan.expected));
    put_float(image + TH09_LASER_HALF_RVA, 0.5f);
    memcpy(gate, plan.code, plan.code_length);
    memset(raw, 0xA5, sizeof(raw)); memset(object, 0xCC, sizeof(object));
    memset(body, 0x5A, sizeof(body));
    put_float(raw + 0x548, -100.0f); put_float(raw + 0x54C, 448.0f);
    put_float(raw + 0x554, angle); put_float(raw + 0x558, length1);
    put_float(raw + 0x55C, length1 + 40.0f); put_float(raw + 0x564, 16.0f);
    pointer = raw + 0x548; memcpy(object + 8, &pointer, 4);
    pointer = raw; memcpy(object + 0x0C, &pointer, 4);
    pointer = body; memcpy(object + 0x10, &pointer, 4);
    memcpy(original_raw, raw, sizeof(raw));
    /* Invoke thiscall with ECX from a tiny cdecl stub in this test process.
     * No game/inject module is loaded or opened, and no foreign memory exists. */
    stub = gate + 256; stub[0] = 0xB9;
    value = (uint32_t)(uintptr_t)object; memcpy(stub + 1, &value, 4);
    stub[5] = 0xB8; value = plan.patch_address; memcpy(stub + 6, &value, 4);
    stub[10] = 0xFF; stub[11] = 0xD0; stub[12] = 0xC3;
    if (!VirtualProtect(image, 0x70000, PAGE_EXECUTE_READ, &previous) ||
        !VirtualProtect(gate, 4096, PAGE_EXECUTE_READ, &previous)) {
        check(0, "isolated original/bridge executable protections"); goto cleanup;
    }
    FlushInstructionCache(GetCurrentProcess(), image, 0x70000);
    FlushInstructionCache(GetCurrentProcess(), gate, 4096);
    run = (void (__cdecl *)(void))(uintptr_t)stub;
    run(); /* Actual original SSE routine first; establishes other fields. */
    memcpy(expected_body, body, sizeof(body));
    check(Th09LaserSensorProject(-100, 448, length1, angle, &x, &y), "native bridge expected projection");
    put_float(expected_body + 4, x); put_float(expected_body + 8, y);
    if (!VirtualProtect(image + TH09_LASER_UPDATE_RVA, TH09_LASER_PATCH_SIZE,
                        PAGE_EXECUTE_READWRITE, &previous)) {
        check(0, "isolated patch writable protection"); goto cleanup;
    }
    memcpy(image + TH09_LASER_UPDATE_RVA, plan.patch, TH09_LASER_PATCH_SIZE);
    check(VirtualProtect(image + TH09_LASER_UPDATE_RVA, TH09_LASER_PATCH_SIZE,
                         PAGE_EXECUTE_READ, &previous), "isolated patch restore protection");
    FlushInstructionCache(GetCurrentProcess(), image + TH09_LASER_UPDATE_RVA, TH09_LASER_PATCH_SIZE);
    memset(body, 0x5A, sizeof(body));
    run(); /* Actual bridge, actual compiled C helper, actual FXSAVE/FXRSTOR. */
    check(!memcmp(body, expected_body, sizeof(body)), "real x86 bridge preserves dimensions and fixes anchor");
    check(!memcmp(raw, original_raw, sizeof(raw)), "real x86 bridge never writes raw game data");
cleanup:
    if (gate) VirtualFree(gate, 0, MEM_RELEASE);
    if (image) VirtualFree(image, 0, MEM_RELEASE);
}
static void test_angle(float angle, float length1) {
    unsigned char raw[0x59C], before_raw[0x59C], object[24], body[24], expected[24];
    unsigned char *pointer;
    float x = 0, y = 0;
    memset(raw, 0xA5, sizeof(raw)); memset(object, 0xCC, sizeof(object));
    memset(body, 0x5A, sizeof(body));
    put_float(raw + 0x548, 12.0f); put_float(raw + 0x54C, -23.0f);
    put_float(raw + 0x554, angle); put_float(raw + 0x558, length1);
    pointer = raw + 0x548; memcpy(object + 8, &pointer, 4);
    pointer = raw; memcpy(object + 0x0C, &pointer, 4);
    pointer = body; memcpy(object + 0x10, &pointer, 4);
    memcpy(before_raw, raw, sizeof(raw)); memcpy(expected, body, sizeof(body));
    check(Th09LaserSensorProject(12, -23, length1, angle, &x, &y), "finite projection accepted");
    check(fabs((double)x - (12.0 + length1 * cos((double)angle))) < 0.00003, "projected x");
    check(fabs((double)y - (-23.0 + length1 * sin((double)angle))) < 0.00003, "projected y");
    put_float(expected + 4, x); put_float(expected + 8, y);
    Th09LaserSensorCorrectManaged(object);
    check(!memcmp(body, expected, sizeof(body)), "only managed x/y change");
    check(!memcmp(raw, before_raw, sizeof(raw)), "raw game laser unchanged");
    check(get_float(body + 4) == x && get_float(body + 8) == y, "managed coordinates match");
    /* A wrong object layout must not write its candidate hitBody. */
    pointer = raw + 0x540; memcpy(object + 8, &pointer, 4);
    memset(body, 0x5A, sizeof(body)); memcpy(expected, body, sizeof(body));
    Th09LaserSensorCorrectManaged(object);
    check(!memcmp(body, expected, sizeof(body)), "mismatched position reference rejected");
}
static void test_log(const char *message) { puts(message); }

int main(int argc, char **argv) {
    Th09LaserSensorPlan plan;
    if (argc == 5 && strcmp(argv[1], "--dump") == 0) {
        uint32_t base = (uint32_t)strtoul(argv[2], NULL, 0);
        uint32_t code = (uint32_t)strtoul(argv[3], NULL, 0);
        uint32_t helper = (uint32_t)strtoul(argv[4], NULL, 0);
        if (!Th09LaserSensorBuildPlan(base, code, helper, &plan)) return 2;
        printf("EXPECTED %08lx ", (unsigned long)plan.patch_address);
        hexbytes(plan.expected, sizeof(plan.expected)); puts("");
        printf("PATCH %08lx ", (unsigned long)plan.patch_address);
        hexbytes(plan.patch, sizeof(plan.patch)); puts("");
        printf("CODE %08lx ", (unsigned long)plan.gateway_address);
        hexbytes(plan.code, plan.code_length); puts("");
        return 0;
    }
    check(sizeof(void *) == 4, "x86 compiler required");
    test_angle(0, 0); test_angle(0, 80); test_angle(1.5707963267948966f, 80);
    test_angle(-1.5707963267948966f, 80); test_angle(3.141592653589793f, 80);
    test_angle(0.8f, 123.5f); test_angle(-0.8f, 123.5f); test_angle(0.8f, -12.0f);
    test_native_bridge(0, 0); test_native_bridge(0, 80);
    test_native_bridge(-1.5707963267948966f, 80); test_native_bridge(0.8f, 123.5f);
    {
        uint32_t nan_bits = 0x7FC00001u; float nan_value, x = 9, y = 10;
        memcpy(&nan_value, &nan_bits, 4);
        check(!Th09LaserSensorProject(0, 0, nan_value, 0, &x, &y), "NaN rejected");
        check(x == 9 && y == 10, "failed projection leaves output untouched");
    }
    check(!Th09LaserSensorBuildPlan(0, 1, 1, &plan), "invalid plan base rejected");
    check(!Th09LaserSensorInstall(test_log), "missing inject.dll fails closed in isolated harness");
    if (failures) return 1;
    puts("PASS: laser projection/layout, real x86 bridge, raw-state preservation and missing-module fail-closed tests");
    return 0;
}

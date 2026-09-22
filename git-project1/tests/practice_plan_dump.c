/* Offline fixture: builds gates at deterministic addresses, never injects. */
#include "../src/native/practice_patches.h"
#include <stdio.h>
#include <stdlib.h>
static void hex(const unsigned char *data, unsigned int size) {
    unsigned int i;
    for (i = 0; i < size; ++i) printf("%02X", data[i]);
}
int main(int argc, char **argv) {
    Th09PracticePlan p; unsigned int i;
    if (argc != 3 || !Th09PracticeBuildPlan(atoi(argv[1]), atoi(argv[2]), 0x600000, 0x600800, &p)) return 2;
    printf("CODE %08X ", p.code_address); hex(p.code, p.code_length); printf("\n");
    for (i = 0; i < p.patch_count; ++i) {
        printf("PATCH %08X ", p.patches[i].address);
        hex(p.patches[i].before, p.patches[i].length); printf(" ");
        hex(p.patches[i].after, p.patches[i].length); printf("\n");
    }
    return 0;
}

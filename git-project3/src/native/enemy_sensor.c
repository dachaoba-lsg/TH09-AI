/* Read-only, same-object enemy combat data appended after SetEnemyFields.
 * The upstream managed ID is never inferred from position or raw slot order.
 * Only injected Lua tables and checked export gateway bytes are written. */
#include "enemy_sensor.h"
#include <stdio.h>
#include <string.h>
static LONG install_attempted;
static Th09PlayerSensorLuaApi lua_api;
static uint32_t u32(const unsigned char *p){uint32_t v;memcpy(&v,p,4);return v;}
static int i32(const unsigned char *p){int v;memcpy(&v,p,4);return v;}
static float f32(const unsigned char *p){float v;memcpy(&v,p,4);return v;}
static int bounded(float v,float limit){return v==v&&v>=-limit&&v<=limit;}
static BOOL rpm(uint32_t a,void *out,size_t n,void *ctx){SIZE_T got=0;(void)ctx;
    return ReadProcessMemory(GetCurrentProcess(),(void *)(uintptr_t)a,out,n,&got)&&got==n;}

BOOL Th09EnemySensorCollect(uint32_t managed,Th09PlayerSensorReadFn rd,void *ctx,Th09EnemySnapshot *out){
    unsigned char object[12],again[12],board[4],hp[4],flags[8],timer[4],position[8],size[20],verify[8];
    Th09EnemySnapshot s;uint32_t raw,container,start,delta;int side,found=0;
    if(!out)return FALSE;memset(out,0,sizeof(*out));memset(&s,0,sizeof(s));
    if(!rd||managed<0x10000u||managed>0xffffff00u||managed%4||!rd(managed,object,sizeof(object),ctx))return FALSE;
    s.id=u32(object+4);raw=u32(object+8);
    if(!s.id||raw<0x10000u||raw>0xffffa000u||raw%4)return FALSE;
    for(side=0;side<2;side++){
        if(!rd(0x4a7da0u+(uint32_t)side*0x38u,board,4,ctx))return FALSE;
        container=u32(board);
        if(container<0x10000u||container>0xffd590a8u||container%4)continue;
        start=container+0x5758u;
        if(raw<start)continue;delta=raw-start;
        if(delta<128u*0x5430u&&delta%0x5430u==0){
            if(found)return FALSE;found=1;s.side=side+1;s.slot_index=(int)(delta/0x5430u)+1;
        }
    }
    if(!found||!rd(raw+0x2e48,hp,4,ctx)||!rd(raw+0x337c,flags,8,ctx)||
       !rd(raw+0x53b0,timer,4,ctx)||!rd(raw+0x2dd4,position,8,ctx)||!rd(raw+0x2dbc,size,sizeof(size),ctx))return FALSE;
    s.hp=i32(hp);s.flags=u32(flags);s.flags2=u32(flags+4);s.protection_ticks=i32(timer);
    s.x=f32(position);s.y=f32(position+4);s.width=f32(size);s.height=f32(size+4);
    s.secondary_width=f32(size+12);s.secondary_height=f32(size+16);
    /* Bit 4 enables additional segmented hit bodies at 3404/53A4. Their
     * collision/consumption is not represented by these two AABBs. */
    if((s.flags&0x105u)!=1u||s.hp < -1000000||s.hp>1000000||
       s.protection_ticks < -1000000||s.protection_ticks>1000000||
       !bounded(s.x,1000000)||!bounded(s.y,1000000)||!bounded(s.width,4096)||
       !bounded(s.height,4096)||s.width<=0||s.height<=0||!bounded(s.secondary_width,4096)||
       !bounded(s.secondary_height,4096)||(s.secondary_width>0&&s.secondary_height<=0))return FALSE;
    /* 410E9A/410FAB decide if enemy queries the player's shot AABBs at all.
     * 41103B and the 53A8 Timer gate decide whether raw damage reduces HP.
     * A blocked HP subtraction can still consume a type-0 shot. */
    s.blocks_shots=!(s.flags&0x30u)&&(s.flags&0x40u)!=0;
    s.secondary_blocks_shots=s.blocks_shots&&s.secondary_width>0;
    /* Secondary query consumes shots but its return is not added to primary
     * total; it also overwrites the shot-damage classification. Export exact
     * separate geometry for blocking, but do not promise a simple HP model. */
    s.damageable=s.blocks_shots&&!s.secondary_blocks_shots&&(s.flags&8u)!=0&&s.protection_ticks<=0&&s.hp>0&&!(s.flags2&9u);
    s.shot_damage_divisor=(s.flags2&0x1c0u)?((s.flags2&0x1000u)?2:4):1;
    /* 4103B7 skips explosion-circle creation for unactivated spirits killed
     * by direct shots; HP sufficiency alone must never promote them to seeds. */
    s.shot_can_ignite=s.damageable&&(!(s.flags2&0x1c0u)||(s.flags2&0x1000u))&&
        !(s.flags&0x80002410u);
    if(!rd(managed,again,sizeof(again),ctx)||memcmp(object,again,sizeof(object))||
       !rd(raw+0x337c,verify,8,ctx)||memcmp(flags,verify,8)||
       !rd(raw+0x2e48,verify,4,ctx)||memcmp(hp,verify,4)||
       !rd(raw+0x53b0,verify,4,ctx)||memcmp(timer,verify,4))return FALSE;
    s.valid=1;*out=s;return TRUE;
}
static void number(void *L,const Th09PlayerSensorLuaApi *a,const char *key,double v){
    a->push_string(L,key);a->push_number(L,v);a->set_table(L,-3);}
static void boolean(void *L,const Th09PlayerSensorLuaApi *a,const char *key,int v){
    a->push_string(L,key);a->push_boolean(L,v);a->set_table(L,-3);}
void Th09EnemySensorWriteTable(void *L,const Th09PlayerSensorLuaApi *a,const Th09EnemySnapshot *s){
    a->push_string(L,"combat");a->create_table(L,0,20);
    number(L,a,"apiVersion",TH09_ENEMY_COMBAT_API);boolean(L,a,"valid",s->valid);
    number(L,a,"id",s->id);number(L,a,"side",s->side);number(L,a,"slotIndex",s->slot_index);
    number(L,a,"hp",s->hp);number(L,a,"flags",s->flags);number(L,a,"flags2",s->flags2);
    number(L,a,"x",s->x);number(L,a,"y",s->y);number(L,a,"width",s->width);number(L,a,"height",s->height);
    number(L,a,"secondaryWidth",s->secondary_width);number(L,a,"secondaryHeight",s->secondary_height);
    number(L,a,"protectionTicks",s->protection_ticks);number(L,a,"shotDamageDivisor",s->shot_damage_divisor);
    boolean(L,a,"blocksShots",s->blocks_shots);boolean(L,a,"damageable",s->damageable);
    boolean(L,a,"secondaryBlocksShots",s->secondary_blocks_shots);
    boolean(L,a,"shotCanIgnite",s->shot_can_ignite);a->set_table(L,-3);
}
static void __cdecl append_sensor(void *L,void *managed){Th09EnemySnapshot s;
    Th09EnemySensorCollect((uint32_t)(uintptr_t)managed,rpm,NULL,&s);Th09EnemySensorWriteTable(L,&lua_api,&s);}
static void emit8(Th09EnemySensorPlan *p,unsigned char b){p->code[p->code_length++]=b;}
static void emit32(Th09EnemySensorPlan *p,uint32_t b){memcpy(p->code+p->code_length,&b,4);p->code_length+=4;}
static void rel(Th09EnemySensorPlan *p,unsigned char op,uint32_t base,uint32_t to){
    emit8(p,op);emit32(p,to-(base+(uint32_t)p->code_length+4));}
BOOL Th09EnemySensorBuildPlan(uint32_t module,uint32_t code,uint32_t helper,Th09EnemySensorPlan *p){
    static const unsigned char prologue[5]={0x55,0x8b,0xec,0x6a,0xff};uint32_t displacement;
    if(!module||!code||!helper||!p)return FALSE;memset(p,0,sizeof(*p));
    p->patch_address=module+TH09_ENEMY_FIELDS_RVA;p->gateway_address=code;
    memcpy(p->code,prologue,5);p->code_length=5;rel(p,0xe9,code,p->patch_address+5);
    while(p->code_length<16)emit8(p,0x90);p->bridge_address=code+(uint32_t)p->code_length;
    emit8(p,0x52);emit8(p,0x51);rel(p,0xe8,code,p->gateway_address);
    emit8(p,0x9c);emit8(p,0x60);emit8(p,0x89);emit8(p,0xe3);
    emit8(p,0x81);emit8(p,0xec);emit32(p,0x210);emit8(p,0x83);emit8(p,0xe4);emit8(p,0xf0);
    emit8(p,0x0f);emit8(p,0xae);emit8(p,0x04);emit8(p,0x24);
    emit8(p,0xff);emit8(p,0x73);emit8(p,0x28);emit8(p,0xff);emit8(p,0x73);emit8(p,0x24);
    rel(p,0xe8,code,helper);emit8(p,0x83);emit8(p,0xc4);emit8(p,0x08);
    emit8(p,0x0f);emit8(p,0xae);emit8(p,0x0c);emit8(p,0x24);
    emit8(p,0x89);emit8(p,0xdc);emit8(p,0x61);emit8(p,0x9d);
    emit8(p,0x8d);emit8(p,0x64);emit8(p,0x24);emit8(p,0x08);emit8(p,0xc3);
    p->patch[0]=0xe9;displacement=p->bridge_address-(p->patch_address+5);memcpy(p->patch+1,&displacement,4);return TRUE;
}
static uint32_t hash(const unsigned char *p,size_t n){uint32_t h=2166136261u;while(n--)h=(h^*p++)*16777619u;return h;}
typedef struct {uint32_t address,length,hash;} Fingerprint;
static BOOL verify_fingerprint(Fingerprint f){unsigned char data[TH09_ENEMY_FIELDS_SIZE];
    return f.length<=sizeof(data)&&rpm(f.address,data,f.length,NULL)&&hash(data,f.length)==f.hash;}
BOOL Th09EnemySensorInstall(Th09PlayerSensorLogFn logfn){
    static const unsigned short reloc[]={0x6,0x18,0x31,0x4b,0x69,0xa8,0x127,0x171,0x215,0x241,0x276,0x2c9,0x2ed,0x33b,0x35f,0x38a,0x3c5};
    static const Fingerprint apis[]={{0x17e0,0x19,0xef1c7cb3},{0x1860,0x66,0xa5d882bf},
        {0x19d0,0x1e,0x846388ac},{0x1b50,0x40,0x1f6bc85f},{0x1c60,0x2b,0x32bd45de}};
    static const Fingerprint game[]={{0x410E9A,0x27,0xF97F4270u},{0x410FAB,0x141,0xCE5ACAFAu},
        {0x4111B3,0x20B,0xCBF0CFECu},{0x4102B0,0x204,0x68834A3Bu},{0x40F1D0,0x170,0xED9902A7u},
        {0x403DE0,0x14,0x0018AEDEu},{0x4110EC,0x7A,0x811E4955u},
        {0x410848,0x37,0xD915418Bu},{0x41162A,0x18,0x64E1E14Bu}};
    unsigned char original[TH09_ENEMY_FIELDS_SIZE],*code=NULL,*target;HMODULE module;
    uint32_t base,value;size_t i;DWORD old,unused;Th09EnemySensorPlan plan;BOOL success=FALSE;
    const char *reason="already attempted or wrong architecture";
    if(sizeof(void*)!=4||InterlockedCompareExchange(&install_attempted,1,0))goto finish;
    reason="verified inject.dll missing";module=GetModuleHandleW(L"inject.dll");if(!module)goto finish;base=(uint32_t)(uintptr_t)module;
    reason="SetEnemyFields fingerprint mismatch";if(!rpm(base+TH09_ENEMY_FIELDS_RVA,original,sizeof(original),NULL))goto finish;
    for(i=0;i<sizeof(reloc)/sizeof(reloc[0]);i++){value=u32(original+reloc[i])-base+0x10000000u;memcpy(original+reloc[i],&value,4);}
    if(hash(original,sizeof(original))!=0x4b518202u)goto finish;
    reason="static Lua API fingerprint mismatch";
    for(i=0;i<sizeof(apis)/sizeof(apis[0]);i++){Fingerprint f=apis[i];f.address+=base;if(!verify_fingerprint(f))goto finish;}
    reason="enemy damage/HP/activation fingerprint mismatch";
    for(i=0;i<sizeof(game)/sizeof(game[0]);i++)if(!verify_fingerprint(game[i]))goto finish;
    lua_api.push_string=(void (__cdecl *)(void*,const char*))(uintptr_t)(base+0x1860);
    lua_api.push_number=(void (__cdecl *)(void*,double))(uintptr_t)(base+0x17e0);
    lua_api.push_boolean=(void (__cdecl *)(void*,int))(uintptr_t)(base+0x19d0);
    lua_api.create_table=(void (__cdecl *)(void*,int,int))(uintptr_t)(base+0x1b50);
    lua_api.set_table=(void (__cdecl *)(void*,int))(uintptr_t)(base+0x1c60);
    reason="gateway allocation failed";code=VirtualAlloc(NULL,4096,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);if(!code)goto finish;
    Th09EnemySensorBuildPlan(base,(uint32_t)(uintptr_t)code,(uint32_t)(uintptr_t)append_sensor,&plan);memcpy(code,plan.code,plan.code_length);
    reason="gateway protection/cache failed";
    if(!VirtualProtect(code,4096,PAGE_EXECUTE_READ,&old)||!FlushInstructionCache(GetCurrentProcess(),code,plan.code_length))goto finish;
    target=(unsigned char *)(uintptr_t)plan.patch_address;reason="target protection/write/cache failed";
    if(!VirtualProtect(target,5,PAGE_EXECUTE_READWRITE,&old))goto finish;memcpy(target,plan.patch,5);
    if(!FlushInstructionCache(GetCurrentProcess(),target,5)||!VirtualProtect(target,5,old,&unused)||memcmp(target,plan.patch,5))goto finish;
    success=TRUE;
finish:
    if(logfn){char msg[256];if(success)strcpy(msg,"enemy_sensor: install=ok api=1 readonly enemy combat");
        else {_snprintf(msg,sizeof(msg)-1,"enemy_sensor: install=FAILED reason=%s",reason);msg[sizeof(msg)-1]=0;}logfn(msg);}
    return success;
}

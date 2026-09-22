/* Read-only TH09 Japanese 1.50a / ka_ai_duka v1.7 sensor bridge.
 * Player::SetPlayerFields is compiler-fastcall (ECX=Lua, EDX=managed Player),
 * not the apparent cdecl in source. Hook preserves its return context and
 * appends a Lua-owned table after original export, with no raw game writes.
 *
 * Poison: 44A330 switches ExFeature[0]. Only value 1 reaches 44A527..44A5B6;
 * raw EX+10 timer int >20 && <300, side at +4, strict radius squared <4096,
 * each cloud multiplies each movement axis by binary32 0.4. The two poison
 * factors at player+1CE4/8 are reset by 41BA80; NEVER sample those as speed.
 * Instead recompute the hypothetical factor at this snapshot's position,
 * over current settled clouds. 1CDC/E0 are persistent additional factors.
 * No history of applied displacement is claimed by moveScaleX/Y.
 * Charge: 41FA28 gates on player+1B80 bit4; 41FC42..41FC6B increments C1
 * timer then clears it at feature+28. Initial held-Z warm-up is separate.
 */
#define WIN32_LEAN_AND_MEAN
#include "player_sensor.h"
#include <string.h>
#include <stdio.h>

static LONG install_attempted;
static Th09PlayerSensorLuaApi lua_api;
static uint32_t u32(const unsigned char *p){uint32_t v;memcpy(&v,p,4);return v;}
static int i32(const unsigned char *p){int v;memcpy(&v,p,4);return v;}
static float f32(const unsigned char *p){float v;memcpy(&v,p,4);return v;}
static BOOL finite(float f){uint32_t v;memcpy(&v,&f,4);return (v&0x7f800000u)!=0x7f800000u;}
static float positive(float f){return f>0.0f?f:0.0f;}
static BOOL rpm(uint32_t a,void *p,size_t n,void *context){
    SIZE_T got=0;(void)context;
    return a>=0x10000u && a<=0xffffffffu-n &&
        ReadProcessMemory(GetCurrentProcess(),(void *)(uintptr_t)a,p,n,&got) && got==n;
}

BOOL Th09PlayerSensorCollect(uint32_t raw,Th09PlayerSensorReadFn rd,void *ctx,Th09PlayerSnapshot *s){
    unsigned char head[0x10],pos[0x178],tail[0x98],feature[0x2c];
    unsigned char slots[256*0x4c],tiny[4];
    uint32_t side,ptr,flags,global_flags,manager,container;
    int pause_gate,charge_gate,j,local,age_int;
    float x,y,action_age,duration,warmup,age,poison=1.0f;
    if(!s)return FALSE;
    memset(s,0,sizeof(*s));
    if(!rd || !raw || !rd(raw,head,sizeof(head),ctx) ||
       !rd(raw+0x1b74,pos,sizeof(pos),ctx) || !rd(raw+0x30338,tail,sizeof(tail),ctx))return FALSE;
    s->state=i32(head);side=u32(head+8);
    if(side>1 || s->state<0 || s->state>5)return FALSE;
    if(!rd(0x4a7d94u+side*0x38u,tiny,4,ctx) || u32(tiny)!=raw)return FALSE;
    ptr=u32(tail);
    if(!rd(ptr,feature,sizeof(feature),ctx))return FALSE;
    x=f32(pos+0x14);y=f32(pos+0x18);flags=u32(pos+0xc);
    s->base_x=f32(pos+0x168);s->base_y=f32(pos+0x16c);
    action_age=f32(tail+0x64);duration=f32(feature+0x28);warmup=f32(tail+0x88);
    if(!finite(x)||!finite(y)||!finite(s->base_x)||!finite(s->base_y)||
       s->base_x<0||s->base_y<0||s->base_x>16||s->base_y>16||
       !finite(duration)||duration<0||duration>3600||!finite(action_age)||
       !finite(warmup)||!finite(f32(feature+0x14))||!finite(f32(feature+0x18)))return FALSE;
    if(!rd(0x4a7ec4,tiny,4,ctx))return FALSE;
    global_flags=u32(tiny);s->cut_in=(global_flags&0x1800u)!=0;
    if(!rd(0x4b36b8,tiny,4,ctx))return FALSE;
    s->time_scale=f32(tiny);
    if(!finite(s->time_scale)||s->time_scale<0||s->time_scale>1000.0f)return FALSE;
    /* Original Timer helpers use exactly one unit when delta > .99. */
    if(s->time_scale>0.99f)s->time_scale=1.0f;
    if(!rd(0x4a7e38,tiny,4,ctx))return FALSE;
    manager=u32(tiny);
    if(!rd(manager+0xe94c,tiny,4,ctx))return FALSE;
    pause_gate=i32(tiny);
    if(!rd(manager+0x1095c,tiny,4,ctx))return FALSE;
    charge_gate=i32(tiny);
    s->protection=s->state==3?positive(f32(tail+0x94)):0.0f;
    if(!finite(s->protection)||s->protection>3600)return FALSE;
    s->charge_block=(flags&4)?positive(duration-action_age):0.0f;
    s->charge_warmup=positive(10.0f-warmup);
    /* canCharge is the action/cut-in gate, not whether Z is already held.
     * A still-set action bit with age==duration remains blocked until the
     * original update clears it; report at least one update of blockage. */
    if((flags&4) && s->charge_block<1.0f)s->charge_block=1.0f;
    s->can_charge=!(flags&4) && !s->cut_in && s->state!=5 &&
        pause_gate<0 && pause_gate!=-2 && charge_gate==0;
    s->movement_enabled=(s->state==0||s->state==3)&&!s->cut_in;
    if(!rd(0x4a7e3c,tiny,4,ctx))return FALSE;
    container=u32(tiny);
    /* During a game the original EX container exists even when empty. A
     * missing/unreadable container invalidates the sensor, not "no poison". */
    if(!rd(container+0x1c,slots,sizeof(slots),ctx))return FALSE;
    for(j=0;j<256;j++){
        const unsigned char *e=slots+j*0x4c;
        Th09PoisonCloud *cloud;float dx,dy;
        if(!i32(e+0xc)||u32(e+4)!=side||u32(e+0x40)!=0x44a330u)continue;
        if(!rd(u32(e+0x34),tiny,4,ctx))return FALSE;
        local=i32(tiny);if(local!=1)continue; /* flying seed or fading cloud */
        age=f32(e+0x14);age_int=i32(e+0x18);
        if(!finite(age)||age<0||age>100000||!finite(f32(e+0x20))||!finite(f32(e+0x24)))return FALSE;
        if(age_int>=300)continue;
        cloud=&s->clouds[s->cloud_count++];
        cloud->x=f32(e+0x20);cloud->y=f32(e+0x24);
        cloud->age=age;cloud->age_int=age_int;
        cloud->frames_left=positive(300.0f-age);
        cloud->active=age_int>20&&age_int<300;
        dx=x-cloud->x;dy=y-cloud->y;
        /* float subtraction is stored by the original Vector3D helper;
         * squares/sum are evaluated by x87 without binary32 truncation. */
        if(cloud->active && (double)dx*dx+(double)dy*dy<4096.0)
            poison=(float)((double)poison*(double)0.4f);
    }
    s->move_x=(float)((double)s->base_x*poison);
    s->move_y=(float)((double)s->base_y*poison);
    s->valid=TRUE;
    return TRUE;
}

static void number(void *L,const Th09PlayerSensorLuaApi *a,const char *key,double v){
    a->push_string(L,key);a->push_number(L,v);a->set_table(L,-3);
}
static void boolean(void *L,const Th09PlayerSensorLuaApi *a,const char *key,int v){
    a->push_string(L,key);a->push_boolean(L,v);a->set_table(L,-3);
}
void Th09PlayerSensorWriteTable(void *L,const Th09PlayerSensorLuaApi *a,const Th09PlayerSnapshot *s){
    int i;
    /* Stack: ... player -> ... player "sensor" table -> ... player.
     * Fresh tables avoid stale cloud entries and avoid manipulating any
     * host registry/global state. Maximum temporary Lua stack growth is 8. */
    a->push_string(L,"sensor");a->create_table(L,0,17);
    number(L,a,"apiVersion",TH09_PLAYER_SENSOR_API);boolean(L,a,"valid",s->valid);
    number(L,a,"state",s->state);number(L,a,"protectionFrames",s->protection);
    number(L,a,"chargeBlockFrames",s->charge_block);number(L,a,"chargeWarmupFrames",s->charge_warmup);
    boolean(L,a,"canCharge",s->can_charge);boolean(L,a,"cutIn",s->cut_in);
    boolean(L,a,"movementEnabled",s->movement_enabled);number(L,a,"timeScale",s->time_scale);
    number(L,a,"baseScaleX",s->base_x);number(L,a,"baseScaleY",s->base_y);
    number(L,a,"moveScaleX",s->move_x);number(L,a,"moveScaleY",s->move_y);
    a->push_string(L,"poisonClouds");a->create_table(L,s->valid?s->cloud_count:0,0);
    if(s->valid)for(i=0;i<s->cloud_count;i++){
        const Th09PoisonCloud *c=&s->clouds[i];
        a->push_number(L,i+1);a->create_table(L,0,7);
        number(L,a,"x",c->x);number(L,a,"y",c->y);number(L,a,"radius",64);
        number(L,a,"age",c->age);number(L,a,"ageInt",c->age_int);
        number(L,a,"framesLeft",c->frames_left);boolean(L,a,"active",c->active);
        a->set_table(L,-3);
    }
    a->set_table(L,-3);a->set_table(L,-3);
}

static void __cdecl append_sensor(void *L,void *managed){
    uint32_t raw=0;Th09PlayerSnapshot s;
    memset(&s,0,sizeof(s));
    if(managed && rpm((uint32_t)(uintptr_t)managed,&raw,4,NULL))
        Th09PlayerSensorCollect(raw,rpm,NULL,&s);
    Th09PlayerSensorWriteTable(L,&lua_api,&s);
}

static void emit8(Th09PlayerSensorPlan *p,unsigned char b){p->code[p->code_length++]=b;}
static void emit32(Th09PlayerSensorPlan *p,uint32_t b){memcpy(p->code+p->code_length,&b,4);p->code_length+=4;}
static void rel(Th09PlayerSensorPlan *p,unsigned char op,uint32_t base,uint32_t to){
    emit8(p,op);emit32(p,to-(base+(uint32_t)p->code_length+4));
}
BOOL Th09PlayerSensorBuildPlan(uint32_t module,uint32_t code,uint32_t helper,Th09PlayerSensorPlan *p){
    static const unsigned char prologue[5]={0x55,0x8b,0xec,0x6a,0xff};
    uint32_t displacement;
    if(!module||!code||!helper||!p)return FALSE;
    memset(p,0,sizeof(*p));p->patch_address=module+TH09_PLAYER_FIELDS_RVA;p->gateway_address=code;
    memcpy(p->code,prologue,5);p->code_length=5;rel(p,0xe9,code,p->patch_address+5);
    while(p->code_length<16)emit8(p,0x90);
    p->bridge_address=code+(uint32_t)p->code_length;
    emit8(p,0x52);emit8(p,0x51); /* saved managed and Lua below original call */
    rel(p,0xe8,code,p->gateway_address);
    emit8(p,0x9c);emit8(p,0x60);emit8(p,0x89);emit8(p,0xe3);
    emit8(p,0x81);emit8(p,0xec);emit32(p,0x210);
    emit8(p,0x83);emit8(p,0xe4);emit8(p,0xf0);
    emit8(p,0x0f);emit8(p,0xae);emit8(p,0x04);emit8(p,0x24);
    emit8(p,0xff);emit8(p,0x73);emit8(p,0x28); /* managed */
    emit8(p,0xff);emit8(p,0x73);emit8(p,0x24); /* Lua */
    rel(p,0xe8,code,helper);
    emit8(p,0x83);emit8(p,0xc4);emit8(p,0x08);
    emit8(p,0x0f);emit8(p,0xae);emit8(p,0x0c);emit8(p,0x24);
    emit8(p,0x89);emit8(p,0xdc);emit8(p,0x61);emit8(p,0x9d);
    emit8(p,0x8d);emit8(p,0x64);emit8(p,0x24);emit8(p,0x08);emit8(p,0xc3);
    p->patch[0]=0xe9;displacement=p->bridge_address-(p->patch_address+5);
    memcpy(p->patch+1,&displacement,4);return TRUE;
}

static uint32_t hash(const unsigned char *p,size_t n){uint32_t h=2166136261u;while(n--)h=(h^*p++)*16777619u;return h;}
typedef struct {uint32_t address,length,hash;} Fingerprint;
static BOOL verify_fingerprint(Fingerprint f){
    unsigned char data[TH09_PLAYER_FIELDS_SIZE];
    return f.length<=sizeof(data)&&rpm(f.address,data,f.length,NULL)&&hash(data,f.length)==f.hash;
}
BOOL Th09PlayerSensorInstall(Th09PlayerSensorLogFn logfn){
    static const unsigned short reloc[]={6,0x18,0x32,0x6a,0xa5,0xd9,0x10d,0x141,0x17c,0x1b7,0x1f5,0x229,0x25e,0x28e,0x2cc,0x308,0x340,0x3b6,0x3ee,0x462,0x49a};
    static const Fingerprint apis[]={
        {0x17e0,0x19,0xef1c7cb3},{0x1860,0x66,0xa5d882bf},{0x19d0,0x1e,0x846388ac},
        {0x1b50,0x40,0x1f6bc85f},{0x1c60,0x2b,0x32bd45de}};
    static const Fingerprint game[]={
        {0x44A330,0x335,0x3B9863CC},{0x41BA80,0x79,0x53D6F1F9},
        {0x41C3AB,0x25,0x5B6705DA},{0x41FA08,0x2D,0xB346BC33},
        {0x41FC16,0x5C,0x7F7CA815},{0x41CC80,0x90,0xE191168A},
        {0x41E900,0x11,0xCE37E485},{0x41EAAB,0x17,0x7CF2EF10},
        {0x404980,0x18,0xFF97FEEE},{0x491650,8,0x3420A951}};
    unsigned char original[TH09_PLAYER_FIELDS_SIZE],*code=NULL,*target;
    HMODULE module;uint32_t base,value;size_t i;DWORD old,unused;
    Th09PlayerSensorPlan plan;BOOL success=FALSE;const char *reason="already attempted or wrong architecture";
    if(sizeof(void*)!=4||InterlockedCompareExchange(&install_attempted,1,0))goto finish;
    reason="verified inject.dll missing";module=GetModuleHandleW(L"inject.dll");if(!module)goto finish;
    base=(uint32_t)(uintptr_t)module;
    reason="SetPlayerFields fingerprint mismatch";
    if(!rpm(base+TH09_PLAYER_FIELDS_RVA,original,sizeof(original),NULL))goto finish;
    for(i=0;i<sizeof(reloc)/sizeof(reloc[0]);i++){
        value=u32(original+reloc[i])-base+0x10000000u;memcpy(original+reloc[i],&value,4);
    }
    if(hash(original,sizeof(original))!=0xfcb504c4u)goto finish;
    reason="static Lua API fingerprint mismatch";
    for(i=0;i<sizeof(apis)/sizeof(apis[0]);i++){Fingerprint f=apis[i];f.address+=base;if(!verify_fingerprint(f))goto finish;}
    reason="game movement/charge/Medicine fingerprint mismatch";
    for(i=0;i<sizeof(game)/sizeof(game[0]);i++)if(!verify_fingerprint(game[i]))goto finish;
    lua_api.push_string=(void (__cdecl *)(void*,const char*))(uintptr_t)(base+0x1860);
    lua_api.push_number=(void (__cdecl *)(void*,double))(uintptr_t)(base+0x17e0);
    lua_api.push_boolean=(void (__cdecl *)(void*,int))(uintptr_t)(base+0x19d0);
    lua_api.create_table=(void (__cdecl *)(void*,int,int))(uintptr_t)(base+0x1b50);
    lua_api.set_table=(void (__cdecl *)(void*,int))(uintptr_t)(base+0x1c60);
    reason="gateway allocation failed";code=VirtualAlloc(NULL,4096,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);
    if(!code)goto finish;
    Th09PlayerSensorBuildPlan(base,(uint32_t)(uintptr_t)code,(uint32_t)(uintptr_t)append_sensor,&plan);
    memcpy(code,plan.code,plan.code_length);
    reason="gateway protection/cache failed";
    if(!VirtualProtect(code,4096,PAGE_EXECUTE_READ,&old)||!FlushInstructionCache(GetCurrentProcess(),code,plan.code_length))goto finish;
    target=(unsigned char *)(uintptr_t)plan.patch_address;
    reason="target protection/write/cache failed";
    if(!VirtualProtect(target,5,PAGE_EXECUTE_READWRITE,&old))goto finish;
    memcpy(target,plan.patch,5);
    if(!FlushInstructionCache(GetCurrentProcess(),target,5)||!VirtualProtect(target,5,old,&unused)||memcmp(target,plan.patch,5))goto finish;
    success=TRUE;
finish:
    /* Startup handshake rejects failure. Never free a possibly published gateway. */
    if(logfn){char msg[256];
        if(success)strcpy(msg,"player_sensor: install=ok api=1 readonly snapshot; poison recomputed, C gate exported");
        else {_snprintf(msg,sizeof(msg)-1,"player_sensor: install=FAILED reason=%s",reason);msg[sizeof(msg)-1]=0;}
        logfn(msg);
    }
    return success;
}

/* No game launch, module load, injection or foreign process access. */
#include "player_sensor.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
static int failures,checks;
static void check(int ok,const char *what){checks++;if(!ok){failures++;printf("FAIL %s\n",what);}}
static void put32(unsigned char *p,uint32_t v){memcpy(p,&v,4);}
static void put16(unsigned char *p,unsigned short v){memcpy(p,&v,2);}
static void putf(unsigned char *p,float v){memcpy(p,&v,4);}
static uint32_t get32(const unsigned char *p){uint32_t v;memcpy(&v,p,4);return v;}
static unsigned char player[0x30454],feature[0x2200],manager[0x10960],ex[0x4c*256+0x1c],exfeature[256*4];
/* 3.0 step 1: second board/player used by the read-only opponent gauge. */
static unsigned char opponent[0x30454],ofeature[0x2200];
static unsigned char boards[0x38*2];
static uint32_t globals[5];
static uint32_t fail_address;static int read_calls;
static BOOL reader(uint32_t a,void *out,size_t n,void *ignored){
    unsigned char *p=NULL;size_t available=0;(void)ignored;
    read_calls++;if(fail_address&&a==fail_address)return FALSE;
    if(a>=0x600000 && a<0x600000+sizeof(player)){p=player+a-0x600000;available=sizeof(player)-(a-0x600000);}
    if(a>=0x700000 && a<0x700000+sizeof(feature)){p=feature+a-0x700000;available=sizeof(feature)-(a-0x700000);}
    if(a>=0x800000 && a<0x800000+sizeof(manager)){p=manager+a-0x800000;available=sizeof(manager)-(a-0x800000);}
    if(a>=0x900000 && a<0x900000+sizeof(ex)){p=ex+a-0x900000;available=sizeof(ex)-(a-0x900000);}
    if(a>=0xa00000 && a<0xa00000+sizeof(exfeature)){p=exfeature+a-0xa00000;available=sizeof(exfeature)-(a-0xa00000);}
    if(a>=0x500000 && a<0x500000+sizeof(opponent)){p=opponent+a-0x500000;available=sizeof(opponent)-(a-0x500000);}
    if(a>=0x540000 && a<0x540000+sizeof(ofeature)){p=ofeature+a-0x540000;available=sizeof(ofeature)-(a-0x540000);}
    if(a>=0x4a7d94 && a<0x4a7d94+sizeof(boards)){p=boards+(a-0x4a7d94);available=sizeof(boards)-(a-0x4a7d94);}
    if(a==0x4a7e38){p=(unsigned char *)&globals[1];available=4;}
    if(a==0x4a7e3c){p=(unsigned char *)&globals[2];available=4;}
    if(a==0x4a7ec4){p=(unsigned char *)&globals[3];available=4;}
    if(a==0x4b36b8){p=(unsigned char *)&globals[4];available=4;}
    if(!p||available<n)return FALSE;memcpy(out,p,n);return TRUE;
}
static void fixture(void){
    memset(player,0,sizeof(player));memset(feature,0,sizeof(feature));memset(ex,0,sizeof(ex));memset(exfeature,0,sizeof(exfeature));memset(manager,0,sizeof(manager));
    globals[0]=0x600000;globals[1]=0x800000;globals[2]=0x900000;globals[3]=0;globals[4]=0x3f800000;
    memset(boards,0,sizeof(boards));put32(boards,0x600000);memset(opponent,0,sizeof(opponent));memset(ofeature,0,sizeof(ofeature));
    put32(player+0x30338,0x700000);putf(player+0x1cdc,1);putf(player+0x1ce0,1);
    putf(feature+0x14,4.1f);putf(feature+0x18,2.2f);putf(feature+0x28,60);
    put32(manager+0xe94c,0xffffffff);putf(player+0x1b88,0);putf(player+0x1b8c,300);
    put32(player+0xc114,512);put16(feature+2,2);put32(feature+0x434,0x700440);put16(feature+0x440,0xffff);
    fail_address=0;read_calls=0;
}
/* Valid opponent gauge fixture, mirroring the own-player field layout. */
static void opponent_fixture(int state,float current,float maximum,float speed){
    put32(boards+0x38,0x500000);
    put32(opponent+0x30338,0x540000);
    putf(ofeature+0x24,speed);
    putf(opponent+0x30384,current);putf(opponent+0x30388,maximum);
    put32(opponent,state);
    put32(opponent+0xa8,7);          /* life */
    put32(opponent+0x30414,12);      /* combo */
    put32(opponent+0x3041c,345678);  /* spell point */
    putf(opponent+0x303cc,33);       /* protection when state 3 */
}
static void wave(int slot,int type,int life,int delay,float radius){
    unsigned char *w=slot==512?player+0xb0bc:player+0x28bc+slot*0x44;
    memset(w,0,0x44);putf(w,20);putf(w+4,310);putf(w+8,radius);putf(w+0xc,4);
    put32(w+0x24,life);put32(w+0x38,type);w[0x3c]=1;put32(w+0x40,delay);
}
static void wave_list(int count){
    int j;put32(player+0xc110,count);put32(player+0xc114,512-count);
    for(j=0;j<count;j++)put32(player+0xb100+j*4,0x600000+0x28bc+j*0x44);
    put32(player+0xb100+count*4,0);
}
static void c1_template(int index,int tick,int type){
    unsigned char *r=feature+0x440+index*0x38;
    memset(r,0,0x38);put16(r,tick);putf(r+4,6);putf(r+8,-12);putf(r+0xc,16);putf(r+0x10,32);
    putf(r+0x14,-1.57079632679f);putf(r+0x18,12);put16(r+0x1c,2);put16(r+0x22,type);
    put16(r+0x38,0xffff);
}
static void c1_active(int slot,int template_index,int type){
    unsigned char *s=player+0xc11c+slot*0x484;
    putf(s+0x2a4,12);putf(s+0x2a8,240);putf(s+0x430,16);putf(s+0x434,32);
    putf(s+0x43c,0);putf(s+0x440,-12);putf(s+0x458,3);put16(s+0x460,2);
    put16(s+0x462,1);put16(s+0x464,type);put32(s+0x480,0x700440+template_index*0x38);
}
static void reimu_template(int index){
    unsigned char *r=feature+0x440+index*0x38;
    c1_template(index,0,0);putf(r+4,8);putf(r+8,0);
    putf(r+0xc,48);putf(r+0x10,48);putf(r+0x18,.5f);
    put16(r+0x1c,30);put32(r+0x2c,0x4415e0);
}
static void reimu_active(void){
    unsigned char *r=player+0xc11c;
    c1_active(0,0,0);putf(r+0x430,48);putf(r+0x434,48);
    putf(r+0x44c,.5f);put16(r+0x460,30);put32(r+0x474,0x4415e0);
    put32(r+0x454,39);put32(r+0x45c,40);
}
static void cloud(int j,int side,int local,float age,float x,float y){
    unsigned char *e=ex+0x1c+j*0x4c;
    put32(e+4,side);put32(e+0xc,1);putf(e+0x14,age);put32(e+0x18,(uint32_t)(int)age);
    putf(e+0x20,x);putf(e+0x24,y);put32(e+0x34,0xa00000+j*4);put32(exfeature+j*4,local);put32(e+0x40,0x44a330);
}
typedef struct {int kind;double number;const char *string;int table;} Value;
typedef struct {int count,capacity;Value *keys,*values;} Table;
static Table tables[1100];static Value stack[24];static int top,table_count,max_top;
static Value val(int kind){Value v;memset(&v,0,sizeof(v));v.kind=kind;return v;}
static void push(Value v){check(top<24,"mock Lua stack bound");stack[top++]=v;if(top>max_top)max_top=top;}
static void __cdecl mock_string(void *L,const char *k){Value v=val(1);check(L==stack,"Lua pointer preserved");v.string=k;push(v);}
static void __cdecl mock_number(void *L,double n){Value v=val(2);(void)L;v.number=n;push(v);}
static void __cdecl mock_bool(void *L,int n){Value v=val(3);(void)L;v.number=!!n;push(v);}
static void __cdecl mock_table(void *L,int array,int record){Value v=val(4);Table *t;(void)L;check(table_count<1100,"Lua mock table pool");v.table=table_count++;t=&tables[v.table];t->capacity=(array>record?array:record)+4;t->keys=calloc(t->capacity,sizeof(Value));t->values=calloc(t->capacity,sizeof(Value));check(t->keys&&t->values,"mock table allocation");push(v);}
static void __cdecl mock_set(void *L,int index){int target=top+index;Table *t;(void)L;check(target>=0&&stack[target].kind==4,"settable has parent table");t=&tables[stack[target].table];check(t->count<t->capacity,"mock table capacity");t->keys[t->count]=stack[top-2];t->values[t->count++]=stack[top-1];top-=2;}
static const Th09PlayerSensorLuaApi api={mock_string,mock_number,mock_bool,mock_table,mock_set};
static Value field(int table,const char *key){int i;Table *t=&tables[table];for(i=t->count-1;i>=0;i--)if(t->keys[i].kind==1&&!strcmp(t->keys[i].string,key))return t->values[i];return val(0);}
static void reset_lua(void){int i;for(i=0;i<table_count;i++){free(tables[i].keys);free(tables[i].values);}memset(tables,0,sizeof(tables));top=table_count=max_top=0;mock_table(stack,0,16);}
static void json_value(Value v){int i,array;Table *t;
    if(v.kind==1){printf("\"%s\"",v.string);return;}
    if(v.kind==2){printf("%.9g",v.number);return;}
    if(v.kind==3){printf("%s",v.number?"true":"false");return;}
    if(v.kind!=4){printf("null");return;}
    t=&tables[v.table];array=t->count&&t->keys[0].kind==2;putchar(array?'[':'{');
    for(i=0;i<t->count;i++){if(i)putchar(',');if(!array){json_value(t->keys[i]);putchar(':');}json_value(t->values[i]);}
    putchar(array?']':'}');
}
static Th09PlayerSnapshot bridge_snapshot;static int bridge_calls;
static void __cdecl bridge_helper(void *L,void *managed){
    check(L==stack,"real bridge saved ECX argument");check(managed==player,"real bridge saved EDX argument");
    bridge_calls++;Th09PlayerSensorWriteTable(L,&api,&bridge_snapshot);
}
static void test_bridge(void){
    unsigned char *image=VirtualAlloc(NULL,0x20000,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);
    unsigned char *code=VirtualAlloc(NULL,4096,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE),*stub;
    const unsigned char fake_original[]={0x55,0x8b,0xec,0x6a,0xff,0xb9,0x11,0x11,0x11,0x11,0xba,0x22,0x22,0x22,0x22,0x83,0xc4,0x04,0x5d,0xc3};
    Th09PlayerSensorPlan p;DWORD old;void (__cdecl *run)(void);
    check(image&&code,"bridge allocation");if(!image||!code)return;
    Th09PlayerSensorBuildPlan((uint32_t)(uintptr_t)image,(uint32_t)(uintptr_t)code,(uint32_t)(uintptr_t)bridge_helper,&p);
    memcpy(image+TH09_PLAYER_FIELDS_RVA,fake_original,sizeof(fake_original));memcpy(image+TH09_PLAYER_FIELDS_RVA,p.patch,5);memcpy(code,p.code,p.code_length);
    stub=code+256;stub[0]=0xb9;put32(stub+1,(uint32_t)(uintptr_t)stack);stub[5]=0xba;put32(stub+6,(uint32_t)(uintptr_t)player);stub[10]=0xb8;put32(stub+11,p.patch_address);stub[15]=0xff;stub[16]=0xd0;stub[17]=0xc3;
    check(VirtualProtect(image,0x20000,PAGE_EXECUTE_READ,&old)&&VirtualProtect(code,4096,PAGE_EXECUTE_READ,&old),"bridge executable");
    FlushInstructionCache(GetCurrentProcess(),image,0x20000);FlushInstructionCache(GetCurrentProcess(),code,4096);
    reset_lua();run=(void (__cdecl *)(void))stub;run();
    check(bridge_calls==1&&top==1,"real bridge callback once / balanced Lua stack");
    check(field(field(0,"sensor").table,"apiVersion").number==1,"real bridge writes sensor table");
    VirtualFree(image,0,MEM_RELEASE);VirtualFree(code,0,MEM_RELEASE);
}
static void hexbytes(const unsigned char *p,size_t n){while(n--)printf("%02x",*p++);}
/* Optional real-resource fixture, extracted read-only into work/. Relocation
 * mirrors 41BC20..41BC74 on our private test array, never on game memory. */
static int test_marisa_resource(const char *path){
    FILE *f;long size;int i,j,k;uint32_t offset,index;Th09PlayerSnapshot s;
    static const uint32_t callbacks[4][3]={{0,0x441ef0,0x4423d0},{0,0x4415e0,0x441f90},{0,0x442220,0x443300},{0,0x441880,0x443430}};
    fixture();f=fopen(path,"rb");if(!f){puts("FAIL real SHT fixture open");return 1;}
    fseek(f,0,SEEK_END);size=ftell(f);rewind(f);
    if(size!=1484||fread(feature,1,(size_t)size,f)!=(size_t)size){fclose(f);puts("FAIL verified pl01.sht size");return 1;}fclose(f);
    check(feature[2]==2&&feature[3]==0,"actual pl01 has two SHT selectors");
    for(i=0;i<2;i++){
        offset=get32(feature+0x42c+i*8);check(offset>=0x43c&&offset<(uint32_t)size,"actual SHT table offset bounds");
        if(offset<0x43c||offset>=(uint32_t)size)return 1;
        put32(feature+0x42c+i*8,0x700000+offset);
        for(j=0;j<128&&offset+2<=(uint32_t)size;j++,offset+=0x38){
            if(feature[offset+1]&0x80)break;
            check(offset+0x38<=(uint32_t)size,"actual SHT record within file");if(offset+0x38>(uint32_t)size)return 1;
            for(k=0;k<4;k++){
                index=get32(feature+offset+0x28+k*4);check(index<3,"actual Marisa callback index verified table subset");if(index>=3)return 1;
                put32(feature+offset+0x28+k*4,callbacks[k][index]);
            }
        }
        check(j<128,"actual SHT negative terminator found");
    }
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.c1_valid&&s.c1_limited&&s.c1_count==1,"actual Marisa C1 readable and limited");
    check(s.c1_action_duration==45&&s.c1_shots[0].spawn_tick==0&&s.c1_shots[0].type==2&&s.c1_shots[0].damage==1&&!s.c1_shots[0].supported,"actual Marisa custom C1 is not generic prediction");
    c1_active(0,0,2);put32(player+0xc11c+0x480,s.c1_shots[0].template_address);
    putf(player+0xc11c+0x434,320);putf(player+0xc11c+0x2a8,160);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.c1_active_valid&&s.c1_active_count==1&&s.c1_active[0].supported&&s.c1_active[0].damage_ready&&s.c1_active[0].height==320&&s.c1_active[0].y==160,"actual C1 template identity accepts settled Marisa default-hit AABB");
    /* This tests reading a known post-update geometry, not executing Marisa's
     * callback or claiming full live-game character acceptance. */
    printf("player_sensor_real_marisa: %s (%d checks)\n",failures?"FAIL":"PASS",checks);return failures?1:0;
}
static int test_reimu_resource(const char *path,int emit_json){
    FILE *f;long size;int i,j,k;uint32_t offset,index;Th09PlayerSnapshot s;
    static const uint32_t callbacks[4][3]={{0,0x441ef0,0x4423d0},{0,0x4415e0,0x441f90},{0,0x442220,0x443300},{0,0x441880,0x443430}};
    fixture();f=fopen(path,"rb");if(!f){puts("FAIL real Reimu SHT fixture open");return 1;}
    fseek(f,0,SEEK_END);size=ftell(f);rewind(f);
    if(size!=1652||fread(feature,1,(size_t)size,f)!=(size_t)size){fclose(f);puts("FAIL verified pl00.sht size");return 1;}fclose(f);
    check(feature[2]==2&&feature[3]==0,"actual Reimu has two SHT selectors");
    for(i=0;i<2;i++){
        offset=get32(feature+0x42c+i*8);check(offset>=0x43c&&offset<(uint32_t)size,"actual Reimu table offset bounds");
        if(offset<0x43c||offset>=(uint32_t)size)return 1;
        put32(feature+0x42c+i*8,0x700000+offset);
        for(j=0;j<128&&offset+2<=(uint32_t)size;j++,offset+=0x38){
            if(feature[offset+1]&0x80)break;
            check(offset+0x38<=(uint32_t)size,"actual Reimu record within file");if(offset+0x38>(uint32_t)size)return 1;
            for(k=0;k<4;k++){
                index=get32(feature+offset+0x28+k*4);check(index<3,"actual Reimu callback index verified subset");if(index>=3)return 1;
                put32(feature+offset+0x28+k*4,callbacks[k][index]);
            }
        }
        check(j<128,"actual Reimu negative terminator found");
    }
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.c1_valid&&!s.c1_limited&&s.c1_count==4&&s.c1_action_duration==50,"actual Reimu four supported C1 templates");
    for(i=0;i<4;i++)check(s.c1_shots[i].template_index==i+1&&s.c1_shots[i].supported&&s.c1_shots[i].movement_model_version==1&&s.c1_shots[i].linear_until_tick==40&&s.c1_shots[i].damage==30&&s.c1_shots[i].speed==.5f&&s.c1_shots[i].width==48&&s.c1_shots[i].height==48&&!s.c1_shots[i].piercing,"actual Reimu each independent damage30 homing shot");
    if(emit_json&&!failures){reset_lua();Th09PlayerSensorWriteTable(stack,&api,&s);json_value(stack[0]);puts("");}
    else printf("player_sensor_real_reimu: %s (%d checks)\n",failures?"FAIL":"PASS",checks);
    return failures?1:0;
}
static int perf_collect(void){
    LARGE_INTEGER freq,a,b;Th09PlayerSnapshot s;int j,k,ok=1;double ms;
    QueryPerformanceFrequency(&freq);
    for(k=0;k<2;k++){
        fixture();if(k){wave_list(511);for(j=0;j<511;j++)wave(j,j%2?4:1,40,0,32);wave(512,1,12,0,4);
            put32(player+0xb100+511*4,0x600000+0xb0bc);for(j=0;j<128;j++){c1_template(j,j,0);c1_active(j,j,0);}for(j=0;j<256;j++)cloud(j,0,1,50,0,300);}
        read_calls=0;QueryPerformanceCounter(&a);for(j=0;j<10000;j++)ok=Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&ok;QueryPerformanceCounter(&b);
        ms=(double)(b.QuadPart-a.QuadPart)*1000.0/(double)freq.QuadPart/10000;
        printf("native mock-memory collect %s mean_ms=%.6f reads=%d iterations=10000 valid=%d\n",k?"all_fixed_caps":"empty",ms,read_calls/10000,ok);
    }
    return ok?0:1;
}
int main(int argc,char **argv){
    Th09PlayerSnapshot s;int j;Value sv,cv;
    if(argc==3&&!strcmp(argv[1],"--sht"))return test_marisa_resource(argv[2]);
    if(argc==3&&!strcmp(argv[1],"--reimu-sht"))return test_reimu_resource(argv[2],0);
    if(argc==3&&!strcmp(argv[1],"--reimu-fixture"))return test_reimu_resource(argv[2],1);
    if(argc==2&&!strcmp(argv[1],"--perf"))return perf_collect();
    if(argc==5&&!strcmp(argv[1],"--dump")){
        Th09PlayerSensorPlan p;Th09PlayerSensorBuildPlan(strtoul(argv[2],NULL,0),strtoul(argv[3],NULL,0),strtoul(argv[4],NULL,0),&p);
        printf("PATCH %08x ",p.patch_address);hexbytes(p.patch,5);printf("\nCODE %08x ",p.gateway_address);hexbytes(p.code,p.code_length);puts("");return 0;
    }
    fixture();check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s),"empty scene valid");check(s.move_x==1&&s.move_y==1&&s.can_charge&&s.charge_warmup==10,"base speed and warm-up independent of canCharge");
    cloud(0,0,1,20,0,300);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.cloud_count==1&&!s.clouds[0].active&&s.move_x==1,"preactive20 exported not slowing");
    cloud(0,0,1,21,0,300);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.move_x==0.4f,"age21 first slow");
    cloud(1,0,1,299,0,300);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&fabs(s.move_x-0.16f)<1e-7&&s.clouds[1].frames_left==1,"two clouds compound");
    cloud(2,0,1,300,0,300);cloud(3,1,1,50,0,300);cloud(4,0,0,50,0,300);cloud(5,0,2,50,0,300);cloud(6,0,1,50,64,300);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.cloud_count==3&&fabs(s.move_x-0.16f)<1e-7,"expiry / other side / seed / fading / strict radius excluded");
    putf(player+0x1cdc,0.5f);putf(player+0x1ce0,0.25f);putf(player+0x1ce4,1);putf(player+0x1ce8,1);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&fabs(s.move_x-.08f)<1e-7&&fabs(s.move_y-.04f)<1e-7,"persistent axis multipliers survive reset poison fields");
    put32(player,3);putf(player+0x303cc,48);put32(player+0x1b80,4);putf(player+0x3039c,10);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.protection==48&&s.charge_block==50&&!s.can_charge,"protection and recharge timers distinct");
    putf(player+0x303cc,1);putf(player+0x3039c,60);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.protection==1&&s.charge_block==1&&!s.can_charge,"one unit protection raw / uncleared action gate");
    put32(player,4);put32(player+0x1b80,0);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.protection==0&&!s.movement_enabled,"state4 not mislabelled C protection");
    globals[3]=0x800;check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.cut_in&&!s.can_charge,"cut-in freezes action");globals[3]=0;
    bridge_snapshot=s;reset_lua();Th09PlayerSensorWriteTable(stack,&api,&s);sv=field(0,"sensor");cv=field(sv.table,"poisonClouds");
    check(top==1&&max_top<=11&&sv.kind==4,"sensor table stack balanced");check(field(sv.table,"valid").kind==3&&field(sv.table,"valid").number==1,"valid Boolean not number");check(tables[cv.table].count==s.cloud_count,"cloud array length exact");
    test_bridge();
    fixture();for(j=0;j<256;j++)cloud(j,0,1,50,0,300);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.cloud_count==256&&s.move_x>=0,"256 cloud bounded scan no overflow");
    globals[2]=0;check(!Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.valid,"missing container fails closed");
    fixture();put32(player+8,1);check(!Th09PlayerSensorCollect(0x600000,reader,NULL,&s),"wrong-side raw player rejected");
    fixture();put32(player+0x1cdc,0x7fc00000);check(!Th09PlayerSensorCollect(0x600000,reader,NULL,&s),"NaN scale rejected");
    fixture();check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.can_press_z&&!s.c1_action_active&&s.waves_valid&&s.c1_valid&&s.c1_active_valid,"empty followup snapshots valid independently");
    put32(player+0x1b80,4);putf(player+0x3039c,7);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.can_press_z&&!s.can_charge&&s.c1_action_active&&s.c1_action_age==7&&s.c1_action_duration==60,"Z allowed through C1 action but new charge blocked");
    put32(player,3);putf(player+0x303cc,20);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.can_press_z&&s.protection==20,"natural state3 Z window");
    put32(player,4);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.can_press_z,"hit recovery cannot press Z");
    put32(player,5);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.can_press_z,"inactive state cannot press Z");
    fixture();globals[3]=0x800;check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.can_press_z,"cutin closes Z gate");
    fixture();globals[4]=0;check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.can_press_z,"time stop closes Z gate");
    fixture();put32(manager+0xe94c,0xfffffffe);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.can_press_z,"global pause closes Z gate");
    fixture();put32(manager+0x1095c,1);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.can_press_z,"global charge action closes Z gate");
    fixture();put32(player+0x3039c,0x7fc00000);check(!Th09PlayerSensorCollect(0x600000,reader,NULL,&s),"NaN C1 age fails core closed");
    fixture();wave_list(2);wave(0,1,40,0,32);wave(1,4,40,0,32);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.waves_valid&&s.wave_count==2&&s.waves[0].radius==32&&s.waves[1].type==4&&s.waves[1].listed,"actual paired circles and fixed centres exported");
    putf(player+0x1b88,-120);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.waves[0].x==20,"wave centre did not follow moved player");
    wave(512,1,12,2,4);put32(player+0xb100+2*4,0x600000+0xb0bc);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.waves_valid&&s.wave_count==3&&s.waves[2].slot_id==513&&s.waves[2].delay==2&&s.waves[2].listed,"fallback exported once outside normal count");
    put32(player+0xb100+2*4,0);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.wave_count==3&&!s.waves[2].listed,"unlisted fallback not labeled collision-active");
    put32(player+0xb100,0x600001+0x28bc);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.waves_valid&&s.wave_count==0&&s.valid,"unaligned pool pointer invalidates only waves");
    fixture();wave_list(2);wave(0,1,10,0,4);put32(player+0xb104,0x600000+0x28bc);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.waves_valid,"duplicate pool slot rejected");
    fixture();wave_list(1);put32(player+0xb100,0x700000);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.waves_valid,"foreign pool pointer rejected");
    fixture();put32(player+0xc110,512);put32(player+0xc114,0);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.waves_valid,"impossible active count bounded");
    fixture();wave_list(1);wave(0,1,10,0,4);put32(player+0x28bc+8,0x7fc00000);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.waves_valid,"NaN radius cannot become empty safety");
    fixture();wave_list(1);wave(0,1,10,0,0);putf(player+0x28bc+0x10,50);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.waves_valid&&s.wave_count==0,"rectangular type1 not advertised as circle");
    fixture();c1_template(0,0,2);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.c1_valid&&!s.c1_limited&&s.c1_count==1&&s.c1_shots[0].supported&&s.c1_shots[0].width==16&&s.c1_shots[0].piercing,"actual generic C1 full-width template");
    put32(feature+0x440+0x2c,0x441f90);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.c1_valid&&s.c1_limited&&!s.c1_shots[0].supported,"unknown callback is readable but not predictive coverage");
    c1_active(0,0,2);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.c1_active_valid&&s.c1_active_count==1&&s.c1_active[0].supported&&s.c1_active[0].y==240,"custom-moving C1 current AABB observed independently");
    check(s.c1_active[0].damage_ready,"type2 even integer tick can apply damage");
    put32(player+0xc11c+0x45c,3);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.c1_active[0].supported&&!s.c1_active[0].damage_ready,"type2 odd tick geometry is not damage-ready");
    put16(player+0xc11c+0x464,3);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.c1_active[0].damage_ready,"type3 has no type2 odd-tick gate");
    put32(player+0xc11c+0x47c,0x441880);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.c1_active_valid&&!s.c1_active[0].supported,"unknown hit callback cannot promise hit");
    put32(player+0xc11c+0x480,0x700800);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.c1_active_valid&&s.c1_active_count==0,"normal/other-selector shot not borrowed as C1");
    put32(feature+0x434,0xffffffff);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.c1_valid&&s.c1_limited&&!s.c1_active_valid&&s.c1_count==0&&s.valid,"invalid C1 pointer does not invalidate core or invent coverage");
    fixture();c1_template(0,0,0);put32(feature+0x440+0xc,0x7fc00000);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.c1_valid,"NaN SHT dimensions rejected");
    fixture();for(j=0;j<128;j++)c1_template(j,j,0);put16(feature+0x440+128*0x38,0);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.c1_valid&&s.c1_count==0,"unterminated SHT scan hard bounded");
    fixture();c1_template(0,0,0);c1_active(0,0,0);fail_address=0x600000+0xc11c+0x430;
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.c1_valid&&!s.c1_active_valid&&s.c1_active_count==0,"partial active-shot read invalidates its own snapshot");
    fixture();reimu_template(0);reimu_template(1);reimu_active();
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.character==0&&s.c1_valid&&!s.c1_limited&&s.c1_count==2&&s.c1_shots[0].supported,"verified Reimu callback supported only as its known model");
    check(s.c1_shots[0].movement_model_version==1&&s.c1_shots[0].linear_until_tick==40&&s.c1_shots[1].template_index==2,"Reimu phase boundary and distinct template identities");
    check(s.c1_active_count==1&&s.c1_active[0].supported&&s.c1_active[0].movement_model_version==1&&s.c1_active[0].speed==.5f&&s.c1_active[0].age_integer==40&&s.c1_active[0].previous_age_integer==39,"actual Reimu speed and integer clock read");
    reset_lua();Th09PlayerSensorWriteTable(stack,&api,&s);sv=field(field(0,"sensor").table,"c1Profile");
    check(field(sv.table,"character").number==0&&field(sv.table,"damageModelVersion").number==1&&field(sv.table,"movementModelVersion").number==1,"Lua precise Reimu model contract");
    cv=field(sv.table,"shots");cv=tables[cv.table].values[1];
    check(field(cv.table,"templateIndex").number==2&&field(cv.table,"linearUntilTick").number==40&&field(cv.table,"movementModelVersion").number==1,"Lua template identity and movement model fields");
    cv=field(sv.table,"activeShots");cv=tables[cv.table].values[0];
    check(field(cv.table,"speed").number==.5&&field(cv.table,"ageInteger").number==40&&field(cv.table,"previousAgeInteger").number==39,"Lua active Reimu motion fields");
    put32(boards+0x1c,1);check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.character==1&&s.c1_limited&&!s.c1_shots[0].supported,"other character cannot borrow Reimu callback contract");
    put32(boards+0x1c,0);put32(player+0xc11c+0x474,0x4415e1);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.c1_active_count==1&&!s.c1_active[0].supported&&!s.c1_active[0].movement_model_version,"changed active callback fails precise model closed");
    reimu_active();putf(player+0xc11c+0x44c,0);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.c1_active[0].supported,"zero active speed cannot normalize future trajectory");
    fail_address=0x4a7db0;check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.character==-1&&!s.c1_shots[0].supported,"unknown character closes only precise C1 model");
    /* 3.0 step 1: opponent gauge is an independent fail-closed sub-snapshot. */
    fixture();check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.valid&&!s.opponent.valid,"no opponent board leaves own snapshot valid");
    opponent_fixture(0,150,200,10);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.valid&&s.opponent.valid&&s.opponent.charge_current==150&&s.opponent.charge_max==200&&s.opponent.charge_speed==10&&s.opponent.life==7&&s.opponent.combo==12&&s.opponent.spell_point==345678,"opponent gauge exported read-only");
    opponent_fixture(3,0,300,10);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.opponent.state==3&&s.opponent.protection==33,"opponent state3 protection exported");
    opponent_fixture(9,0,200,10);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.valid&&!s.opponent.valid,"impossible opponent state rejects only sub-snapshot");
    opponent_fixture(0,0,401,10);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.valid&&!s.opponent.valid,"opponent gauge above verified range rejected");
    opponent_fixture(0,0,200,120);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.valid&&!s.opponent.valid,"opponent charge speed outside verified range rejected");
    opponent_fixture(0,0x7fc00000,200,10);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.valid&&!s.opponent.valid,"NaN opponent gauge rejected");
    opponent_fixture(0,0,200,10);put32(boards+0x38,0x500001);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.valid&&!s.opponent.valid,"unaligned opponent player pointer rejected");
    opponent_fixture(0,0,200,10);fail_address=0x500000+0x30384;
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.valid&&!s.opponent.valid,"failed opponent read cannot clear own validity");
    fail_address=0;
    opponent_fixture(0,120,250,10);Th09PlayerSensorCollect(0x600000,reader,NULL,&s);
    reset_lua();Th09PlayerSensorWriteTable(stack,&api,&s);sv=field(0,"sensor");cv=field(sv.table,"opponent");
    check(field(sv.table,"opponentApiVersion").number==1&&field(cv.table,"valid").kind==3&&field(cv.table,"valid").number==1,"opponent API version and Boolean exported");
    check(field(cv.table,"chargeMax").number==250&&field(cv.table,"chargeCurrent").number==120&&field(cv.table,"spellPoint").number==345678,"opponent gauge values exported to Lua");
    s.opponent.valid=0;reset_lua();Th09PlayerSensorWriteTable(stack,&api,&s);sv=field(0,"sensor");cv=field(sv.table,"opponent");
    check(!field(cv.table,"valid").number&&field(cv.table,"chargeMax").number==0,"invalid opponent never reported as an energy level");
    fixture();wave_list(511);for(j=0;j<511;j++)wave(j,j%2?4:1,40,0,32);wave(512,1,12,0,4);put32(player+0xb100+511*4,0x600000+0xb0bc);
    for(j=0;j<128;j++){c1_template(j,j,0);c1_active(j,j,0);}for(j=0;j<256;j++)cloud(j,0,1,50,0,300);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.wave_count==512&&s.c1_count==128&&s.c1_active_count==128&&s.cloud_count==256,"all native collections reach only fixed bounds");
    check(read_calls<1500,"native collection read calls bounded");
    reset_lua();Th09PlayerSensorWriteTable(stack,&api,&s);sv=field(0,"sensor");
    check(top==1&&max_top<=11,"maximal followup table stack balanced");
    check(field(sv.table,"followupApiVersion").number==1&&field(sv.table,"canPressZ").kind==3,"followup API and Z Boolean exported");
    check(tables[field(sv.table,"commonWaves").table].count==512,"wave array count exact");
    cv=field(sv.table,"c1Profile");check(tables[field(cv.table,"shots").table].count==128&&tables[field(cv.table,"activeShots").table].count==128,"C1 arrays count exact");
    s.valid=0;reset_lua();Th09PlayerSensorWriteTable(stack,&api,&s);sv=field(0,"sensor");
    check(!field(sv.table,"canPressZ").number&&!field(sv.table,"commonWavesValid").number&&tables[field(sv.table,"commonWaves").table].count==0,"invalid core cannot retain followup permissions/effects");
    printf("player_sensor_selftest: %s (%d checks)\n",failures?"FAIL":"PASS",checks);return failures?1:0;
}

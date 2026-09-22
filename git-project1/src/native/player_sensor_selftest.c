/* No game launch, module load, injection or foreign process access. */
#include "player_sensor.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
static int failures,checks;
static void check(int ok,const char *what){checks++;if(!ok){failures++;printf("FAIL %s\n",what);}}
static void put32(unsigned char *p,uint32_t v){memcpy(p,&v,4);}
static void putf(unsigned char *p,float v){memcpy(p,&v,4);}
static unsigned char player[0x30454],feature[0x2c],manager[0x10960],ex[0x4c*256+0x1c],exfeature[256*4];
static uint32_t globals[5];
static BOOL reader(uint32_t a,void *out,size_t n,void *ignored){
    unsigned char *p=NULL;size_t available=0;(void)ignored;
    if(a>=0x600000 && a<0x600000+sizeof(player)){p=player+a-0x600000;available=sizeof(player)-(a-0x600000);}
    if(a>=0x700000 && a<0x700000+sizeof(feature)){p=feature+a-0x700000;available=sizeof(feature)-(a-0x700000);}
    if(a>=0x800000 && a<0x800000+sizeof(manager)){p=manager+a-0x800000;available=sizeof(manager)-(a-0x800000);}
    if(a>=0x900000 && a<0x900000+sizeof(ex)){p=ex+a-0x900000;available=sizeof(ex)-(a-0x900000);}
    if(a>=0xa00000 && a<0xa00000+sizeof(exfeature)){p=exfeature+a-0xa00000;available=sizeof(exfeature)-(a-0xa00000);}
    if(a==0x4a7d94){p=(unsigned char *)&globals[0];available=4;}
    if(a==0x4a7e38){p=(unsigned char *)&globals[1];available=4;}
    if(a==0x4a7e3c){p=(unsigned char *)&globals[2];available=4;}
    if(a==0x4a7ec4){p=(unsigned char *)&globals[3];available=4;}
    if(a==0x4b36b8){p=(unsigned char *)&globals[4];available=4;}
    if(!p||available<n)return FALSE;memcpy(out,p,n);return TRUE;
}
static void fixture(void){
    memset(player,0,sizeof(player));memset(feature,0,sizeof(feature));memset(ex,0,sizeof(ex));memset(exfeature,0,sizeof(exfeature));memset(manager,0,sizeof(manager));
    globals[0]=0x600000;globals[1]=0x800000;globals[2]=0x900000;globals[3]=0;globals[4]=0x3f800000;
    put32(player+0x30338,0x700000);putf(player+0x1cdc,1);putf(player+0x1ce0,1);
    putf(feature+0x14,4.1f);putf(feature+0x18,2.2f);putf(feature+0x28,60);
    put32(manager+0xe94c,0xffffffff);putf(player+0x1b88,0);putf(player+0x1b8c,300);
}
static void cloud(int j,int side,int local,float age,float x,float y){
    unsigned char *e=ex+0x1c+j*0x4c;
    put32(e+4,side);put32(e+0xc,1);putf(e+0x14,age);put32(e+0x18,(uint32_t)(int)age);
    putf(e+0x20,x);putf(e+0x24,y);put32(e+0x34,0xa00000+j*4);put32(exfeature+j*4,local);put32(e+0x40,0x44a330);
}
typedef struct {int kind;double number;const char *string;int table;} Value;
typedef struct {int count;Value keys[32],values[32];} Table;
static Table tables[300];static Value stack[24];static int top,table_count,max_top;
static Value val(int kind){Value v;memset(&v,0,sizeof(v));v.kind=kind;return v;}
static void push(Value v){check(top<24,"mock Lua stack bound");stack[top++]=v;if(top>max_top)max_top=top;}
static void __cdecl mock_string(void *L,const char *k){Value v=val(1);check(L==stack,"Lua pointer preserved");v.string=k;push(v);}
static void __cdecl mock_number(void *L,double n){Value v=val(2);(void)L;v.number=n;push(v);}
static void __cdecl mock_bool(void *L,int n){Value v=val(3);(void)L;v.number=!!n;push(v);}
static void __cdecl mock_table(void *L,int array,int record){Value v=val(4);(void)L;(void)array;(void)record;check(table_count<300,"Lua mock table pool");v.table=table_count++;push(v);}
static void __cdecl mock_set(void *L,int index){int target=top+index;Table *t;(void)L;check(target>=0&&stack[target].kind==4,"settable has parent table");t=&tables[stack[target].table];check(t->count<32,"mock table capacity");t->keys[t->count]=stack[top-2];t->values[t->count++]=stack[top-1];top-=2;}
static const Th09PlayerSensorLuaApi api={mock_string,mock_number,mock_bool,mock_table,mock_set};
static Value field(int table,const char *key){int i;Table *t=&tables[table];for(i=t->count-1;i>=0;i--)if(t->keys[i].kind==1&&!strcmp(t->keys[i].string,key))return t->values[i];return val(0);}
static void reset_lua(void){memset(tables,0,sizeof(tables));top=table_count=max_top=0;mock_table(stack,0,16);}
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
int main(int argc,char **argv){
    Th09PlayerSnapshot s;int j;Value sv,cv;
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
    check(top==1&&max_top<=9&&sv.kind==4,"sensor table stack balanced");check(field(sv.table,"valid").kind==3&&field(sv.table,"valid").number==1,"valid Boolean not number");check(tables[cv.table].count==s.cloud_count,"cloud array length exact");
    test_bridge();
    fixture();for(j=0;j<256;j++)cloud(j,0,1,50,0,300);
    check(Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&s.cloud_count==256&&s.move_x>=0,"256 cloud bounded scan no overflow");
    globals[2]=0;check(!Th09PlayerSensorCollect(0x600000,reader,NULL,&s)&&!s.valid,"missing container fails closed");
    fixture();put32(player+8,1);check(!Th09PlayerSensorCollect(0x600000,reader,NULL,&s),"wrong-side raw player rejected");
    fixture();put32(player+0x1cdc,0x7fc00000);check(!Th09PlayerSensorCollect(0x600000,reader,NULL,&s),"NaN scale rejected");
    printf("player_sensor_selftest: %s (%d checks)\n",failures?"FAIL":"PASS",checks);return failures?1:0;
}

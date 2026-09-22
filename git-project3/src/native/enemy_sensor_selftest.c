/* Synthetic memory only. No game/module/process is opened or started. */
#include "enemy_sensor.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int checks,failures;
static unsigned char object[12],enemy[0x5430],boards[0x70];
static uint32_t raw,fail_address,tear_address;static int tear_reads;
static void put32(unsigned char *p,uint32_t v){memcpy(p,&v,4);}
static void putf(unsigned char *p,float v){memcpy(p,&v,4);}
static void check(int ok,const char *name){checks++;if(!ok){failures++;printf("FAIL %s\n",name);}}
static BOOL reader(uint32_t a,void *out,size_t n,void *ctx){unsigned char *p=NULL;size_t room=0;(void)ctx;
    if(a==fail_address)return FALSE;
    if(a>=0x600000&&a<0x600000+sizeof(object)){p=object+a-0x600000;room=sizeof(object)-(a-0x600000);}
    if(a>=raw&&a<raw+sizeof(enemy)){p=enemy+a-raw;room=sizeof(enemy)-(a-raw);}
    if(a>=0x4a7d94&&a<0x4a7d94+sizeof(boards)){p=boards+a-0x4a7d94;room=sizeof(boards)-(a-0x4a7d94);}
    if(!p||n>room)return FALSE;memcpy(out,p,n);
    if(a==tear_address&&++tear_reads>1)((unsigned char *)out)[0]^=1;
    return TRUE;
}
static void fixture(int side,int slot){memset(object,0,sizeof(object));memset(enemy,0,sizeof(enemy));memset(boards,0,sizeof(boards));
    raw=(side==1?0x700000:0xb00000)+0x5758u+(uint32_t)slot*0x5430u;
    put32(boards+0xc+(side-1)*0x38,side==1?0x700000:0xb00000);
    put32(object,0x10060000);put32(object+4,123456789);put32(object+8,raw);
    put32(enemy+0x2e48,20);put32(enemy+0x337c,0x49);putf(enemy+0x2dd4,12);putf(enemy+0x2dd8,250);
    putf(enemy+0x2dbc,16);putf(enemy+0x2dc0,24);fail_address=0;tear_address=0;tear_reads=0;
}
static int top,api_checks,json_mode,json_first;static const char *key;static double exported_hp,exported_id;static int exported_valid;
static void __cdecl push_string(void *L,const char *s){(void)L;top++;key=s;}
static void json_key(void){if(!json_mode)return;if(!json_first)putchar(',');json_first=0;printf("\"%s\":",key);}
static void __cdecl push_number(void *L,double n){(void)L;top++;if(!strcmp(key,"hp"))exported_hp=n;if(!strcmp(key,"id"))exported_id=n;if(json_mode){json_key();printf("%.9g",n);}}
static void __cdecl push_boolean(void *L,int n){(void)L;top++;if(!strcmp(key,"valid"))exported_valid=n;if(json_mode){json_key();printf("%s",n?"true":"false");}}
static void __cdecl create_table(void *L,int n,int r){(void)L;(void)n;(void)r;top++;}
static void __cdecl set_table(void *L,int n){(void)L;check(n==-3&&top>=3,"Lua table stack index");top-=2;api_checks++;}
static void table_test(const Th09EnemySnapshot *s){Th09PlayerSensorLuaApi a;memset(&a,0,sizeof(a));
    a.push_string=push_string;a.push_number=push_number;a.push_boolean=push_boolean;a.create_table=create_table;a.set_table=set_table;
    top=1;api_checks=0;exported_hp=-999;exported_id=-999;exported_valid=-1;
    Th09EnemySensorWriteTable(NULL,&a,s);
    check(top==1&&api_checks==21,"table writer balances stack");
    check(exported_valid==s->valid&&exported_hp==s->hp&&exported_id==(double)s->id,"table preserves ID HP validity");
}
int main(int argc,char **argv){Th09EnemySnapshot s;Th09EnemySensorPlan plan;int side,slot,i;
    unsigned char before[sizeof(enemy)],obefore[sizeof(object)];
    if(argc==2&&!strcmp(argv[1],"--fixture")){
        fixture(2,0);put32(enemy+0x337c,0x400049);put32(enemy+0x3380,0x1040);
        if(!Th09EnemySensorCollect(0x600000,reader,NULL,&s))return 1;
        json_mode=json_first=1;putchar('{');table_test(&s);puts("}");return failures?1:0;
    }
    if(argc==5&&!strcmp(argv[1],"--dump")){
        if(!Th09EnemySensorBuildPlan(strtoul(argv[2],NULL,0),strtoul(argv[3],NULL,0),strtoul(argv[4],NULL,0),&plan))return 2;
        printf("PATCH %08lx ",(unsigned long)plan.patch_address);for(i=0;i<5;i++)printf("%02x",plan.patch[i]);
        printf("\nCODE %08lx ",(unsigned long)plan.gateway_address);for(i=0;i<(int)plan.code_length;i++)printf("%02x",plan.code[i]);puts("");return 0;
    }
    for(side=1;side<=2;side++)for(slot=0;slot<128;slot++){
        fixture(side,slot);memcpy(before,enemy,sizeof(enemy));memcpy(obefore,object,sizeof(object));
        check(Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&s.valid,"pool slot accepted");
        check(s.side==side&&s.slot_index==slot+1&&s.id==123456789&&s.hp==20,"same object ID/side/slot/HP");
        check(s.blocks_shots&&s.damageable&&s.shot_can_ignite&&s.shot_damage_divisor==1,"ordinary direct-shot gates");
        check(!memcmp(before,enemy,sizeof(enemy))&&!memcmp(obefore,object,sizeof(object)),"no raw or managed writes");
    }
    fixture(1,0);put32(enemy+0x337c,0x400049);put32(enemy+0x3380,0x40);
    check(Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&s.damageable&&s.blocks_shots&&s.shot_damage_divisor==4&&!s.shot_can_ignite,"unactivated spirit loses HP but cannot seed");
    put32(enemy+0x3380,0x1040);
    check(Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&s.shot_damage_divisor==2&&s.shot_can_ignite,"activated spirit divisor and seed");
    put32(enemy+0x53b0,1);
    check(Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&s.blocks_shots&&!s.damageable&&!s.shot_can_ignite,"protection consumes shot without credible kill");
    fixture(2,127);put32(enemy+0x337c,0x41);
    check(Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&s.blocks_shots&&!s.damageable,"HP-write gate off still consumes shot");
    put32(enemy+0x337c,0x19);
    check(Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&!s.blocks_shots&&!s.damageable,"pseudo enemy skips shots");
    put32(enemy+0x337c,9);
    check(Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&!s.blocks_shots,"shot collision flag off");
    fixture(1,0);put32(enemy+0x3380,8);
    check(Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&!s.damageable&&!s.shot_can_ignite,"death deferred is unknown for kill");
    fixture(1,0);putf(enemy+0x2dc8,40);putf(enemy+0x2dcc,60);
    check(Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&s.secondary_blocks_shots&&s.secondary_width==40&&
        s.secondary_height==60&&!s.damageable&&!s.shot_can_ignite,"secondary AABB consumes but cannot claim simple HP damage");
    fixture(1,0);put32(enemy+0x337c,0x80000049);
    check(Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&!s.shot_can_ignite,"boss not a chain seed");
    fixture(1,0);put32(enemy+0x337c,0x2449);
    check(Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&!s.shot_can_ignite,"Lily not a chain seed");
    fixture(1,0);put32(enemy+0x2e48,0xfffffffb);
    check(Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&s.hp==-5&&!s.damageable,"signed HP is not clamped to alive");table_test(&s);
    fixture(1,0);put32(object+8,raw+4);
    check(!Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&!s.valid&&!s.id,"unowned unaligned raw slot rejected");
    fixture(1,0);put32(boards+0x44,0x700000);
    check(!Th09EnemySensorCollect(0x600000,reader,NULL,&s),"ambiguous board ownership rejected");
    fixture(1,0);put32(object+4,0);
    check(!Th09EnemySensorCollect(0x600000,reader,NULL,&s),"zero ID rejected");
    fixture(1,0);put32(enemy+0x337c,0x149);
    check(!Th09EnemySensorCollect(0x600000,reader,NULL,&s),"stale disabled object rejected");
    fixture(1,0);put32(enemy+0x337c,0x4d);
    check(!Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&!s.valid,"segmented extra hit bodies close precise budget instead of missing blockers");
    fixture(1,0);put32(enemy+0x2e48,1000001);
    check(!Th09EnemySensorCollect(0x600000,reader,NULL,&s),"unbounded HP rejected");
    fixture(1,0);put32(enemy+0x2dd4,0x7fc00000);
    check(!Th09EnemySensorCollect(0x600000,reader,NULL,&s),"NaN collision geometry rejected");
    fixture(1,0);fail_address=raw+0x2e48;
    check(!Th09EnemySensorCollect(0x600000,reader,NULL,&s)&&!s.id&&!s.hp&&!s.damageable,"failed HP read yields unknown not zero-HP enemy");table_test(&s);
    fixture(1,0);tear_address=0x600000;
    check(!Th09EnemySensorCollect(0x600000,reader,NULL,&s),"changed managed ID rejected");
    fixture(1,0);tear_address=raw+0x337c;
    check(!Th09EnemySensorCollect(0x600000,reader,NULL,&s),"changed status rejected");
    check(!Th09EnemySensorBuildPlan(0,1,1,&plan),"null module plan rejected");
    printf("%s: %d enemy combat collection/table checks; no game process or writes.\n",failures?"FAIL":"PASS",checks);
    return failures?1:0;
}

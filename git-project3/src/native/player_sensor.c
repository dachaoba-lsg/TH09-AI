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
static int i16(const unsigned char *p){short v;memcpy(&v,p,2);return v;}
static unsigned int u16(const unsigned char *p){unsigned short v;memcpy(&v,p,2);return v;}
static float f32(const unsigned char *p){float v;memcpy(&v,p,4);return v;}
static BOOL finite(float f){uint32_t v;memcpy(&v,&f,4);return (v&0x7f800000u)!=0x7f800000u;}
static float positive(float f){return f>0.0f?f:0.0f;}
static BOOL bounded(float f,float limit){return finite(f)&&f>=-limit&&f<=limit;}
static BOOL rpm(uint32_t a,void *p,size_t n,void *context){
    SIZE_T got=0;(void)context;
    return a>=0x10000u && a<=0xffffffffu-n &&
        ReadProcessMemory(GetCurrentProcess(),(void *)(uintptr_t)a,p,n,&got) && got==n;
}

/* Each sub-snapshot can fail independently. Never turn an unreadable effect
 * pool or unknown SHT callback into an empty/safe scene or a promised kill. */
static BOOL add_wave(uint32_t raw,uint32_t address,int listed,Th09PlayerSensorReadFn rd,void *ctx,Th09PlayerSnapshot *s){
    unsigned char data[0x44];Th09CommonWave *w;int type,life,delay,id;
    if(address==raw+0xb0bc)id=513;
    else{
        if(address<raw+0x28bc||address>=raw+0xb0bc||(address-(raw+0x28bc))%0x44)return FALSE;
        id=(int)((address-(raw+0x28bc))/0x44)+1;
    }
    if(!rd(address,data,sizeof(data),ctx))return FALSE;
    if(data[0x3c]>1)return FALSE;
    if(!data[0x3c])return TRUE;
    type=i32(data+0x38);if(type<0||type>4)return FALSE;
    if(type!=1&&type!=4)return TRUE;
    life=i32(data+0x24);delay=i32(data+0x40);
    if(life<=0||life>36000||delay<0||delay>36000||
       !bounded(f32(data),1000000)||!bounded(f32(data+4),1000000)||
       !bounded(f32(data+8),100000)||!bounded(f32(data+0xc),10000))return FALSE;
    /* Non-circular type1/4 objects exist. Their size fields are not a radius;
     * export only genuine circles, with no invented circular envelope. */
    if(f32(data+8)<=0 && (f32(data+0x10)!=0||f32(data+0x14)!=0))return TRUE;
    if(f32(data+8)<0||s->wave_count>=TH09_PLAYER_SENSOR_MAX_WAVES)return FALSE;
    w=&s->waves[s->wave_count++];w->slot_id=id;w->type=type;
    w->x=f32(data);w->y=f32(data+4);w->radius=f32(data+8);w->growth=f32(data+0xc);
    w->life=life;w->delay=delay;w->enabled=1;w->listed=listed;
    return TRUE;
}
static BOOL collect_waves(uint32_t raw,Th09PlayerSensorReadFn rd,void *ctx,Th09PlayerSnapshot *s){
    unsigned char counts[8],again[8],pointers[512*4],verify[512*4],fallback[0x44];
    unsigned char seen[512];uint32_t address;int count,free_count,j,listed;
    if(!rd(raw+0xc110,counts,sizeof(counts),ctx))return FALSE;
    count=i32(counts);free_count=i32(counts+4);
    /* The allocator reserves one pool entry and uses the separate fallback
     * when free_count<=1. count excludes that fallback. */
    if(count<0||count>511||free_count<1||free_count>512||count+free_count!=512)return FALSE;
    if(!rd(raw+0xb100,pointers,(size_t)(count+1)*4,ctx))return FALSE;
    memset(seen,0,sizeof(seen));
    for(j=0;j<count;j++){
        unsigned int index;
        address=u32(pointers+j*4);
        if(address<raw+0x28bc||address>=raw+0xb0bc||(address-(raw+0x28bc))%0x44)return FALSE;
        index=(address-(raw+0x28bc))/0x44;
        if(seen[index])return FALSE;seen[index]=1;
        if(!add_wave(raw,address,1,rd,ctx,s))return FALSE;
    }
    address=u32(pointers+count*4);
    if(address && address!=raw+0xb0bc)return FALSE;
    listed=address==raw+0xb0bc;
    if(!rd(raw+0xb0bc,fallback,sizeof(fallback),ctx))return FALSE;
    if(fallback[0x3c]>1)return FALSE;
    if(fallback[0x3c]&&!add_wave(raw,raw+0xb0bc,listed,rd,ctx,s))return FALSE;
    if(!rd(raw+0xc110,again,sizeof(again),ctx)||memcmp(counts,again,sizeof(counts))||
       !rd(raw+0xb100,verify,(size_t)(count+1)*4,ctx)||memcmp(pointers,verify,(size_t)(count+1)*4))return FALSE;
    return TRUE;
}
static BOOL collect_c1(uint32_t feature,Th09PlayerSensorReadFn rd,void *ctx,Th09PlayerSnapshot *s){
    unsigned char head[4],pointer[4],record[0x38];uint32_t start,address;int j;
    if(feature<0x10000||feature>0xffeff000u||!rd(feature,head,4,ctx)||
       u16(head+2)<2||u16(head+2)>64||!rd(feature+0x434,pointer,4,ctx))return FALSE;
    start=u32(pointer);
    if(start<feature+0x43c||start>feature+0x100000-0x38||start%4)return FALSE;
    for(j=0;j<=TH09_PLAYER_SENSOR_MAX_C1_SHOTS;j++){
        Th09C1Shot *shot;int tick;
        address=start+(uint32_t)j*0x38;
        if(address>feature+0x100000-0x38||!rd(address,record,2,ctx))return FALSE;
        tick=i16(record);if(tick<0)return TRUE;
        if(j==TH09_PLAYER_SENSOR_MAX_C1_SHOTS||tick>3600||!rd(address,record,sizeof(record),ctx))return FALSE;
        if(!bounded(f32(record+4),4096)||!bounded(f32(record+8),4096)||
           !bounded(f32(record+0xc),4096)||!bounded(f32(record+0x10),4096)||
           !bounded(f32(record+0x14),1000)||!bounded(f32(record+0x18),1000))return FALSE;
        shot=&s->c1_shots[s->c1_count++];shot->template_address=address;
        shot->spawn_tick=tick;shot->offset_x=f32(record+4);shot->offset_y=f32(record+8);
        shot->width=f32(record+0xc);shot->height=f32(record+0x10);
        shot->angle=f32(record+0x14);shot->speed=f32(record+0x18);
        shot->damage=i16(record+0x1c);shot->type=i16(record+0x22);
        shot->piercing=shot->type==2||shot->type==3;
        shot->supported=!u32(record+0x28)&&!u32(record+0x2c)&&!u32(record+0x30)&&!u32(record+0x34)
            &&shot->type>=0&&shot->type<=3&&shot->damage>0&&shot->width>0&&shot->height>0;
        if(!shot->supported)s->c1_limited=1;
    }
    return FALSE;
}
static BOOL collect_c1_active(uint32_t raw,Th09PlayerSensorReadFn rd,void *ctx,Th09PlayerSnapshot *s){
    unsigned char status[2],position[8],tail[0x58];int slot,j;uint32_t base,template_address;
    if(!s->c1_valid)return FALSE;
    if(!s->c1_count)return TRUE;
    for(slot=0;slot<128;slot++){
        Th09C1ActiveShot *shot;
        base=raw+0xc11c+(uint32_t)slot*0x484;
        if(!rd(base+0x462,status,2,ctx))return FALSE;
        if(u16(status)!=1)continue;
        if(!rd(base+0x430,tail,0x54,ctx))return FALSE;
        template_address=u32(tail+0x50);
        for(j=0;j<s->c1_count;j++)if(s->c1_shots[j].template_address==template_address)break;
        if(j==s->c1_count)continue; /* normal shot / another selector */
        if(!rd(base+0x2a4,position,sizeof(position),ctx)||
           !bounded(f32(position),1000000)||!bounded(f32(position+4),1000000)||
           !bounded(f32(tail),4096)||!bounded(f32(tail+4),4096)||
           !bounded(f32(tail+0xc),10000)||!bounded(f32(tail+0x10),10000)||
           !bounded(f32(tail+0x28),1000000))return FALSE;
        if(u16(tail+0x32)!=1)return FALSE; /* snapshot changed during read */
        shot=&s->c1_active[s->c1_active_count++];shot->slot_id=slot+1;
        shot->x=f32(position);shot->y=f32(position+4);shot->width=f32(tail);shot->height=f32(tail+4);
        shot->vx=f32(tail+0xc);shot->vy=f32(tail+0x10);shot->age=f32(tail+0x28);
        shot->type=i16(tail+0x34);shot->damage=i16(tail+0x30);
        shot->piercing=shot->type==2||shot->type==3;
        /* Current AABB is authoritative even for custom movement. An unknown
         * hit callback can reject it, so never mark that geometry supported. */
        shot->supported=!u32(tail+0x4c)&&shot->type>=0&&shot->type<=3&&shot->damage>0&&shot->width>0&&shot->height>0;
        /* 41FDAA..41FDC1 skips type-2 damage on odd integer shot-timer ticks.
         * Geometry is still observable then, but is not a current damage hit. */
        shot->damage_ready=shot->type!=2 || (u32(tail+0x2c)&1u)==0;
    }
    return TRUE;
}

/* 3.0 step 1: opponent gauge, read-only. The two boards live back to back at
 * 0x4a7d94 (board[0].player, board[1].player); the own side comes from the
 * hooked player. Every field is range-checked; any failure only clears the
 * opponent sub-snapshot and never touches the own snapshot or game memory. */
static void collect_opponent(uint32_t side,Th09PlayerSensorReadFn rd,void *ctx,Th09PlayerSnapshot *s){
    unsigned char tiny[4],head[4],feature_ptr[4],gauges[8];
    uint32_t ptr,feature;
    float speed,current,maximum;
    Th09OpponentSnapshot *o=&s->opponent;
    memset(o,0,sizeof(*o));
    if(side>1)return;
    if(!rd(0x4a7d94u+(1u-side)*0x38u,tiny,4,ctx))return;
    ptr=u32(tiny);
    if(ptr<0x10000u||ptr>0xfffcfbacu)return;
    if(!rd(ptr,head,4,ctx))return;
    if(i32(head)<0||i32(head)>5)return;
    if(!rd(ptr+0x30338,feature_ptr,4,ctx))return;
    feature=u32(feature_ptr);
    if(feature<0x10000u||feature>0xfffcfbacu)return;
    if(!rd(feature+0x24,tiny,4,ctx))return;
    speed=f32(tiny);
    if(!finite(speed)||speed<0||speed>=100)return;
    if(!rd(ptr+0x30384,gauges,sizeof(gauges),ctx))return;
    current=f32(gauges);maximum=f32(gauges+4);
    if(!finite(current)||!finite(maximum)||current<0||maximum<0||
       current>400.001f||maximum>400.001f)return;
    o->state=i32(head);
    o->charge_current=current;o->charge_max=maximum;o->charge_speed=speed;
    /* Same offsets as the own snapshot: life, combo, spell point, protection. */
    if(!rd(ptr+0xa8,tiny,4,ctx))return;
    if(i32(tiny)<0||i32(tiny)>1000000)return;
    o->life=i32(tiny);
    if(!rd(ptr+0x30414,gauges,0xc,ctx))return;
    if(u32(gauges)>1000000u||u32(gauges+8)>2000000000u)return;
    o->combo=u32(gauges);o->spell_point=u32(gauges+8);
    if(o->state==3){
        if(!rd(ptr+0x303cc,tiny,4,ctx))return;
        o->protection=positive(f32(tiny));
        if(!finite(o->protection)||o->protection>3600)return;
    }
    o->valid=1;
}

BOOL Th09PlayerSensorCollect(uint32_t raw,Th09PlayerSensorReadFn rd,void *ctx,Th09PlayerSnapshot *s){
    unsigned char head[0x10],pos[0x178],tail[0x98],feature[0x2c];
    unsigned char slots[256*0x4c],tiny[4];
    uint32_t side,ptr,flags,global_flags,manager,container;
    int pause_gate,charge_gate,j,local,age_int;
    float x,y,action_age,duration,warmup,age,poison=1.0f;
    if(!s)return FALSE;
    memset(s,0,sizeof(*s));
    if(!rd || raw<0x10000||raw>0xfffcfbacu || !rd(raw,head,sizeof(head),ctx) ||
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
       !finite(duration)||duration<0||duration>3600||!bounded(action_age,1000000)||
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
    s->can_press_z=(s->state==0||s->state==3)&&!s->cut_in&&s->time_scale>0&&
        pause_gate<0&&pause_gate!=-2&&charge_gate==0;
    s->c1_action_active=(flags&4)!=0;
    s->c1_action_age=action_age;s->c1_action_duration=duration;
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
    s->waves_valid=collect_waves(raw,rd,ctx,s);
    if(!s->waves_valid)s->wave_count=0;
    s->c1_valid=collect_c1(ptr,rd,ctx,s);
    if(!s->c1_valid){s->c1_count=0;s->c1_limited=1;}
    s->c1_active_valid=collect_c1_active(raw,rd,ctx,s);
    if(!s->c1_active_valid)s->c1_active_count=0;
    collect_opponent(side,rd,ctx,s);
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
     * host registry/global state. The C1 profile adds one nested table level. */
    a->push_string(L,"sensor");a->create_table(L,0,28);
    number(L,a,"apiVersion",TH09_PLAYER_SENSOR_API);boolean(L,a,"valid",s->valid);
    number(L,a,"followupApiVersion",TH09_PLAYER_FOLLOWUP_API);
    boolean(L,a,"canPressZ",s->valid&&s->can_press_z);
    boolean(L,a,"c1ActionActive",s->valid&&s->c1_action_active);
    number(L,a,"c1ActionAge",s->valid?s->c1_action_age:0);
    number(L,a,"c1ActionDuration",s->valid?s->c1_action_duration:0);
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
    a->set_table(L,-3);
    boolean(L,a,"commonWavesValid",s->valid&&s->waves_valid);
    a->push_string(L,"commonWaves");a->create_table(L,s->valid&&s->waves_valid?s->wave_count:0,0);
    if(s->valid&&s->waves_valid)for(i=0;i<s->wave_count;i++){
        const Th09CommonWave *w=&s->waves[i];
        a->push_number(L,i+1);a->create_table(L,0,10);
        number(L,a,"slotId",w->slot_id);number(L,a,"type",w->type);
        number(L,a,"x",w->x);number(L,a,"y",w->y);number(L,a,"radius",w->radius);number(L,a,"growth",w->growth);
        number(L,a,"life",w->life);number(L,a,"delay",w->delay);
        boolean(L,a,"enabled",w->enabled);boolean(L,a,"listed",w->listed);
        a->set_table(L,-3);
    }
    a->set_table(L,-3);
    a->push_string(L,"c1Profile");a->create_table(L,0,6);
    boolean(L,a,"valid",s->valid&&s->c1_valid);boolean(L,a,"limited",!s->valid||s->c1_limited);
    number(L,a,"actionDuration",s->valid?s->c1_action_duration:0);
    a->push_string(L,"shots");a->create_table(L,s->valid&&s->c1_valid?s->c1_count:0,0);
    if(s->valid&&s->c1_valid)for(i=0;i<s->c1_count;i++){
        const Th09C1Shot *v=&s->c1_shots[i];
        a->push_number(L,i+1);a->create_table(L,0,12);
        number(L,a,"spawnTick",v->spawn_tick);number(L,a,"offsetX",v->offset_x);number(L,a,"offsetY",v->offset_y);
        number(L,a,"width",v->width);number(L,a,"height",v->height);number(L,a,"angle",v->angle);
        number(L,a,"speed",v->speed);number(L,a,"damage",v->damage);number(L,a,"type",v->type);
        boolean(L,a,"supported",v->supported);boolean(L,a,"piercing",v->piercing);
        a->set_table(L,-3);
    }
    a->set_table(L,-3);
    boolean(L,a,"activeValid",s->valid&&s->c1_active_valid);
    a->push_string(L,"activeShots");a->create_table(L,s->valid&&s->c1_active_valid?s->c1_active_count:0,0);
    if(s->valid&&s->c1_active_valid)for(i=0;i<s->c1_active_count;i++){
        const Th09C1ActiveShot *v=&s->c1_active[i];
        a->push_number(L,i+1);a->create_table(L,0,14);
        number(L,a,"slotId",v->slot_id);number(L,a,"x",v->x);number(L,a,"y",v->y);
        number(L,a,"width",v->width);number(L,a,"height",v->height);
        number(L,a,"vx",v->vx);number(L,a,"vy",v->vy);number(L,a,"age",v->age);
        number(L,a,"type",v->type);number(L,a,"damage",v->damage);
        boolean(L,a,"supported",v->supported);boolean(L,a,"piercing",v->piercing);
        boolean(L,a,"currentGeometryOnly",TRUE);
        boolean(L,a,"damageReady",v->damage_ready);
        a->set_table(L,-3);
    }
    a->set_table(L,-3);a->set_table(L,-3);   /* activeShots, c1Profile */
    /* Opponent gauge sub-snapshot (3.0 step 1). valid=false is a normal state
     * between rounds; a missing table entry is never treated as "opponent has
     * no energy". All numbers are zero when invalid. Written while the sensor
     * table is still on top of the stack. */
    number(L,a,"opponentApiVersion",TH09_PLAYER_OPPONENT_API);
    a->push_string(L,"opponent");a->create_table(L,0,9);
    {
        const Th09OpponentSnapshot *o=&s->opponent;
        int ok=s->valid&&o->valid;
        boolean(L,a,"valid",ok);
        number(L,a,"chargeCurrent",ok?o->charge_current:0);
        number(L,a,"chargeMax",ok?o->charge_max:0);
        number(L,a,"chargeSpeed",ok?o->charge_speed:0);
        number(L,a,"state",ok?o->state:0);
        number(L,a,"protectionFrames",ok?o->protection:0);
        number(L,a,"life",ok?o->life:0);
        number(L,a,"spellPoint",ok?(double)o->spell_point:0);
        number(L,a,"combo",ok?(double)o->combo:0);
    }
    a->set_table(L,-3);
    a->set_table(L,-3);   /* sensor -> player */
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
        {0x404980,0x18,0xFF97FEEE},{0x491650,8,0x3420A951},
        /* Followup ABI: common pool layout/update and SHT/current-shot geometry. */
        {0x403C20,0x6B,0xA76BAA60u},{0x41EBFA,0x55,0x805EE4FDu},
        {0x41C8E0,0x110,0xD13CD57Bu},{0x41CF30,0x6C,0x5A94CA68u},
        {0x41CFE0,0x139,0x478B14ECu},{0x41BBE0,0xAC,0x1D88C1E9u},
        {0x41F2C0,0x37,0x2A1222A2u},{0x41F350,0x22C,0x93A0EF0Bu},
        {0x41F580,0xFB,0xFFA2C9C3u},{0x41FCD0,0x20B,0xDA96AD60u}};
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

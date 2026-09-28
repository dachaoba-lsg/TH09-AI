/* Reproducible guard for the pinned upstream x86 DLL. All original RVAs and
 * relocation entries stay fixed. This build tool never loads the input DLL.
 * A protected input is accepted only if it exactly equals the canonical
 * transformation of the SHA-256-pinned original (source-package rebuilds).
 * Build: tcc -Wall -Werror inject_guard_builder.c -o inject_guard_builder.exe
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ORIGINAL_SIZE 443392u
#define GUARDED_SIZE (ORIGINAL_SIZE + 512u)
#define ENTRY_RVA 0x1d9b0u
#define ENTRY_RAW 0x1cdb0u
#define GUARD_RVA 0x72000u
#define NEW_SECTION_HEADER 0x2a8u

static const unsigned char original_head[6] = {0x55,0x8b,0xec,0x83,0xec,0x08};
static const unsigned char original_sha256[32] = {
    0x2b,0xa6,0x7f,0x1f,0x80,0xeb,0xe5,0x3f,0x97,0x8d,0xc6,0x84,0x37,0x77,0x76,0x4b,
    0x5e,0xad,0x91,0x1a,0x68,0x8c,0x89,0xc9,0xcd,0x68,0xcc,0x8c,0x2d,0x9c,0xae,0x00
};

static unsigned short u16(const unsigned char *p) { return p[0] | p[1] << 8; }
static unsigned int u32(const unsigned char *p) {
    return (unsigned int)p[0] | (unsigned int)p[1] << 8 |
        (unsigned int)p[2] << 16 | (unsigned int)p[3] << 24;
}
static void w16(unsigned char *p, unsigned int n) { p[0]=(unsigned char)n; p[1]=(unsigned char)(n>>8); }
static void w32(unsigned char *p, unsigned int n) {
    p[0]=(unsigned char)n; p[1]=(unsigned char)(n>>8);
    p[2]=(unsigned char)(n>>16); p[3]=(unsigned char)(n>>24);
}

/* CryptoAPI is dynamically resolved to keep the minimal TinyCC SDK usable.
 * SHA-256 and full byte equality pin the input; this is not a key verifier. */
static int sha256(const unsigned char *data, unsigned int size, unsigned char out[32]) {
    typedef BOOL (WINAPI *Acquire)(ULONG_PTR *,LPCSTR,LPCSTR,DWORD,DWORD);
    typedef BOOL (WINAPI *Create)(ULONG_PTR,DWORD,ULONG_PTR,DWORD,ULONG_PTR *);
    typedef BOOL (WINAPI *Update)(ULONG_PTR,const BYTE *,DWORD,DWORD);
    typedef BOOL (WINAPI *Finish)(ULONG_PTR,DWORD,BYTE *,DWORD *,DWORD);
    typedef BOOL (WINAPI *Destroy)(ULONG_PTR);
    typedef BOOL (WINAPI *Release)(ULONG_PTR,DWORD);
    HMODULE library; char path[MAX_PATH]; UINT length;
    Acquire acquire; Create create; Update update; Finish finish; Destroy destroy; Release release;
    ULONG_PTR provider=0,hash=0; DWORD bytes=32; int ok=0;
    length=GetSystemDirectoryA(path,MAX_PATH);
    if(!length || length>MAX_PATH-14) return 0;
    strcat(path,"\\advapi32.dll"); library=LoadLibraryA(path);
    if(!library) return 0;
    acquire=(Acquire)GetProcAddress(library,"CryptAcquireContextA");
    create=(Create)GetProcAddress(library,"CryptCreateHash");
    update=(Update)GetProcAddress(library,"CryptHashData");
    finish=(Finish)GetProcAddress(library,"CryptGetHashParam");
    destroy=(Destroy)GetProcAddress(library,"CryptDestroyHash");
    release=(Release)GetProcAddress(library,"CryptReleaseContext");
    if(!acquire||!create||!update||!finish||!destroy||!release) goto done;
    if(!acquire(&provider,NULL,NULL,24,0xf0000000u)) goto done;
    if(!create(provider,0x800cu,0,0,&hash)) goto done;
    ok=update(hash,data,size,0)&&finish(hash,2,out,&bytes,0)&&bytes==32;
done:
    if(hash) destroy(hash);
    if(provider) release(provider,0);
    FreeLibrary(library); return ok;
}

static void emit(unsigned char *code, unsigned int *used, unsigned int value) {
    code[(*used)++]=(unsigned char)value;
}
static void emit32(unsigned char *code, unsigned int *used, unsigned int value) {
    w32(code+*used,value); *used+=4;
}

static unsigned int make_guard(unsigned char *c) {
    unsigned int n=0,base_offset,module_ref,export_ref,deny_refs[3],deny,tail,module_name,export_name,i;
    const char *module="window_support.dll",*name="Th09NativeSideAuthorized";
    /* pushfd/pushad preserve the original cdecl entry state. call/pop yields
     * our relocated module base without adding absolute relocations. */
    emit(c,&n,0x9c); emit(c,&n,0x60);
    emit(c,&n,0xe8); emit32(c,&n,0); base_offset=n;
    emit(c,&n,0x5b); emit(c,&n,0x81); emit(c,&n,0xeb); emit32(c,&n,GUARD_RVA+base_offset);
    emit(c,&n,0x8d); emit(c,&n,0x83); module_ref=n; emit32(c,&n,0); emit(c,&n,0x50);
    emit(c,&n,0xff); emit(c,&n,0x93); emit32(c,&n,0x4c0c4u); /* GetModuleHandleW */
    emit(c,&n,0x85); emit(c,&n,0xc0); emit(c,&n,0x0f); emit(c,&n,0x84); deny_refs[0]=n; emit32(c,&n,0);
    emit(c,&n,0x8d); emit(c,&n,0x93); export_ref=n; emit32(c,&n,0); emit(c,&n,0x52); emit(c,&n,0x50);
    emit(c,&n,0xff); emit(c,&n,0x93); emit32(c,&n,0x4c018u); /* GetProcAddress */
    emit(c,&n,0x85); emit(c,&n,0xc0); emit(c,&n,0x0f); emit(c,&n,0x84); deny_refs[1]=n; emit32(c,&n,0);
    emit(c,&n,0xff); emit(c,&n,0xd0); /* cdecl, zero arguments */
    emit(c,&n,0x83); emit(c,&n,0xf8); emit(c,&n,0x01); /* exact authorized value */
    emit(c,&n,0x0f); emit(c,&n,0x85); deny_refs[2]=n; emit32(c,&n,0);
    emit(c,&n,0x61); emit(c,&n,0x9d);
    memcpy(c+n,original_head,6); n+=6;
    emit(c,&n,0xe9); tail=n; emit32(c,&n,ENTRY_RVA+6-(GUARD_RVA+tail+4));
    deny=n; emit(c,&n,0x61); emit(c,&n,0x9d); emit(c,&n,0x31); emit(c,&n,0xc0); emit(c,&n,0xc3);
    module_name=n;
    for(i=0;i<=strlen(module);i++) { emit(c,&n,module[i]); emit(c,&n,0); }
    export_name=n; memcpy(c+n,name,strlen(name)+1); n+=(unsigned int)strlen(name)+1;
    w32(c+module_ref,GUARD_RVA+module_name); w32(c+export_ref,GUARD_RVA+export_name);
    for(i=0;i<3;i++) w32(c+deny_refs[i],deny-deny_refs[i]-4);
    return n;
}

static int canonical_original(unsigned char *data,unsigned int size) {
    unsigned char digest[32];
    if(size==GUARDED_SIZE) {
        /* Restore only the documented transformation, then hash the entire
         * original. The caller also compares the complete rebuilt guarded DLL. */
        w16(data+0xee,5); w32(data+0x104,0x4a800u); w32(data+0x138,0x72000u);
        memset(data+NEW_SECTION_HEADER,0,40); memcpy(data+ENTRY_RAW,original_head,6);
    } else if(size!=ORIGINAL_SIZE) return 0;
    return sha256(data,ORIGINAL_SIZE,digest)&&memcmp(digest,original_sha256,32)==0;
}

int main(int argc,char **argv) {
    FILE *file=NULL; unsigned char *input=NULL,*output=NULL,*s; long length;
    unsigned int n; int code=1,was_guarded=0,same_path; DWORD in_length,out_length;
    char in_path[MAX_PATH],out_path[MAX_PATH];
    if(argc!=3) { fprintf(stderr,"Usage: inject_guard_builder input.dll output.dll\n"); return 2; }
    in_length=GetFullPathNameA(argv[1],MAX_PATH,in_path,NULL);
    out_length=GetFullPathNameA(argv[2],MAX_PATH,out_path,NULL);
    if(!in_length||in_length>=MAX_PATH||!out_length||out_length>=MAX_PATH) return 2;
    same_path=_stricmp(in_path,out_path)==0;
    file=fopen(argv[1],"rb"); if(!file) goto done;
    if(fseek(file,0,SEEK_END)) goto done;
    length=ftell(file); if(length!=ORIGINAL_SIZE&&length!=GUARDED_SIZE) goto done;
    if(fseek(file,0,SEEK_SET)) goto done;
    input=(unsigned char *)malloc((size_t)length); output=(unsigned char *)calloc(1,GUARDED_SIZE);
    if(!input||!output||fread(input,1,(size_t)length,file)!=(size_t)length) goto done;
    fclose(file); file=NULL; memcpy(output,input,(size_t)length); was_guarded=length==GUARDED_SIZE;
    if(!canonical_original(output,(unsigned int)length)) { fprintf(stderr,"Input is not the pinned upstream or canonical guarded DLL.\n"); goto done; }
    if(u16(output+0xee)!=5||u32(output+0x138)!=GUARD_RVA||memcmp(output+ENTRY_RAW,original_head,6)) goto done;
    memset(output+ORIGINAL_SIZE,0,512); n=make_guard(output+ORIGINAL_SIZE);
    w16(output+0xee,6); w32(output+0x104,0x4aa00u); w32(output+0x138,0x73000u);
    s=output+NEW_SECTION_HEADER; memcpy(s,".aiguard",8); w32(s+8,n); w32(s+12,GUARD_RVA);
    w32(s+16,512); w32(s+20,ORIGINAL_SIZE); w32(s+36,0x60000020u);
    output[ENTRY_RAW]=0xe9; w32(output+ENTRY_RAW+1,GUARD_RVA-ENTRY_RVA-5); output[ENTRY_RAW+5]=0x90;
    if(was_guarded&&memcmp(input,output,GUARDED_SIZE)) { fprintf(stderr,"Guarded DLL canonical byte verification failed.\n"); goto done; }
    if(same_path) {
        if(!was_guarded) { fprintf(stderr,"Use a distinct output when transforming the original DLL.\n"); goto done; }
        printf("PASS: canonical guarded DLL verified in place; no file change.\n"); code=0; goto done;
    }
    file=fopen(argv[2],"wb"); if(!file||fwrite(output,1,GUARDED_SIZE,file)!=GUARDED_SIZE) goto done;
    if(fclose(file)) { file=NULL; goto done; } file=NULL;
    printf("PASS: canonical 1P write guard; original RVAs preserved; %u bytes.\n",GUARDED_SIZE); code=0;
done:
    if(file) fclose(file);
    free(input); free(output);
    if(code) fprintf(stderr,"Guard construction failed; no unsupported DLL is accepted.\n");
    return code;
}

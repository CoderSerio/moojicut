#define _GNU_SOURCE 1
#define _DARWIN_C_SOURCE 1
#include "platform/shared/plugin_host/package_store.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* Fault build: compile only package_store_posix.c with
 * -Dfsync=mc_plugin_store_test_fsync; compile this fixture with
 * -DMC_PLUGIN_STORE_FAULT_TEST. All other IO and CAS calls remain real. */
static atomic_int fail_sync_kind = ATOMIC_VAR_INIT(0);
int mc_plugin_store_test_fsync(int fd) {
    struct stat identity;
    int mode=atomic_load(&fail_sync_kind);
    if(mode && !fstat(fd,&identity) && ((mode==1 && S_ISREG(identity.st_mode)) || (mode==2 && S_ISDIR(identity.st_mode)))) {
        atomic_store(&fail_sync_kind,0);errno=EIO;return -1;
    }
    return fsync(fd);
}
static unsigned checks,failures;
#define CHECK(value,message) do {++checks;if(!(value)){++failures;fprintf(stderr,"FAIL package store: %s\n",message);}}while(0)
static const uint8_t a[]={'o','l','d',0,'A'},b[]={'n','e','w',0,'B'},c[]={'n','e','w',0,'C'};
static MCPluginStoreError error;
static void path_join(char out[4096],const char *root,const char *name) {
    int count=snprintf(out,4096,"%s/%s",root,name);
    if(count<0 || count>=4096)abort();
}
static bool equals_snapshot(const char *root,const uint8_t *bytes,size_t size) {
    MCPluginStoreBytes read={0};
    bool result=mc_plugin_store_read_snapshot(root,&read,&error)==MC_PLUGIN_STORE_OK && read.size==size &&
        (!size || !memcmp(read.bytes,bytes,size));
    mc_plugin_store_bytes_free(&read);return result;
}
static unsigned staging_count(const char *path) {
    DIR *directory=opendir(path);if(!directory)return 0;
    unsigned count=0;struct dirent *entry;
    while((entry=readdir(directory)))if(!strncmp(entry->d_name,".stage-",7))++count;
    closedir(directory);return count;
}
static unsigned open_count(void) {
    unsigned count=0;
    for(int fd=0;fd<256;++fd)if(fcntl(fd,F_GETFD)!=-1)++count;
    return count;
}
static void remove_fixture(const char *path) {
    struct stat identity;if(lstat(path,&identity))return;
    if(!S_ISDIR(identity.st_mode)){unlink(path);return;}
    chmod(path,0700);DIR *directory=opendir(path);if(!directory)return;
    struct dirent *entry;
    while((entry=readdir(directory))) {
        if(!strcmp(entry->d_name,".") || !strcmp(entry->d_name,".."))continue;
        char child[4096];path_join(child,path,entry->d_name);remove_fixture(child);
    }
    closedir(directory);rmdir(path);
}
static bool load_zip(const char *path,MCPluginStoreBytes *bytes) {
    FILE *file=fopen(path,"rb");if(!file)return false;
    uint8_t *buffer=malloc(MC_PLUGIN_STORE_ZIP_LIMIT+1u);if(!buffer){fclose(file);return false;}
    size_t size=fread(buffer,1,MC_PLUGIN_STORE_ZIP_LIMIT+1u,file);
    bool result=!ferror(file) && size<=MC_PLUGIN_STORE_ZIP_LIMIT;
    if(fclose(file))result=false;
    if(!result){free(buffer);return false;}bytes->bytes=buffer;bytes->size=size;return true;
}
typedef struct {const char *root;const uint8_t *replacement;atomic_bool *start;MCPluginStoreStatus result;} Race;
static void *race_replace(void *value) {
    Race *race=value;struct timespec delay={0,1000000};
    while(!atomic_load(race->start))nanosleep(&delay,NULL);
    for(unsigned attempt=0;attempt<1000;++attempt) {
        race->result=mc_plugin_store_replace_snapshot(race->root,true,a,sizeof(a),race->replacement,sizeof(a),NULL);
        if(race->result!=MC_PLUGIN_STORE_BUSY)break;
        nanosleep(&delay,NULL);
    }
    return NULL;
}

int main(int argc,char **argv) {
    if(argc!=3){fprintf(stderr,"Usage: plugin-package-store-posix real-plugin.zip lowercase-sha256\n");return 2;}
    unsigned initial_fds=open_count();
    char temporary[]="/tmp/moojicut-package-store-XXXXXX";
    if(!mkdtemp(temporary))return 2;
    char root[4096],snapshot[4096],packages[4096],lock_path[4096],zip_path[4096],name[80];
    path_join(root,temporary,"plugins-v2");path_join(snapshot,root,"snapshot.bin");path_join(packages,root,"packages");path_join(lock_path,root,".lock");
    snprintf(name,sizeof(name),"%s.zip",argv[2]);path_join(zip_path,packages,name);
    MCPluginStoreBytes bytes={0},original_zip={0};
    CHECK(mc_plugin_store_read_snapshot(root,&bytes,&error)==MC_PLUGIN_STORE_MISSING && !bytes.bytes && access(root,F_OK),"missing snapshot read does not create root");
    CHECK(mc_plugin_store_read_zip(root,argv[2],&bytes,&error)==MC_PLUGIN_STORE_MISSING && access(root,F_OK),"missing ZIP read does not create root");
    CHECK(mc_plugin_store_read_snapshot("relative",&bytes,&error)==MC_PLUGIN_STORE_INVALID,"relative storage root rejected");
    CHECK(mc_plugin_store_stage_zip(root,"../escape",a,sizeof(a),&error)==MC_PLUGIN_STORE_INVALID && access(root,F_OK),"invalid digest rejected before IO");
    CHECK(mc_plugin_store_replace_snapshot(root,false,NULL,0,a,sizeof(a),&error)==MC_PLUGIN_STORE_OK && equals_snapshot(root,a,sizeof(a)),"first snapshot publication and exact binary read");
    struct stat first,second;CHECK(!stat(snapshot,&first),"snapshot is present");
    CHECK(mc_plugin_store_replace_snapshot(root,false,NULL,0,b,sizeof(b),&error)==MC_PLUGIN_STORE_STALE && equals_snapshot(root,a,sizeof(a)),"absent CAS cannot overwrite existing snapshot");
    CHECK(mc_plugin_store_replace_snapshot(root,true,b,sizeof(b),c,sizeof(c),&error)==MC_PLUGIN_STORE_STALE && equals_snapshot(root,a,sizeof(a)),"wrong expected bytes preserve old snapshot");
    CHECK(mc_plugin_store_replace_snapshot(root,true,a,sizeof(a),b,sizeof(b),&error)==MC_PLUGIN_STORE_OK && equals_snapshot(root,b,sizeof(b)),"matching CAS publishes complete replacement");
    CHECK(!stat(snapshot,&second) && first.st_ino!=second.st_ino,"replacement uses a new inode rather than overwriting live bytes");
    CHECK(mc_plugin_store_replace_snapshot(root,true,b,sizeof(b),b,sizeof(b),&error)==MC_PLUGIN_STORE_OK,"same desired snapshot confirms durability");
    CHECK(!stat(snapshot,&first) && first.st_ino==second.st_ino,"same snapshot does not rewrite bytes");
    int lock=open(lock_path,O_RDWR);CHECK(lock>=0 && !flock(lock,LOCK_EX|LOCK_NB),"fixture holds actual store flock");
    CHECK(mc_plugin_store_replace_snapshot(root,true,b,sizeof(b),c,sizeof(c),&error)==MC_PLUGIN_STORE_BUSY,"concurrent transaction returns BUSY without waiting");
    CHECK(mc_plugin_store_stage_zip(root,argv[2],a,sizeof(a),&error)==MC_PLUGIN_STORE_BUSY,"staging uses same transaction lock");
    if(lock>=0){flock(lock,LOCK_UN);close(lock);}
    CHECK(load_zip(argv[1],&original_zip),"real MoonBit ZIP read by caller");
    CHECK(mc_plugin_store_stage_zip(root,argv[2],original_zip.bytes,original_zip.size,&error)==MC_PLUGIN_STORE_OK,"stage actual ZIP immutably");
    CHECK(!stat(zip_path,&first),"immutable ZIP has a real file");
    CHECK(mc_plugin_store_stage_zip(root,argv[2],original_zip.bytes,original_zip.size,&error)==MC_PLUGIN_STORE_OK && !stat(zip_path,&second) && first.st_ino==second.st_ino,"identical digest and bytes reuse immutable ZIP");
    CHECK(mc_plugin_store_stage_zip(root,argv[2],a,sizeof(a),&error)==MC_PLUGIN_STORE_CONFLICT,"same digest cannot overwrite different bytes");
    CHECK(mc_plugin_store_read_zip(root,argv[2],&bytes,&error)==MC_PLUGIN_STORE_OK && bytes.size==original_zip.size && !memcmp(bytes.bytes,original_zip.bytes,bytes.size),"conflict leaves exact original ZIP readable after reopen");
    mc_plugin_store_bytes_free(&bytes);
    CHECK(mc_plugin_store_stage_zip(root,argv[2],a,MC_PLUGIN_STORE_ZIP_LIMIT+1u,&error)==MC_PLUGIN_STORE_INVALID,"ZIP limit enforced before accessing input bytes");
    CHECK(mc_plugin_store_replace_snapshot(root,true,b,sizeof(b),a,MC_PLUGIN_STORE_SNAPSHOT_LIMIT+1u,&error)==MC_PLUGIN_STORE_INVALID && equals_snapshot(root,b,sizeof(b)),"snapshot limit preserves previous bytes");

#ifdef MC_PLUGIN_STORE_FAULT_TEST
    atomic_store(&fail_sync_kind,1);
    CHECK(mc_plugin_store_replace_snapshot(root,true,b,sizeof(b),c,sizeof(c),&error)==MC_PLUGIN_STORE_IO && error.system_error==EIO,"real file fsync failure prevents publication");
    CHECK(equals_snapshot(root,b,sizeof(b)) && staging_count(root)==0,"precommit failure rolls back only owned staging");
    atomic_store(&fail_sync_kind,2);
    CHECK(mc_plugin_store_replace_snapshot(root,true,b,sizeof(b),c,sizeof(c),&error)==MC_PLUGIN_STORE_COMMITTED_NOT_DURABLE && error.system_error==EIO,"post-rename directory failure reports already committed");
    CHECK(equals_snapshot(root,c,sizeof(c)),"committed-not-durable bytes are actually visible");
    CHECK(mc_plugin_store_replace_snapshot(root,true,b,sizeof(b),a,sizeof(a),&error)==MC_PLUGIN_STORE_STALE,"old expectation cannot roll back visible commit");
    CHECK(mc_plugin_store_replace_snapshot(root,true,c,sizeof(c),b,sizeof(b),&error)==MC_PLUGIN_STORE_OK,"reconciliation uses actual current expected bytes");
    static const char other_digest[]="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    atomic_store(&fail_sync_kind,1);
    CHECK(mc_plugin_store_stage_zip(root,other_digest,original_zip.bytes,original_zip.size,&error)==MC_PLUGIN_STORE_IO,"ZIP sync failure never publishes a partial blob");
    CHECK(mc_plugin_store_read_zip(root,other_digest,&bytes,&error)==MC_PLUGIN_STORE_MISSING && staging_count(packages)==0,"failed staging has no discoverable ZIP or owned temporary");
    atomic_store(&fail_sync_kind,2);
    CHECK(mc_plugin_store_stage_zip(root,other_digest,original_zip.bytes,original_zip.size,&error)==MC_PLUGIN_STORE_COMMITTED_NOT_DURABLE,"ZIP directory-sync failure is also committed");
    CHECK(mc_plugin_store_read_zip(root,other_digest,&bytes,&error)==MC_PLUGIN_STORE_OK && bytes.size==original_zip.size,"published ZIP remains readable after durability warning");
    mc_plugin_store_bytes_free(&bytes);
#endif

    CHECK(mc_plugin_store_replace_snapshot(root,true,b,sizeof(b),NULL,0,&error)==MC_PLUGIN_STORE_OK,"empty snapshots are opaque valid storage bytes");
    CHECK(mc_plugin_store_read_snapshot(root,&bytes,&error)==MC_PLUGIN_STORE_OK && bytes.size==0 && bytes.bytes,"empty existing snapshot differs from missing");
    mc_plugin_store_bytes_free(&bytes);
    CHECK(mc_plugin_store_replace_snapshot(root,false,NULL,0,a,sizeof(a),&error)==MC_PLUGIN_STORE_STALE,"empty file is not absence");
    CHECK(mc_plugin_store_replace_snapshot(root,true,NULL,0,a,sizeof(a),&error)==MC_PLUGIN_STORE_OK,"empty exact expectation is explicit");
    atomic_bool start=ATOMIC_VAR_INIT(false);Race races[]={{root,b,&start,MC_PLUGIN_STORE_IO},{root,c,&start,MC_PLUGIN_STORE_IO}};
    pthread_t threads[2];int left=pthread_create(&threads[0],NULL,race_replace,&races[0]);int right=pthread_create(&threads[1],NULL,race_replace,&races[1]);
    atomic_store(&start,true);
    if(!left)pthread_join(threads[0],NULL);
    if(!right)pthread_join(threads[1],NULL);
    CHECK(!left && !right && ((races[0].result==MC_PLUGIN_STORE_OK && races[1].result==MC_PLUGIN_STORE_STALE) ||
          (races[1].result==MC_PLUGIN_STORE_OK && races[0].result==MC_PLUGIN_STORE_STALE)),"two real threads with same expected bytes publish exactly once");

    char alias[4096],backup[4096],outside[4096];path_join(alias,temporary,"alias");path_join(backup,root,"fixture-backup");path_join(outside,temporary,"outside");
    CHECK(!symlink(root,alias) && mc_plugin_store_read_snapshot(alias,&bytes,&error)==MC_PLUGIN_STORE_IO,"root symlink is not followed");unlink(alias);
    CHECK(!link(snapshot,outside) && mc_plugin_store_read_snapshot(root,&bytes,&error)==MC_PLUGIN_STORE_INVALID,"hardlinked snapshot is rejected");unlink(outside);
    CHECK(!rename(snapshot,backup) && !symlink(backup,snapshot) && mc_plugin_store_read_snapshot(root,&bytes,&error)==MC_PLUGIN_STORE_IO,"snapshot symlink is not followed");
    CHECK(mc_plugin_store_replace_snapshot(root,false,NULL,0,a,sizeof(a),&error)==MC_PLUGIN_STORE_IO,"snapshot link never masquerades as missing");unlink(snapshot);rename(backup,snapshot);
    CHECK(!rename(snapshot,backup) && !mkfifo(snapshot,0600) && mc_plugin_store_read_snapshot(root,&bytes,&error)==MC_PLUGIN_STORE_INVALID,"FIFO rejected without waiting for writer");unlink(snapshot);rename(backup,snapshot);
    CHECK(!chmod(root,0755) && mc_plugin_store_read_snapshot(root,&bytes,&error)==MC_PLUGIN_STORE_INVALID,"existing nonprivate root rejected without chmod repair");chmod(root,0700);
    CHECK(!link(zip_path,outside) && mc_plugin_store_read_zip(root,argv[2],&bytes,&error)==MC_PLUGIN_STORE_INVALID,"hardlinked ZIP is rejected");unlink(outside);
    CHECK(!rename(packages,backup) && !symlink(backup,packages) && mc_plugin_store_read_zip(root,argv[2],&bytes,&error)==MC_PLUGIN_STORE_IO,"packages directory symlink is not followed");
    CHECK(mc_plugin_store_stage_zip(root,argv[2],a,sizeof(a),&error)==MC_PLUGIN_STORE_IO,"stage refuses redirected packages directory");unlink(packages);rename(backup,packages);
    CHECK(!rename(snapshot,backup),"fixture preserves current snapshot for oversized-file check");
    int large=open(snapshot,O_WRONLY|O_CREAT|O_EXCL,0600);
    CHECK(large>=0 && !ftruncate(large,MC_PLUGIN_STORE_SNAPSHOT_LIMIT+1u),"fixture creates real oversized snapshot");
    if(large>=0)close(large);
    CHECK(mc_plugin_store_read_snapshot(root,&bytes,&error)==MC_PLUGIN_STORE_INVALID,"oversized disk file fails before allocation");
    CHECK(mc_plugin_store_replace_snapshot(root,false,NULL,0,a,sizeof(a),&error)==MC_PLUGIN_STORE_INVALID,"unreadable catalog is not silently reset");unlink(snapshot);rename(backup,snapshot);
    CHECK(!staging_count(root) && !staging_count(packages),"only owned temporary files are cleaned");
    mc_plugin_store_bytes_free(&bytes);mc_plugin_store_bytes_free(&original_zip);
    CHECK(open_count()==initial_fds,"success and failure paths release descriptors and locks");
    remove_fixture(temporary);
    printf("package store POSIX: %u checks, %u failures\n",checks,failures);
    return failures?1:0;
}

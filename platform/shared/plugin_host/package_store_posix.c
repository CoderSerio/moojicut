#define _GNU_SOURCE 1
#define _DARWIN_C_SOURCE 1
#include "package_store.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

typedef struct { int parent, fd; char name[256]; struct stat identity; } Root;
static atomic_uint_fast64_t temporary_sequence = 0;

static MCPluginStoreStatus failure(MCPluginStoreError *error, MCPluginStoreStatus status,
    const char *operation, int code) {
    if (error) {
        error->system_error = (uint32_t)code;
        if (code) snprintf(error->message, sizeof(error->message), "%s (errno %d)", operation, code);
        else snprintf(error->message, sizeof(error->message), "%s", operation);
    }
    return status;
}
static void error_reset(MCPluginStoreError *error) { if (error) memset(error, 0, sizeof(*error)); }
static bool valid_utf8(const unsigned char *p) {
    while (*p) {
        unsigned char first = *p++;
        if (first < 0x80) continue;
        unsigned count; uint32_t value, minimum;
        if (first >= 0xc2 && first <= 0xdf) { count=1;value=first&0x1fu;minimum=0x80; }
        else if (first >= 0xe0 && first <= 0xef) { count=2;value=first&0x0fu;minimum=0x800; }
        else if (first >= 0xf0 && first <= 0xf4) { count=3;value=first&7u;minimum=0x10000; }
        else return false;
        for (unsigned i=0;i<count;++i) {
            if ((*p & 0xc0u) != 0x80u) return false;
            value=(value<<6)|(*p++&0x3fu);
        }
        if (value<minimum || value>0x10ffff || (value>=0xd800 && value<=0xdfff)) return false;
    }
    return true;
}
static bool valid_root_path(const char *path) {
    if (!path || path[0]!='/' || strnlen(path,4097)>4096 || !valid_utf8((const unsigned char *)path)) return false;
    const char *part=path+1;
    for (;;) {
        const char *slash=strchr(part,'/');size_t size=slash?(size_t)(slash-part):strlen(part);
        if (!size || (size==1 && part[0]=='.') || (size==2 && part[0]=='.' && part[1]=='.')) return false;
        if (!slash) return size<256;
        part=slash+1;
    }
}
static bool valid_digest(const char *digest) {
    if (!digest || strnlen(digest,65)!=64) return false;
    for(size_t i=0;i<64;++i)
        if (!((digest[i]>='0' && digest[i]<='9') || (digest[i]>='a' && digest[i]<='f'))) return false;
    return true;
}
static bool identity_equal(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino && (a->st_mode&S_IFMT)==(b->st_mode&S_IFMT);
}
static bool file_unchanged(const struct stat *a,const struct stat *b) {
#ifdef __APPLE__
    bool times=a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
#else
    bool times=a->st_mtim.tv_sec==b->st_mtim.tv_sec && a->st_mtim.tv_nsec==b->st_mtim.tv_nsec &&
        a->st_ctim.tv_sec==b->st_ctim.tv_sec && a->st_ctim.tv_nsec==b->st_ctim.tv_nsec;
#endif
    return identity_equal(a,b) && times && a->st_size==b->st_size && a->st_nlink==b->st_nlink;
}
static bool private_directory(int fd,struct stat *identity) {
    return !fstat(fd,identity) && S_ISDIR(identity->st_mode) && identity->st_uid==geteuid() && !(identity->st_mode&077);
}
static void root_close(Root *root) {
    if(root->fd>=0)close(root->fd);
    if(root->parent>=0)close(root->parent);
    root->fd=root->parent=-1;
}
static bool root_current(const Root *root) {
    struct stat current;
    return !fstatat(root->parent,root->name,&current,AT_SYMLINK_NOFOLLOW) && identity_equal(&current,&root->identity) &&
        current.st_uid==geteuid() && !(current.st_mode&077);
}
static MCPluginStoreStatus root_open(const char *path,bool create,Root *root,MCPluginStoreError *error) {
    *root=(Root){.parent=-1,.fd=-1};
    if(!valid_root_path(path))return failure(error,MC_PLUGIN_STORE_INVALID,"Invalid absolute UTF-8 store root",0);
    char parent[4097];size_t length=strlen(path);memcpy(parent,path,length+1);
    char *slash=strrchr(parent,'/');snprintf(root->name,sizeof(root->name),"%s",slash+1);
    if(slash==parent)slash[1]=0;else *slash=0;
    root->parent=open(parent,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(root->parent<0) {
        if(!create && errno==ENOENT)return MC_PLUGIN_STORE_MISSING;
        return failure(error,MC_PLUGIN_STORE_IO,"Cannot open trusted store parent",errno);
    }
    bool created=false;
    if(create) {
        if(!mkdirat(root->parent,root->name,0700))created=true;
        else if(errno!=EEXIST){MCPluginStoreStatus status=failure(error,MC_PLUGIN_STORE_IO,"Cannot create store root",errno);root_close(root);return status;}
    }
    root->fd=openat(root->parent,root->name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(root->fd<0) {
        MCPluginStoreStatus status=(!create && errno==ENOENT)?MC_PLUGIN_STORE_MISSING:
            failure(error,MC_PLUGIN_STORE_IO,"Cannot open store root without following links",errno);
        root_close(root);return status;
    }
    if(!private_directory(root->fd,&root->identity) || !root_current(root)) {
        root_close(root);return failure(error,MC_PLUGIN_STORE_INVALID,"Store root must be a private owned directory",0);
    }
    if(created && fsync(root->parent)) {
        MCPluginStoreStatus status=failure(error,MC_PLUGIN_STORE_IO,"Cannot sync new store directory",errno);root_close(root);return status;
    }
    return MC_PLUGIN_STORE_OK;
}
static MCPluginStoreStatus acquire_lock(const Root *root,int *lock,MCPluginStoreError *error) {
    *lock=openat(root->fd,".lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,0600);
    if(*lock<0)return failure(error,MC_PLUGIN_STORE_IO,"Cannot open store lock",errno);
    struct stat actual,path;
    if(fstat(*lock,&actual) || !S_ISREG(actual.st_mode) || actual.st_nlink!=1 || actual.st_uid!=geteuid())
        return failure(error,MC_PLUGIN_STORE_INVALID,"Store lock must be an owned independent regular file",0);
    if(flock(*lock,LOCK_EX|LOCK_NB))return failure(error,(errno==EWOULDBLOCK || errno==EAGAIN)?MC_PLUGIN_STORE_BUSY:MC_PLUGIN_STORE_IO,"Cannot acquire store lock",errno);
    if(fstatat(root->fd,".lock",&path,AT_SYMLINK_NOFOLLOW) || !identity_equal(&actual,&path) || !root_current(root))
        return failure(error,MC_PLUGIN_STORE_STALE,"Store or lock identity changed",0);
    return MC_PLUGIN_STORE_OK;
}
static bool lock_current(const Root *root,int lock) {
    struct stat actual,path;
    return root_current(root) && !fstat(lock,&actual) && !fstatat(root->fd,".lock",&path,AT_SYMLINK_NOFOLLOW) &&
        actual.st_nlink==1 && identity_equal(&actual,&path);
}
static void release_lock(int lock) { if(lock>=0){flock(lock,LOCK_UN);close(lock);} }
void mc_plugin_store_bytes_free(MCPluginStoreBytes *bytes) {
    if(bytes){free(bytes->bytes);*bytes=(MCPluginStoreBytes){0};}
}
static MCPluginStoreStatus read_file(int directory,const char *name,size_t limit,
    MCPluginStoreBytes *out,struct stat *identity,MCPluginStoreError *error) {
    int fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0)return errno==ENOENT?MC_PLUGIN_STORE_MISSING:failure(error,MC_PLUGIN_STORE_IO,"Cannot open store file without following links",errno);
    struct stat before,after;
    MCPluginStoreStatus status=MC_PLUGIN_STORE_OK;
    MCPluginStoreBytes result={0};
    if(fstat(fd,&before))status=failure(error,MC_PLUGIN_STORE_IO,"Cannot inspect store file",errno);
    else if(!S_ISREG(before.st_mode) || before.st_nlink!=1 || before.st_size<0 || (uint64_t)before.st_size>limit)
        status=failure(error,MC_PLUGIN_STORE_INVALID,"Store file is not independent, regular and bounded",0);
    if(status==MC_PLUGIN_STORE_OK) {
        result.size=(size_t)before.st_size;result.bytes=malloc(result.size+1);
        if(!result.bytes)status=failure(error,MC_PLUGIN_STORE_IO,"Cannot allocate bounded store read",ENOMEM);
    }
    size_t offset=0;
    while(status==MC_PLUGIN_STORE_OK && offset<result.size) {
        ssize_t count=read(fd,result.bytes+offset,result.size-offset);
        if(count<0 && errno==EINTR)continue;
        if(count<0)status=failure(error,MC_PLUGIN_STORE_IO,"Cannot read store file",errno);
        else if(!count)status=failure(error,MC_PLUGIN_STORE_STALE,"Store file changed during read",0);
        else offset+=(size_t)count;
    }
    if(status==MC_PLUGIN_STORE_OK) {
        uint8_t extra;ssize_t count;
        do {count=read(fd,&extra,1);}while(count<0 && errno==EINTR);
        if(count<0)status=failure(error,MC_PLUGIN_STORE_IO,"Cannot finish store read",errno);
        else if(count || fstat(fd,&after) || !file_unchanged(&before,&after))status=failure(error,MC_PLUGIN_STORE_STALE,"Store file changed during read",0);
    }
    if(close(fd) && status==MC_PLUGIN_STORE_OK)status=failure(error,MC_PLUGIN_STORE_IO,"Cannot close store read",errno);
    if(status!=MC_PLUGIN_STORE_OK){mc_plugin_store_bytes_free(&result);return status;}
    result.bytes[result.size]=0;
    *out=result;
    if(identity)*identity=before;
    return status;
}
static MCPluginStoreStatus packages_open(const Root *root,bool create,int *fd,MCPluginStoreError *error) {
    bool created=false;
    if(create){if(!mkdirat(root->fd,"packages",0700))created=true;else if(errno!=EEXIST)return failure(error,MC_PLUGIN_STORE_IO,"Cannot create package directory",errno);}
    *fd=openat(root->fd,"packages",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(*fd<0)return (!create && errno==ENOENT)?MC_PLUGIN_STORE_MISSING:failure(error,MC_PLUGIN_STORE_IO,"Cannot open package directory",errno);
    struct stat identity;
    if(!private_directory(*fd,&identity))return failure(error,MC_PLUGIN_STORE_INVALID,"Package directory must be private and owned",0);
    if(created && fsync(root->fd))return failure(error,MC_PLUGIN_STORE_IO,"Cannot sync package directory",errno);
    return MC_PLUGIN_STORE_OK;
}
static bool directory_current(int parent,const char *name,int fd) {
    struct stat actual,path;
    return !fstat(fd,&actual) && !fstatat(parent,name,&path,AT_SYMLINK_NOFOLLOW) && identity_equal(&actual,&path);
}
static void remove_owned(int directory,const char *name,const struct stat *identity) {
    struct stat current;
    if(*name && !fstatat(directory,name,&current,AT_SYMLINK_NOFOLLOW) && identity_equal(identity,&current))unlinkat(directory,name,0);
}
static MCPluginStoreStatus write_temporary(int directory,const uint8_t *bytes,size_t size,
    char name[96],struct stat *identity,MCPluginStoreError *error) {
    int fd=-1;
    struct timespec now={0};
    if(clock_gettime(CLOCK_MONOTONIC,&now))return failure(error,MC_PLUGIN_STORE_IO,"Cannot create staging identity",errno);
    for(unsigned attempt=0;attempt<128;++attempt) {
        uint64_t sequence=atomic_fetch_add_explicit(&temporary_sequence,1,memory_order_relaxed);
        snprintf(name,96,".stage-%" PRIu64 "-%" PRIu64 "-%" PRIu64,(uint64_t)getpid(),(uint64_t)now.tv_nsec,sequence);
        fd=openat(directory,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
        if(fd>=0 || errno!=EEXIST)break;
    }
    if(fd<0){name[0]=0;return failure(error,MC_PLUGIN_STORE_IO,"Cannot create exclusive staging file",errno);}
    MCPluginStoreStatus status=MC_PLUGIN_STORE_OK;
    if(fstat(fd,identity))status=failure(error,MC_PLUGIN_STORE_IO,"Cannot inspect staging file",errno);
    size_t offset=0;
    while(status==MC_PLUGIN_STORE_OK && offset<size) {
        ssize_t count=write(fd,bytes+offset,size-offset);
        if(count<0 && errno==EINTR)continue;
        if(count<=0)status=failure(error,MC_PLUGIN_STORE_IO,"Cannot write staging file",count<0?errno:EIO);
        else offset+=(size_t)count;
    }
    if(status==MC_PLUGIN_STORE_OK && (fchmod(fd,0444) || fsync(fd)))status=failure(error,MC_PLUGIN_STORE_IO,"Cannot sync staging file",errno);
    if(close(fd) && status==MC_PLUGIN_STORE_OK)status=failure(error,MC_PLUGIN_STORE_IO,"Cannot close staging file",errno);
    if(status!=MC_PLUGIN_STORE_OK){remove_owned(directory,name,identity);name[0]=0;}
    return status;
}
static int rename_exclusive(int directory,const char *from,const char *to) {
#ifdef __APPLE__
    return renameatx_np(directory,from,directory,to,RENAME_EXCL);
#else
    return renameat2(directory,from,directory,to,RENAME_NOREPLACE);
#endif
}
static MCPluginStoreStatus sync_committed(int directory,MCPluginStoreError *error) {
    return fsync(directory)?failure(error,MC_PLUGIN_STORE_COMMITTED_NOT_DURABLE,"Published bytes are visible but directory sync failed",errno):MC_PLUGIN_STORE_OK;
}
static bool bytes_equal(const MCPluginStoreBytes *a,const uint8_t *b,size_t size) {
    return a->size==size && (!size || !memcmp(a->bytes,b,size));
}
MCPluginStoreStatus mc_plugin_store_read_snapshot(const char *path,MCPluginStoreBytes *output,MCPluginStoreError *error) {
    error_reset(error);
    if(!output || output->bytes || output->size)return failure(error,MC_PLUGIN_STORE_INVALID,"Output must be empty",0);
    Root root;MCPluginStoreStatus status=root_open(path,false,&root,error);
    if(status!=MC_PLUGIN_STORE_OK)return status;
    MCPluginStoreBytes result={0};status=read_file(root.fd,"snapshot.bin",MC_PLUGIN_STORE_SNAPSHOT_LIMIT,&result,NULL,error);
    if((status==MC_PLUGIN_STORE_OK || status==MC_PLUGIN_STORE_MISSING) && !root_current(&root))status=failure(error,MC_PLUGIN_STORE_STALE,"Store root changed during read",0);
    root_close(&root);
    if(status==MC_PLUGIN_STORE_OK)*output=result;
    else mc_plugin_store_bytes_free(&result);
    return status;
}
MCPluginStoreStatus mc_plugin_store_read_zip(const char *path,const char *digest,MCPluginStoreBytes *output,MCPluginStoreError *error) {
    error_reset(error);
    if(!valid_digest(digest) || !output || output->bytes || output->size)return failure(error,MC_PLUGIN_STORE_INVALID,"Invalid digest or nonempty output",0);
    Root root;MCPluginStoreStatus status=root_open(path,false,&root,error);
    if(status!=MC_PLUGIN_STORE_OK)return status;
    int packages=-1;MCPluginStoreBytes result={0};status=packages_open(&root,false,&packages,error);
    if(status==MC_PLUGIN_STORE_OK){char name[69];snprintf(name,sizeof(name),"%s.zip",digest);status=read_file(packages,name,MC_PLUGIN_STORE_ZIP_LIMIT,&result,NULL,error);}
    if((status==MC_PLUGIN_STORE_OK || status==MC_PLUGIN_STORE_MISSING) && (!root_current(&root) ||
       (packages>=0 && !directory_current(root.fd,"packages",packages))))status=failure(error,MC_PLUGIN_STORE_STALE,"Package directory changed during read",0);
    if(packages>=0)close(packages);
    root_close(&root);
    if(status==MC_PLUGIN_STORE_OK)*output=result;
    else mc_plugin_store_bytes_free(&result);
    return status;
}
MCPluginStoreStatus mc_plugin_store_replace_snapshot(const char *path,bool expected_exists,
    const uint8_t *expected,size_t expected_size,const uint8_t *replacement,size_t size,MCPluginStoreError *error) {
    error_reset(error);
    if(expected_size>MC_PLUGIN_STORE_SNAPSHOT_LIMIT || size>MC_PLUGIN_STORE_SNAPSHOT_LIMIT ||
       (expected_size && !expected) || (size && !replacement) || (!expected_exists && (expected || expected_size)))
        return failure(error,MC_PLUGIN_STORE_INVALID,"Invalid snapshot byte ranges",0);
    Root root;MCPluginStoreStatus status=root_open(path,true,&root,error);if(status!=MC_PLUGIN_STORE_OK)return status;
    int lock=-1;char temporary[96]={0};struct stat original={0},staging={0};MCPluginStoreBytes current={0};
    status=acquire_lock(&root,&lock,error);if(status!=MC_PLUGIN_STORE_OK)goto done;
    status=read_file(root.fd,"snapshot.bin",MC_PLUGIN_STORE_SNAPSHOT_LIMIT,&current,&original,error);
    if(status!=MC_PLUGIN_STORE_OK && status!=MC_PLUGIN_STORE_MISSING)goto done;
    if(!lock_current(&root,lock)){status=failure(error,MC_PLUGIN_STORE_STALE,"Store or lock changed before CAS",0);goto done;}
    bool exists=status==MC_PLUGIN_STORE_OK;
    if(exists!=expected_exists || (exists && !bytes_equal(&current,expected,expected_size))) {
        status=failure(error,MC_PLUGIN_STORE_STALE,"Snapshot does not match expected bytes or absence",0);goto done;
    }
    if(exists && bytes_equal(&current,replacement,size)){status=sync_committed(root.fd,error);goto done;}
    status=write_temporary(root.fd,replacement,size,temporary,&staging,error);if(status!=MC_PLUGIN_STORE_OK)goto done;
    struct stat observed,temp;
    if(!lock_current(&root,lock) || fstatat(root.fd,temporary,&temp,AT_SYMLINK_NOFOLLOW) || !identity_equal(&temp,&staging) ||
       (exists && (fstatat(root.fd,"snapshot.bin",&observed,AT_SYMLINK_NOFOLLOW) || !file_unchanged(&original,&observed)))) {
        status=failure(error,MC_PLUGIN_STORE_STALE,"Snapshot or storage identity changed before publication",0);goto done;
    }
    int renamed=exists?renameat(root.fd,temporary,root.fd,"snapshot.bin"):rename_exclusive(root.fd,temporary,"snapshot.bin");
    if(renamed){status=failure(error,errno==EEXIST?MC_PLUGIN_STORE_STALE:MC_PLUGIN_STORE_IO,"Cannot publish snapshot",errno);goto done;}
    temporary[0]=0;status=sync_committed(root.fd,error);
done:
    remove_owned(root.fd,temporary,&staging);mc_plugin_store_bytes_free(&current);release_lock(lock);root_close(&root);return status;
}
MCPluginStoreStatus mc_plugin_store_stage_zip(const char *path,const char *digest,const uint8_t *bytes,size_t size,MCPluginStoreError *error) {
    error_reset(error);
    if(!valid_digest(digest) || size>MC_PLUGIN_STORE_ZIP_LIMIT || (size && !bytes))return failure(error,MC_PLUGIN_STORE_INVALID,"Invalid digest or ZIP byte range",0);
    Root root;MCPluginStoreStatus status=root_open(path,true,&root,error);if(status!=MC_PLUGIN_STORE_OK)return status;
    int lock=-1,packages=-1;char temporary[96]={0},name[69];struct stat staging={0};MCPluginStoreBytes current={0};
    snprintf(name,sizeof(name),"%s.zip",digest);
    status=acquire_lock(&root,&lock,error);if(status!=MC_PLUGIN_STORE_OK)goto done;
    status=packages_open(&root,true,&packages,error);if(status!=MC_PLUGIN_STORE_OK)goto done;
    status=read_file(packages,name,MC_PLUGIN_STORE_ZIP_LIMIT,&current,NULL,error);
    if((status==MC_PLUGIN_STORE_OK || status==MC_PLUGIN_STORE_MISSING) &&
       (!lock_current(&root,lock) || !directory_current(root.fd,"packages",packages))) {
        status=failure(error,MC_PLUGIN_STORE_STALE,"Package storage changed during comparison",0);goto done;
    }
    if(status==MC_PLUGIN_STORE_OK){status=bytes_equal(&current,bytes,size)?sync_committed(packages,error):failure(error,MC_PLUGIN_STORE_CONFLICT,"Digest already names different bytes",0);goto done;}
    if(status!=MC_PLUGIN_STORE_MISSING)goto done;
    status=write_temporary(packages,bytes,size,temporary,&staging,error);if(status!=MC_PLUGIN_STORE_OK)goto done;
    struct stat temp;
    if(!lock_current(&root,lock) || !directory_current(root.fd,"packages",packages) ||
       fstatat(packages,temporary,&temp,AT_SYMLINK_NOFOLLOW) || !identity_equal(&staging,&temp)) {
        status=failure(error,MC_PLUGIN_STORE_STALE,"Package storage changed before publication",0);goto done;
    }
    if(rename_exclusive(packages,temporary,name)) {
        if(errno==EEXIST) {
            status=read_file(packages,name,MC_PLUGIN_STORE_ZIP_LIMIT,&current,NULL,error);
            if(status==MC_PLUGIN_STORE_OK)status=bytes_equal(&current,bytes,size)?sync_committed(packages,error):failure(error,MC_PLUGIN_STORE_CONFLICT,"Digest publication conflicts with existing bytes",0);
            else if(status==MC_PLUGIN_STORE_MISSING)status=failure(error,MC_PLUGIN_STORE_STALE,"Digest destination changed during publication",0);
        }else status=failure(error,MC_PLUGIN_STORE_IO,"Cannot exclusively publish ZIP",errno);
        goto done;
    }
    temporary[0]=0;status=sync_committed(packages,error);
done:
    if(packages>=0){remove_owned(packages,temporary,&staging);close(packages);}
    mc_plugin_store_bytes_free(&current);release_lock(lock);root_close(&root);return status;
}

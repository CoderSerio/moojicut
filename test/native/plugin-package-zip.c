#include "platform/shared/plugin_host/package_zip.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

typedef struct { uint8_t *bytes; size_t size, capacity; } Buffer;
typedef struct {
    const char *name;
    const uint8_t *bytes;
    size_t size;
    uint16_t flags, method;
    unsigned descriptor; /* 1 signed, 2 unsigned */
    uint32_t mode;
    const uint8_t *extra;
    size_t extra_size;
} Item;
static unsigned failures, checks;
#define CHECK(value, message) do { ++checks; if (!(value)) { ++failures; fprintf(stderr, "FAIL package ZIP: %s\n", message); } } while (0)

static void append(Buffer *b, const void *bytes, size_t size) {
    if (size > SIZE_MAX - b->size) abort();
    if (b->size + size > b->capacity) {
        b->capacity = (b->size + size) * 2 + 128;
        uint8_t *next = realloc(b->bytes, b->capacity);
        if (!next) abort();
        b->bytes = next;
    }
    if (size) memcpy(b->bytes + b->size, bytes, size);
    b->size += size;
}
static void put16(Buffer *b, uint16_t value) {
    uint8_t bytes[] = {(uint8_t)value, (uint8_t)(value >> 8)};
    append(b, bytes, sizeof(bytes));
}
static void put32(Buffer *b, uint32_t value) {
    put16(b, (uint16_t)value); put16(b, (uint16_t)(value >> 16));
}
static uint32_t get32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void set32(uint8_t *p, uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) p[i] = (uint8_t)(value >> (8u * i));
}
static Buffer compress_raw(const uint8_t *bytes, size_t size) {
    z_stream stream = {0};
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) abort();
    Buffer result = {0};
    result.capacity = (size_t)compressBound((uLong)size);
    result.bytes = malloc(result.capacity);
    if (!result.bytes) abort();
    stream.next_in = (Bytef *)bytes; stream.avail_in = (uInt)size;
    stream.next_out = result.bytes; stream.avail_out = (uInt)result.capacity;
    if (deflate(&stream, Z_FINISH) != Z_STREAM_END) abort();
    result.size = (size_t)stream.total_out;
    deflateEnd(&stream);
    return result;
}
static bool inflate_raw(void *context, const uint8_t *input, size_t input_size,
    uint8_t *output, size_t capacity, size_t *consumed, size_t *written) {
    (void)context;
    z_stream stream = {0};
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return false;
    stream.next_in = (Bytef *)input; stream.avail_in = (uInt)input_size;
    stream.next_out = output; stream.avail_out = (uInt)capacity;
    int status = inflate(&stream, Z_FINISH);
    *consumed = (size_t)stream.total_in; *written = (size_t)stream.total_out;
    inflateEnd(&stream);
    return status == Z_STREAM_END;
}
static bool bad_consumption(void *context, const uint8_t *input, size_t input_size,
    uint8_t *output, size_t capacity, size_t *consumed, size_t *written) {
    bool result = inflate_raw(context, input, input_size, output, capacity, consumed, written);
    if (*consumed) --*consumed;
    return result;
}

/* Independent ZIP writer uses zlib's CRC, not the reader's implementation. */
static Buffer make_zip(const Item *items, size_t count) {
    Buffer local = {0}, central = {0};
    for (size_t i = 0; i < count; ++i) {
        const Item *item = &items[i];
        Buffer packed = item->method == 8 ? compress_raw(item->bytes, item->size) : (Buffer){0};
        const uint8_t *data = item->method == 8 ? packed.bytes : item->bytes;
        size_t size = item->method == 8 ? packed.size : item->size;
        uint16_t flags = (uint16_t)(item->flags | (item->descriptor ? 8u : 0u));
        uint16_t name_size = (uint16_t)strlen(item->name);
        uint32_t crc = (uint32_t)crc32(0, item->bytes, (uInt)item->size), offset = (uint32_t)local.size;
        put32(&local, 0x04034b50); put16(&local, 20); put16(&local, flags); put16(&local, item->method); put32(&local, 0);
        put32(&local, item->descriptor ? 0 : crc); put32(&local, item->descriptor ? 0 : (uint32_t)size);
        put32(&local, item->descriptor ? 0 : (uint32_t)item->size); put16(&local, name_size); put16(&local, (uint16_t)item->extra_size);
        append(&local, item->name, name_size); append(&local, item->extra, item->extra_size); append(&local, data, size);
        if (item->descriptor) {
            if (item->descriptor == 1) put32(&local, 0x08074b50);
            put32(&local, crc); put32(&local, (uint32_t)size); put32(&local, (uint32_t)item->size);
        }
        put32(&central, 0x02014b50); put16(&central, 0x0314); put16(&central, 20); put16(&central, flags); put16(&central, item->method); put32(&central, 0);
        put32(&central, crc); put32(&central, (uint32_t)size); put32(&central, (uint32_t)item->size);
        put16(&central, name_size); put16(&central, (uint16_t)item->extra_size); put16(&central, 0); put16(&central, 0); put16(&central, 0);
        uint32_t mode = item->mode ? item->mode : (item->name[name_size - 1] == '/' ? 0040755u : 0100644u);
        put32(&central, mode << 16); put32(&central, offset); append(&central, item->name, name_size); append(&central, item->extra, item->extra_size);
        free(packed.bytes);
    }
    uint32_t start = (uint32_t)local.size;
    append(&local, central.bytes, central.size);
    put32(&local, 0x06054b50); put16(&local, 0); put16(&local, 0); put16(&local, (uint16_t)count); put16(&local, (uint16_t)count);
    put32(&local, (uint32_t)central.size); put32(&local, start); put16(&local, 0);
    free(central.bytes);
    return local;
}
static bool rejected(const Buffer *zip) {
    MCPluginZipPackage output = {0};
    MCPluginZipError error = MC_PLUGIN_ZIP_OK;
    bool accepted = mc_plugin_zip_read(zip->bytes, zip->size, inflate_raw, NULL, &output, &error);
    bool result = !accepted && error != MC_PLUGIN_ZIP_OK && !output.storage && !output.manifest.bytes && !output.has_icon;
    mc_plugin_zip_clear(&output);
    return result;
}
static void reject_items(const Item *items, size_t count, const char *message) {
    Buffer zip = make_zip(items, count);
    CHECK(rejected(&zip), message);
    free(zip.bytes);
}
static bool content_is(const MCPluginZipBytes *bytes, const Item *item) {
    return bytes->size == item->size && !memcmp(bytes->bytes, item->bytes, item->size);
}
static bool read_fixture(const char *path, Buffer *result) {
    FILE *file = fopen(path, "rb");
    if (!file) return false;
    uint8_t bytes[16384];
    size_t count;
    while ((count = fread(bytes, 1, sizeof(bytes), file))) {
        if (count > MC_PLUGIN_ZIP_MAX_BYTES - result->size) { fclose(file); return false; }
        append(result, bytes, count);
    }
    bool success = !ferror(file);
    if (fclose(file)) success = false;
    return success;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "Usage: plugin-package-zip real-MoonBit-package.zip\n"); return 2; }
    static const uint8_t manifest[] = "{\"opaque\":\"manifest is interpreted by MoonBit\"}";
    static const uint8_t wasm[] = {0, 'a', 's', 'm', 1, 0, 0, 0};
    static const uint8_t icon[] = {0x89, 'P', 'N', 'G', 0};
    Item base[] = {{.name="manifest.json", .bytes=manifest, .size=sizeof(manifest)-1},
                   {.name="plugin.wasm", .bytes=wasm, .size=sizeof(wasm)}};
    Buffer zip = make_zip(base, 2);
    MCPluginZipPackage output = {0}; MCPluginZipError error = MC_PLUGIN_ZIP_OK;
    CHECK(mc_plugin_zip_read(zip.bytes, zip.size, NULL, NULL, &output, &error) && error == MC_PLUGIN_ZIP_OK &&
          content_is(&output.manifest, &base[0]) && content_is(&output.wasm, &base[1]) && !output.has_icon,
          "stored archive requires no inflater and preserves exact bytes");
    void *identity = output.storage;
    CHECK(!mc_plugin_zip_read(zip.bytes, zip.size, NULL, NULL, &output, &error) &&
          error == MC_PLUGIN_ZIP_ARGUMENT && output.storage == identity, "nonempty output is rejected unchanged");
    memset(zip.bytes, 0, zip.size);
    CHECK(content_is(&output.manifest, &base[0]) && content_is(&output.wasm, &base[1]), "result owns independent payload bytes");
    mc_plugin_zip_clear(&output); mc_plugin_zip_clear(&output); free(zip.bytes);
    CHECK(!output.storage && !output.manifest.bytes && !output.has_icon, "clear releases and resets all views");

    for (unsigned descriptor = 0; descriptor <= 2; ++descriptor) {
        Item entries[] = {base[1], {.name="assets/", .method=8}, base[0],
                           {.name="assets/icon.png", .bytes=icon, .size=sizeof(icon)}};
        entries[2].method=8; entries[2].descriptor=descriptor;
        zip=make_zip(entries, 4);
        CHECK(mc_plugin_zip_read(zip.bytes, zip.size, inflate_raw, NULL, &output, &error) &&
              content_is(&output.manifest, &base[0]) && content_is(&output.wasm, &base[1]) &&
              output.has_icon && content_is(&output.icon, &entries[3]), "deflate and signed/unsigned descriptor, directory, reordered entries");
        mc_plugin_zip_clear(&output);
        CHECK(!mc_plugin_zip_read(zip.bytes, zip.size, NULL, NULL, &output, &error) &&
              error == MC_PLUGIN_ZIP_DEFLATE_REQUIRED, "missing decompressor is explicit");
        CHECK(!mc_plugin_zip_read(zip.bytes, zip.size, bad_consumption, NULL, &output, &error) &&
              error == MC_PLUGIN_ZIP_DEFLATE_FAILED, "inflater must consume the entire packed range");
        free(zip.bytes);
    }
    Item empty_icon[] = {base[0],base[1],{.name="assets/icon.png"}};
    zip=make_zip(empty_icon,3);
    CHECK(mc_plugin_zip_read(zip.bytes,zip.size,NULL,NULL,&output,&error) && output.has_icon && output.icon.size==0,
          "empty icon is distinct from absent icon; image validity is outside reader");
    mc_plugin_zip_clear(&output); free(zip.bytes);

    Item bad[] = {base[0],base[1],base[0]};
    reject_items(bad,3,"duplicate entry rejected");
    static const char *const aliases[]={"../manifest.json","/manifest.json","assets/../manifest.json","manifest.json/","MANIFEST.JSON","manifest.json:stream"};
    for(size_t i=0;i<sizeof(aliases)/sizeof(aliases[0]);++i){bad[0]=base[0];bad[0].name=aliases[i];reject_items(bad,2,"only exact container names accepted");}
    bad[0]=base[0];bad[1].mode=0120777;reject_items(bad,2,"symlink mode rejected");bad[1]=base[1];
    const uint16_t flags[]={1,64,8192,16,32};
    for(size_t i=0;i<sizeof(flags)/sizeof(flags[0]);++i){bad[1].flags=flags[i];reject_items(bad,2,"encryption and unsupported flags rejected");}bad[1]=base[1];
    static const uint8_t zip64[]={1,0,0,0};
    bad[1].extra=zip64;bad[1].extra_size=sizeof(zip64);reject_items(bad,2,"ZIP64 extra rejected");bad[1]=base[1];
    static const uint8_t unix_link[]={0x6e,0x75,0,0};
    bad[1].extra=unix_link;bad[1].extra_size=sizeof(unix_link);reject_items(bad,2,"alternate Unix link metadata rejected");bad[1]=base[1];
    static const uint8_t aes[]={1,0x99,0,0};
    bad[1].extra=aes;bad[1].extra_size=sizeof(aes);reject_items(bad,2,"AES metadata cannot bypass encryption flag rejection");bad[1]=base[1];
    Buffer unicode={0};put16(&unicode,0x7075);put16(&unicode,(uint16_t)(5+strlen(base[0].name)));
    uint8_t version=1;append(&unicode,&version,1);put32(&unicode,(uint32_t)crc32(0,(const Bytef *)base[0].name,(uInt)strlen(base[0].name)));
    append(&unicode,base[0].name,strlen(base[0].name));bad[0].extra=unicode.bytes;bad[0].extra_size=unicode.size;
    zip=make_zip(bad,2);
    CHECK(mc_plugin_zip_read(zip.bytes,zip.size,NULL,NULL,&output,&error),"matching Unicode path metadata retains exact canonical name");
    mc_plugin_zip_clear(&output);free(zip.bytes);
    unicode.bytes[9]='X';reject_items(bad,2,"Unicode path metadata cannot override canonical name");free(unicode.bytes);bad[0]=base[0];
    reject_items(base,1,"missing required file rejected");

    zip=make_zip(base,2);
    size_t central=get32(zip.bytes+zip.size-6), second=central+46+strlen(base[0].name);
    uint8_t original=zip.bytes[30];zip.bytes[30]='X';CHECK(rejected(&zip),"central/local names must match");zip.bytes[30]=original;
    original=zip.bytes[30+strlen(base[0].name)];zip.bytes[30+strlen(base[0].name)]^=1;CHECK(rejected(&zip),"payload CRC verified independently");zip.bytes[30+strlen(base[0].name)]=original;
    zip.bytes[zip.size-18]=1;CHECK(rejected(&zip),"multi-disk archive rejected");zip.bytes[zip.size-18]=0;
    uint32_t offset=get32(zip.bytes+second+42);set32(zip.bytes+second+42,0);CHECK(rejected(&zip),"overlapping local records rejected");set32(zip.bytes+second+42,offset);
    set32(zip.bytes+central+24,MC_PLUGIN_ZIP_MAX_MANIFEST_BYTES+1u);CHECK(rejected(&zip),"declared manifest expansion bounded before allocation");set32(zip.bytes+central+24,(uint32_t)base[0].size);
    set32(zip.bytes+second+24,MC_PLUGIN_ZIP_MAX_WASM_BYTES+1u);CHECK(rejected(&zip),"declared Wasm expansion bounded before allocation");set32(zip.bytes+second+24,(uint32_t)base[1].size);
    bool all_truncated=true;
    for(size_t cut=0;cut<zip.size;++cut){Buffer truncated={.bytes=zip.bytes,.size=cut};if(!rejected(&truncated)){all_truncated=false;break;}}
    CHECK(all_truncated,"every truncation of ordinary ZIP rejected");
    CHECK(!mc_plugin_zip_read(zip.bytes,MC_PLUGIN_ZIP_MAX_BYTES+1u,NULL,NULL,&output,&error) && error==MC_PLUGIN_ZIP_LIMIT,"archive byte cap checked before parsing");
    uint8_t record[46+sizeof("manifest.json")-1];
    size_t second_size=46+strlen(base[1].name);
    memcpy(record,zip.bytes+central,sizeof(record));
    memmove(zip.bytes+central,zip.bytes+second,second_size);memcpy(zip.bytes+central+second_size,record,sizeof(record));
    CHECK(mc_plugin_zip_read(zip.bytes,zip.size,NULL,NULL,&output,&error),"central order may differ from contiguous local record order");
    mc_plugin_zip_clear(&output);
    Buffer prefixed={0};uint8_t padding=0;append(&prefixed,&padding,1);append(&prefixed,zip.bytes,zip.size);
    set32(prefixed.bytes+prefixed.size-6,(uint32_t)central+1u);
    set32(prefixed.bytes+central+1+42,offset+1u);set32(prefixed.bytes+central+1+second_size+42,1u);
    CHECK(rejected(&prefixed),"unindexed prefix cannot hide outside contiguous local records");free(prefixed.bytes);
    free(zip.bytes);

    bad[0]=base[0];bad[0].method=8;zip=make_zip(bad,2);central=get32(zip.bytes+zip.size-6);
    set32(zip.bytes+22,1);set32(zip.bytes+central+24,1);
    CHECK(rejected(&zip),"actual inflated bytes cannot exceed declared output");free(zip.bytes);

    Buffer real={0};
    CHECK(read_fixture(argv[1],&real),"real MoonBit ZIP fixture read");
    CHECK(mc_plugin_zip_read(real.bytes,real.size,inflate_raw,NULL,&output,&error) && output.manifest.size>0 &&
          output.wasm.size>sizeof(wasm) && !memcmp(output.wasm.bytes,wasm,sizeof(wasm)),"actual author ZIP decodes to nontrivial Wasm and manifest");
    if(error!=MC_PLUGIN_ZIP_OK)fprintf(stderr,"real ZIP: %s\n",mc_plugin_zip_error_text(error));
    mc_plugin_zip_clear(&output);free(real.bytes);
    printf("package ZIP: %u checks, %u failures\n",checks,failures);
    return failures ? 1 : 0;
}

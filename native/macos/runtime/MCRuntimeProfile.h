#import <Foundation/Foundation.h>

// Production retains its existing locations across upgrades. A test bundle
// carries its own profile even when Finder launches it without environment variables.
static inline BOOL MCRuntimeIsTestProfile(void) {
    id profile = [NSBundle.mainBundle objectForInfoDictionaryKey:@"MoojiCutBuildProfile"];
    return profile != nil && ![profile isEqual:@"production"];
}

static inline NSString *MCRuntimeDefaultsDomain(void) {
    if (MCRuntimeIsTestProfile()) {
        NSString *embedded = [NSBundle.mainBundle objectForInfoDictionaryKey:@"MoojiCutDefaultsDomain"];
        if (embedded.length && ![embedded isEqual:@"dev.mooncap.native.preferences"]) return embedded;
        return [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".preferences"];
    }
    NSString *domain = NSProcessInfo.processInfo.environment[@"MOOJICUT_NATIVE_DEFAULTS_DOMAIN"];
    if (!domain.length) domain = [NSBundle.mainBundle objectForInfoDictionaryKey:@"MoojiCutDefaultsDomain"];
    return domain.length ? domain : @"dev.mooncap.native.preferences";
}

static inline NSURL *MCRuntimeSupportDirectory(NSString *productionDirectory) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *domain = MCRuntimeDefaultsDomain();
    if ([domain isEqual:@"dev.mooncap.native.preferences"])
        return [support URLByAppendingPathComponent:productionDirectory isDirectory:YES];
    NSString *profile = [[domain dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    profile = [[profile stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    return [[support URLByAppendingPathComponent:@"Mooji Cut/Test Profiles" isDirectory:YES]
        URLByAppendingPathComponent:profile isDirectory:YES];
}

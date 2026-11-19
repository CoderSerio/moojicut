#import "MCReleaseSource.h"
#include "bindings/c/update_release.h"

static NSUInteger const MCReleaseMaximumBody = 4 * 1024 * 1024;
static NSError *MCReleaseError(NSInteger code, NSString *text) {
    return [NSError errorWithDomain:@"dev.moojicut.release-source" code:code userInfo:@{NSLocalizedDescriptionKey:text}];
}
@interface MCReleaseIndexSource () <NSURLSessionDataDelegate>
@property NSURLSessionConfiguration *configuration;
@property NSURLSession *session;
@property NSURLSessionDataTask *task;
@property NSMutableData *body;
@property BOOL tryingMirror;
@property (copy) MCReleaseSourceCompletion completion;
@end

@implementation MCReleaseIndexSource
- (instancetype)init { return [self initWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration]; }
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration {
    if ((self = [super init])) {
        _configuration = [configuration copy];
        _configuration.timeoutIntervalForRequest = 15;
        _configuration.timeoutIntervalForResource = 30;
        _configuration.waitsForConnectivity = NO;
        _configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _configuration.URLCache = nil;
        _configuration.HTTPCookieStorage = nil;
    }
    return self;
}
- (void)fetchReleases:(MCReleaseSourceCompletion)completion {
    NSAssert(NSThread.isMainThread, @"Release source is main-thread only");
    if (self.task) { completion(nil, MCReleaseError(1, @"正在检查更新，请稍候。")); return; }
    self.completion = completion;
    [self startRequestUsingMirror:YES];
}
- (void)startRequestUsingMirror:(BOOL)mirror {
    self.tryingMirror = mirror;
    self.body = [NSMutableData data];
    NSURLSessionConfiguration *configuration = [self.configuration copy];
    if (mirror) configuration.timeoutIntervalForResource = 8;
    self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:mirror ? @MC_UPDATE_MIRROR_INDEX : @MC_UPDATE_GITHUB_INDEX]];
    request.timeoutInterval = mirror ? 8 : 15;
    [request setValue:mirror ? @"application/json" : @"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    if (!mirror) [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:@"Mooji-Cut-update-check" forHTTPHeaderField:@"User-Agent"];
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
}
- (void)finishWithError:(NSError *)error {
    MCReleaseSourceCompletion completion = self.completion;
    NSData *data = error ? nil : [self.body copy];
    self.completion = nil; self.body = nil; self.task = nil;
    NSURLSession *session = self.session; self.session = nil;
    [session invalidateAndCancel];
    if (completion) completion(data, error);
}
- (void)completeAttemptWithError:(NSError *)error {
    if (self.tryingMirror && !error) {
        NSString *text = [[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding];
        int32_t handle = 0;
        if (text) {
            NSString *sampleVersion = @"0.0.0-alpha.1";
            moonbit_string_t current = moonbit_make_string_raw((int32_t)sampleVersion.length);
            [sampleVersion getCharacters:current range:NSMakeRange(0, sampleVersion.length)];
            moonbit_string_t body = moonbit_make_string_raw((int32_t)text.length);
            [text getCharacters:body range:NSMakeRange(0, text.length)];
            handle = update_release_create(current, MC_UPDATE_MACOS_ARM64, body);
            moonbit_decref(body); moonbit_decref(current);
        }
        if (handle) update_release_dispose(handle);
        else error = MCReleaseError(5, @"镜像返回了无效更新信息。");
    }
    if (self.tryingMirror && error) {
        NSURLSession *previous = self.session;
        self.session = nil; self.task = nil;
        [previous invalidateAndCancel];
        [self startRequestUsingMirror:NO];
    } else [self finishWithError:error];
}
- (void)cancel {
    NSAssert(NSThread.isMainThread, @"Release source is main-thread only");
    if (self.task) [self finishWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled
        userInfo:@{NSLocalizedDescriptionKey:@"更新检查已取消。"}]];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if (session != self.session || task != self.task) { completionHandler(NSURLSessionResponseCancel); return; }
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
    NSError *error = nil;
    if (http.statusCode != 200) {
        NSString *message = !self.tryingMirror && (http.statusCode == 403 || http.statusCode == 429) ? @"GitHub 暂时限制了更新请求，请稍后重试。" :
            [NSString stringWithFormat:@"更新服务暂时不可用（HTTP %ld）。", (long)http.statusCode];
        error = MCReleaseError(http.statusCode, message);
    } else if (response.expectedContentLength > (int64_t)MCReleaseMaximumBody)
        error = MCReleaseError(2, @"更新列表过大，已停止读取。请稍后重试。");
    else if ([http valueForHTTPHeaderField:@"Link"].length && [[http valueForHTTPHeaderField:@"Link"] containsString:@"rel=\"next\""])
        error = MCReleaseError(3, @"更新列表超出当前支持范围，请从发布页面确认最新版本。");
    completionHandler(error ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
    if (error) [self completeAttemptWithError:error];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (session != self.session || task != self.task) return;
    if (data.length > MCReleaseMaximumBody - self.body.length) {
        [self completeAttemptWithError:MCReleaseError(2, @"更新列表过大，已停止读取。请稍后重试。")]; return;
    }
    [self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (session != self.session || task != self.task) return;
    [self completeAttemptWithError:error];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    (void)response; (void)request;
    // The public API has a fixed repository identity. Never follow a redirect
    // to a login page, renamed owner, or a different update provider.
    completionHandler(nil);
    if (session == self.session && task == self.task)
        [self completeAttemptWithError:MCReleaseError(4, @"更新地址发生变化，请从发布页面确认。")];
}
@end

#import "MCReleaseSource.h"

static NSUInteger const MCReleaseMaximumBody = 4 * 1024 * 1024;
static NSError *MCReleaseError(NSInteger code, NSString *text) {
    return [NSError errorWithDomain:@"dev.moojicut.release-source" code:code userInfo:@{NSLocalizedDescriptionKey:text}];
}
@interface MCGitHubReleaseSource () <NSURLSessionDataDelegate>
@property NSURLSessionConfiguration *configuration;
@property NSURLSession *session;
@property NSURLSessionDataTask *task;
@property NSMutableData *body;
@property (copy) MCReleaseSourceCompletion completion;
@end

@implementation MCGitHubReleaseSource
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
    self.body = [NSMutableData data];
    self.session = [NSURLSession sessionWithConfiguration:self.configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.github.com/repos/CoderSerio/moojicut/releases?per_page=100"]];
    request.timeoutInterval = 15;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
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
        NSString *message = http.statusCode == 403 || http.statusCode == 429 ? @"GitHub 暂时限制了更新请求，请稍后重试。" :
            [NSString stringWithFormat:@"更新服务暂时不可用（HTTP %ld）。", (long)http.statusCode];
        error = MCReleaseError(http.statusCode, message);
    } else if (response.expectedContentLength > (int64_t)MCReleaseMaximumBody)
        error = MCReleaseError(2, @"更新列表过大，已停止读取。请稍后重试。");
    else if ([http valueForHTTPHeaderField:@"Link"].length && [[http valueForHTTPHeaderField:@"Link"] containsString:@"rel=\"next\""])
        error = MCReleaseError(3, @"更新列表超出当前支持范围，请从发布页面确认最新版本。");
    completionHandler(error ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
    if (error) [self finishWithError:error];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (session != self.session || task != self.task) return;
    if (data.length > MCReleaseMaximumBody - self.body.length) {
        [self finishWithError:MCReleaseError(2, @"更新列表过大，已停止读取。请稍后重试。")]; return;
    }
    [self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (session != self.session || task != self.task) return;
    [self finishWithError:error];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    (void)response; (void)request;
    // The public API has a fixed repository identity. Never follow a redirect
    // to a login page, renamed owner, or a different update provider.
    completionHandler(nil);
    if (session == self.session && task == self.task)
        [self finishWithError:MCReleaseError(4, @"更新地址发生变化，请从发布页面确认。")];
}
@end

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^MCReleaseSourceCompletion)(NSData * _Nullable body, NSError * _Nullable error);
// Transport only. Version/channel/asset policy belongs to the MoonBit core.
@protocol MCReleaseSource <NSObject>
- (void)fetchReleases:(MCReleaseSourceCompletion)completion;
- (void)cancel;
@end

@interface MCReleaseIndexSource : NSObject <MCReleaseSource>
- (instancetype)init;
// Allows NSURLProtocol fixtures without touching the network or installer.
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration;
@end
NS_ASSUME_NONNULL_END

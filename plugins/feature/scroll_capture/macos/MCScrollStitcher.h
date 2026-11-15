#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
// A bounded, single-direction stitcher. Call it from one serial queue. A rejected
// frame never modifies the accepted image or reference frame.
typedef NS_ENUM(NSInteger, MCScrollAppendResult) {
    MCScrollAppendFirstFrame,
    MCScrollAppendDuplicate,
    MCScrollAppendExtended,
    MCScrollAppendRejected,
};
@interface MCScrollStitcher : NSObject
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) NSUInteger acceptedFrames;
@property (nonatomic, readonly) NSUInteger lastOffset;
@property (nonatomic, readonly) NSUInteger fixedHeaderHeight;
@property (nonatomic, readonly) NSUInteger fixedFooterHeight;
- (MCScrollAppendResult)appendPNGData:(NSData *)data error:(NSError **)error;
- (nullable NSData *)PNGDataWithError:(NSError **)error;
// Maximum final dimensions: 24,000 rows and 12 million pixels. Individual
// frames are limited to 4 million pixels, 4096 pixels per side, and 16 MiB PNG.
@end
NS_ASSUME_NONNULL_END

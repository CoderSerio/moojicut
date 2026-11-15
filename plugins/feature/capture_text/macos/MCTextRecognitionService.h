#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSErrorDomain const MCTextRecognitionErrorDomain;
typedef NS_ERROR_ENUM(MCTextRecognitionErrorDomain, MCTextRecognitionError) {
    MCTextRecognitionInvalidImage = 1,
    MCTextRecognitionImageTooLarge = 2,
    MCTextRecognitionCancelled = 3,
    MCTextRecognitionOutputTooLarge = 4,
    MCTextRecognitionServiceFailed = 5,
};

@protocol MCTextRecognitionTask <NSObject>
- (void)cancel;
@end

@protocol MCTextRecognizing <NSObject>
// The completion runs exactly once on the main queue, including cancellation.
// Empty text with no error means that Vision did not find any text.
- (id<MCTextRecognitionTask>)recognizePNGData:(NSData *)data
                                 completion:(void (^)(NSString * _Nullable text, NSError * _Nullable error))completion;
@end

// On-device Vision runs on a bounded serial worker, without uploads or persistence.
@interface MCTextRecognitionService : NSObject <MCTextRecognizing>
@end
NS_ASSUME_NONNULL_END

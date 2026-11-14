#import "MCStyleControls.h"
#include "../../shared/editor_style.h"

NS_ASSUME_NONNULL_BEGIN
typedef struct {
    int32_t rgb;
    double opacity;
    double stroke;
    double fontSize;
} MCStyleValues;

// A reusable property row. Its displayed values belong to the caller; the view
// knows neither the document nor the per-tool default store.
@interface MCStylePropertiesView : NSStackView
@property (nonatomic, readonly) MCColorControl *colorControl;
@property (nonatomic, readonly) MCNumberControl *fontControl;
@property (nonatomic, readonly) MCNumberControl *strokeControl;
@property (nonatomic, readonly) NSTextField *status;
@property (nonatomic) MCStyleValues values;
@property (nonatomic) int32_t propertyMask;
@property (nonatomic, copy, nullable) void (^onChange)(id sender);
- (int32_t)syncFromSender:(nullable id)sender;
- (void)showMessage:(NSString *)message;
@end
NS_ASSUME_NONNULL_END

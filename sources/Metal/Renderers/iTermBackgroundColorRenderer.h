#import "iTermMetalCellRenderer.h"

NS_ASSUME_NONNULL_BEGIN

@interface iTermBackgroundColorRenderer : NSObject<iTermMetalCellRenderer>

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)setColorData:(NSData *)colorData
                 row:(int)row
               width:(int)width;

@end

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "iTermMetalGlyphKey.h"

@class iTermTextureArray;

@interface iTermTextureMap : NSObject

// Given in number of cells
@property (nonatomic, readonly) NSInteger capacity;
@property (nonatomic, readonly) iTermTextureArray *array;
@property (nonatomic, readonly) iTermTextureArray *stage;
@property (nonatomic, copy) NSString *label;

- (instancetype)initWithDevice:(id<MTLDevice>)device
                      cellSize:(CGSize)cellSize
                      capacity:(NSInteger)capacity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)startNewFrame;
- (NSInteger)findOrAllocateIndexOfLockedTextureWithKey:(const iTermMetalGlyphKey *)key
                                                column:(int)column
                                              creation:(NSImage *(^)(int))creation;

- (void)unlockTextureWithIndex:(NSInteger)index;

- (void)blitNewTexturesFromStagingAreaWithCompletion:(void (^)(void))completion;


@end

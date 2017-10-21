@import simd;
@import MetalKit;

#import "DebugLogging.h"
#import "iTermTextureArray.h"
#import "iTermMetalDriver.h"
#import "iTermBackgroundImageRenderer.h"
#import "iTermBackgroundColorRenderer.h"
#import "iTermBadgeRenderer.h"
#import "iTermBroadcastStripesRenderer.h"
#import "iTermCursorGuideRenderer.h"
#import "iTermCursorRenderer.h"
#import "iTermMarkRenderer.h"
#import "iTermPreciseTimer.h"
#import "iTermTextRenderer.h"
#import "iTermTextureMap.h"

#import "iTermShaderTypes.h"

@implementation iTermMetalCursorInfo
@end

@interface iTermMetalDriverContext : NSObject
@property (nonatomic, strong) iTermTextRendererContext *textContext;
@property (nonatomic, strong) iTermMetalCursorInfo *cursorInfo;
@end

@implementation iTermMetalDriverContext
@end

@interface iTermMetalDriver()
@property (atomic) BOOL busy;
@end

@implementation iTermMetalDriver {
    iTermBackgroundImageRenderer *_backgroundImageRenderer;
    iTermBackgroundColorRenderer *_backgroundColorRenderer;
    iTermTextRenderer *_textRenderer;
    iTermMarkRenderer *_markRenderer;
    iTermBadgeRenderer *_badgeRenderer;
    iTermBroadcastStripesRenderer *_broadcastStripesRenderer;
    iTermCursorGuideRenderer *_cursorGuideRenderer;
    iTermCursorRenderer *_underlineCursorRenderer;
    iTermCursorRenderer *_barCursorRenderer;
    iTermCursorRenderer *_blockCursorRenderer;
    iTermCopyModeCursorRenderer *_copyModeCursorRenderer;

    // The command Queue from which we'll obtain command buffers
    id<MTLCommandQueue> _commandQueue;

    // The current size of our view so we can use this in our render pipeline
    vector_uint2 _viewportSize;
    CGSize _cellSize;
//    int _iteration;
    int _rows;
    int _columns;
    BOOL _sizeChanged;
    CGFloat _scale;

    dispatch_queue_t _queue;

    iTermPreciseTimerStats _mainThreadStats;
    iTermPreciseTimerStats _dispatchStats;
    iTermPreciseTimerStats _blitStats;
    iTermPreciseTimerStats _metalSetupStats;
    iTermPreciseTimerStats _renderingStats;
    iTermPreciseTimerStats _preparingStats;
    iTermPreciseTimerStats _endToEnd;
    int _dropped;
    int _total;
}

- (nullable instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView {
    self = [super init];
    if (self) {
        _backgroundImageRenderer = [[iTermBackgroundImageRenderer alloc] initWithDevice:mtkView.device];
        _textRenderer = [[iTermTextRenderer alloc] initWithDevice:mtkView.device];
        _backgroundColorRenderer = [[iTermBackgroundColorRenderer alloc] initWithDevice:mtkView.device];
        _markRenderer = [[iTermMarkRenderer alloc] initWithDevice:mtkView.device];
        _badgeRenderer = [[iTermBadgeRenderer alloc] initWithDevice:mtkView.device];
        _broadcastStripesRenderer = [[iTermBroadcastStripesRenderer alloc] initWithDevice:mtkView.device];
        _cursorGuideRenderer = [[iTermCursorGuideRenderer alloc] initWithDevice:mtkView.device];
        _underlineCursorRenderer = [iTermCursorRenderer newUnderlineCursorRendererWithDevice:mtkView.device];
        _barCursorRenderer = [iTermCursorRenderer newBarCursorRendererWithDevice:mtkView.device];
        _blockCursorRenderer = [iTermCursorRenderer newBlockCursorRendererWithDevice:mtkView.device];
        _copyModeCursorRenderer = [iTermCursorRenderer newCopyModeCursorRendererWithDevice:mtkView.device];
        _commandQueue = [mtkView.device newCommandQueue];
        _queue = dispatch_queue_create("com.iterm2.metalDriver", NULL);
        [self setCellSize:CGSizeMake(30, 30) gridSize:VT100GridSizeMake(80, 25) scale:1];


        iTermPreciseTimerStatsInit(&_mainThreadStats, "main thread");
        iTermPreciseTimerStatsInit(&_dispatchStats, "dispatch");
        iTermPreciseTimerStatsInit(&_preparingStats, "preparing");
        iTermPreciseTimerStatsInit(&_blitStats, "blit");
        iTermPreciseTimerStatsInit(&_metalSetupStats, "metal setup");
        iTermPreciseTimerStatsInit(&_renderingStats, "rendering");
        iTermPreciseTimerStatsInit(&_endToEnd, "end to end");

    }

    return self;
}

- (NSArray<id<iTermMetalCellRenderer>> *)cellRenderers {
    return @[ _textRenderer,
              _backgroundColorRenderer,
              _markRenderer,
              _cursorGuideRenderer,
              _underlineCursorRenderer,
              _barCursorRenderer,
              _blockCursorRenderer,
              _copyModeCursorRenderer ];
}

- (NSArray<id<iTermMetalRenderer>> *)renderers {
    NSArray *nonCellRenderers = @[ _backgroundImageRenderer,
                                   _badgeRenderer,
                                   _broadcastStripesRenderer ];
    return [self.cellRenderers arrayByAddingObjectsFromArray:nonCellRenderers];
}

- (void)setCellSize:(CGSize)cellSize gridSize:(VT100GridSize)gridSize scale:(CGFloat)scale {
    scale = MAX(1, scale);
    cellSize.width *= scale;
    cellSize.height *= scale;
    dispatch_async(_queue, ^{
        if (scale == 0) {
            NSLog(@"Warning: scale is 0");
        }
        NSLog(@"Cell size is now %@x%@, grid size is now %@x%@", @(cellSize.width), @(cellSize.height), @(gridSize.width), @(gridSize.height));
        _sizeChanged = YES;
        _cellSize = cellSize;
        _rows = MAX(1, gridSize.height);
        _columns = MAX(1, gridSize.width);
        _scale = scale;
    });
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
    dispatch_async(_queue, ^{
        // Save the size of the drawable as we'll pass these
        //   values to our vertex shader when we draw
        _viewportSize.x = size.width;
        _viewportSize.y = size.height;
    });
}

- (iTermMetalDriverContext *)updateRenderersWithDataSource:(id<iTermMetalDriverDataSource>)dataSource {
//    _iteration++;
    iTermMetalDriverContext *context = [[iTermMetalDriverContext alloc] init];
    context.textContext = [[iTermTextRendererContext alloc] initWithQueue:_queue];
    context.cursorInfo = [_dataSource metalDriverCursorInfo];
    if (context.cursorInfo.cursorVisible) {
        switch (context.cursorInfo.type) {
            case CURSOR_UNDERLINE:
                [_underlineCursorRenderer setCoord:context.cursorInfo.coord];
                [_underlineCursorRenderer setColor:context.cursorInfo.cursorColor];
                break;
            case CURSOR_BOX:
                [_blockCursorRenderer setCoord:context.cursorInfo.coord];
                [_blockCursorRenderer setColor:context.cursorInfo.cursorColor];
                break;
            case CURSOR_VERTICAL:
                [_barCursorRenderer setCoord:context.cursorInfo.coord];
                [_barCursorRenderer setColor:context.cursorInfo.cursorColor];
                break;
            case CURSOR_DEFAULT:
                break;
        }
    }

    if (context.cursorInfo) {
        [_blockCursorRenderer setCoord:context.cursorInfo.coord];
    }
//    [_underlineCursorRenderer setCoord:(VT100GridCoord){ 2, 2 }];
//    [_barCursorRenderer setCoord:(VT100GridCoord){ 3, 3 }];
//    [_copyModeCursorRenderer setCoord:(VT100GridCoord){4, 4}];
//    _copyModeCursorRenderer.selecting = !((_iteration / 30) % 2);
//
//    [_cursorGuideRenderer setRow:(_iteration / 10) % _rows];
//
//    [_markRenderer setMarkStyle:iTermMarkStyleNone
//                            row:((_iteration + 0) % _rows)];
//    [_markRenderer setMarkStyle:iTermMarkStyleSuccess
//                            row:((_iteration + 1) % _rows)];
//    [_markRenderer setMarkStyle:iTermMarkStyleFailure
//                            row:((_iteration + 2) % _rows)];
//    [_markRenderer setMarkStyle:iTermMarkStyleOther
//                            row:((_iteration + 3) % _rows)];

    CGSize cellSize = _cellSize;
    CGFloat scale = _scale;
    [_textRenderer startNewFrame];
    for (int y = 0; y < _rows; y++) {
        NSMutableData *keysData = [NSMutableData dataWithLength:sizeof(iTermMetalGlyphKey) * _columns];
        NSMutableData *attributesData = [NSMutableData dataWithLength:sizeof(iTermMetalGlyphAttributes) * _columns];
        NSMutableData *backgroundColorData = [NSMutableData dataWithLength:sizeof(vector_float4) * _columns];
        [_dataSource metalGetGlyphKeys:keysData.mutableBytes
                            attributes:attributesData.mutableBytes
                            background:backgroundColorData.mutableBytes
                                   row:y
                                 width:_columns];
        [_textRenderer setGlyphKeysData:keysData
                         attributesData:attributesData
                                    row:y
                                context:context.textContext
                               creation:^NSImage *(int x) {
                                   return [dataSource metalImageForCharacterAtCoord:VT100GridCoordMake(x, y)
                                                                               size:cellSize
                                                                              scale:scale];
                               }];
        [_backgroundColorRenderer setColorData:backgroundColorData
                                           row:y
                                         width:_columns];
    }

    return context;
}

/// Called whenever the view needs to render a frame
- (void)drawInMTKView:(nonnull MTKView *)view {
    id<iTermMetalDriverDataSource> dataSource = _dataSource;
    _total++;
    if (self.busy) {
        NSLog(@"  abort: busy (dropped %@%%)", @((_dropped * 100)/_total));
        _dropped++;
        return;
    }
    DLog(@"Not busy");

    iTermPreciseTimerStatsStartTimer(&_endToEnd);
    iTermPreciseTimerStatsStartTimer(&_mainThreadStats);
    [dataSource metalDriverWillBeginDrawingFrame];
    self.busy = YES;
    DLog(@"Set busy=yes");
    
    iTermPreciseTimerStatsMeasureAndRecordTimer(&_mainThreadStats);
    iTermPreciseTimerStatsStartTimer(&_dispatchStats);
    dispatch_async(_queue, ^{
        iTermPreciseTimerStatsMeasureAndRecordTimer(&_dispatchStats);

        iTermPreciseTimerStatsStartTimer(&_preparingStats);
        if (_cellSize.width == 0 || _cellSize.height == 0) {
            DLog(@"  abort: uninitialized");
            self.busy = NO;
            return;
        }
        assert(!_textRenderer.preparing);
        if (_sizeChanged) {
            [self.renderers enumerateObjectsUsingBlock:^(id<iTermMetalCellRenderer>  _Nonnull renderer, NSUInteger idx, BOOL * _Nonnull stop) {
                [renderer setViewportSize:_viewportSize];
            }];
            [self.cellRenderers enumerateObjectsUsingBlock:^(id<iTermMetalCellRenderer>  _Nonnull renderer, NSUInteger idx, BOOL * _Nonnull stop) {
                [renderer setCellSize:_cellSize];
                [renderer setGridSize:(VT100GridSize){ MAX(1, _columns), MAX(1, _rows) }];
            }];
            _sizeChanged = NO;
        }

        DLog(@"  Updating");
        iTermMetalDriverContext* context = [self updateRenderersWithDataSource:dataSource];
        DLog(@"  Preparing");
        iTermPreciseTimerStatsMeasureAndRecordTimer(&_preparingStats);
        iTermPreciseTimerStatsStartTimer(&_blitStats);
        [_textRenderer prepareForDrawWithContext:context.textContext
                                      completion:^{
                                          iTermPreciseTimerStatsMeasureAndRecordTimer(&_blitStats);
                                          [self reallyDrawInView:view context:context];
                                      }];
    });
}

- (void)reallyDrawInView:(MTKView *)view
                 context:(iTermMetalDriverContext *)context {
    iTermPreciseTimerStatsStartTimer(&_metalSetupStats);
    DLog(@"  Really drawing");
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"Draw Terminal";

    MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;
    if (renderPassDescriptor != nil) {
        id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        renderEncoder.label = @"Render Terminal";
        view.currentDrawable.texture.label = @"Drawable";

        // Set the region of the drawable to which we'll draw.
        MTLViewport viewport = {
            -(double)_viewportSize.x,
            0.0,
            _viewportSize.x * 2,
            _viewportSize.y * 2,
            -1.0,
            1.0
        };
        [renderEncoder setViewport:viewport];

//        [_backgroundImageRenderer drawWithRenderEncoder:renderEncoder];
        [_backgroundColorRenderer drawWithRenderEncoder:renderEncoder];
//        [_broadcastStripesRenderer drawWithRenderEncoder:renderEncoder];
//        [_badgeRenderer drawWithRenderEncoder:renderEncoder];
//        [_cursorGuideRenderer drawWithRenderEncoder:renderEncoder];
//
        if (context.cursorInfo.cursorVisible) {
            switch (context.cursorInfo.type) {
                case CURSOR_UNDERLINE:
                    [_underlineCursorRenderer drawWithRenderEncoder:renderEncoder];
                    break;
                case CURSOR_BOX:
                    [_blockCursorRenderer drawWithRenderEncoder:renderEncoder];
                    break;
                case CURSOR_VERTICAL:
                    [_barCursorRenderer drawWithRenderEncoder:renderEncoder];
                    break;
                case CURSOR_DEFAULT:
                    break;
            }
        }
//        [_copyModeCursorRenderer drawWithRenderEncoder:renderEncoder];

        [_textRenderer drawWithRenderEncoder:renderEncoder context:context.textContext];

        [_markRenderer drawWithRenderEncoder:renderEncoder];

        [renderEncoder endEncoding];

        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull buffer) {
            iTermPreciseTimerStatsMeasureAndRecordTimer(&_renderingStats);
            iTermPreciseTimerStatsMeasureAndRecordTimer(&_endToEnd);

            DLog(@"  Completed");
            [_textRenderer releaseContext:context.textContext];

            iTermPreciseTimerStats stats[] = {
                _mainThreadStats,
                _dispatchStats,
                _preparingStats,
                _blitStats,
                _renderingStats,
                _endToEnd
            };
            iTermPreciseTimerPeriodicLog(stats, sizeof(stats) / sizeof(*stats), 1, YES);

            self.busy = NO;
        }];

        [commandBuffer presentDrawable:view.currentDrawable];
        [commandBuffer commit];
        iTermPreciseTimerStatsMeasureAndRecordTimer(&_metalSetupStats);
        iTermPreciseTimerStatsStartTimer(&_renderingStats);
    } else {
        [commandBuffer commit];
    }
}

@end


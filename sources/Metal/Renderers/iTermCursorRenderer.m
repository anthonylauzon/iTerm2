#import "iTermCursorRenderer.h"

NS_ASSUME_NONNULL_BEGIN

@interface iTermUnderlineCursorRenderer : iTermCursorRenderer
@end

@interface iTermBarCursorRenderer : iTermCursorRenderer
@end

@interface iTermBlockCursorRenderer : iTermCursorRenderer
@end

@implementation iTermCursorRenderer {
@protected
    iTermMetalCellRenderer *_cellRenderer;
    NSColor *_color;
    VT100GridCoord _coord;
}

+ (instancetype)newUnderlineCursorRendererWithDevice:(id<MTLDevice>)device {
    return [[iTermUnderlineCursorRenderer alloc] initWithDevice:device];
}

+ (instancetype)newBarCursorRendererWithDevice:(id<MTLDevice>)device {
    return [[iTermBarCursorRenderer alloc] initWithDevice:device];
}

+ (instancetype)newBlockCursorRendererWithDevice:(id<MTLDevice>)device {
    return [[iTermBlockCursorRenderer alloc] initWithDevice:device];
}

+ (instancetype)newCopyModeCursorRendererWithDevice:(id<MTLDevice>)device {
    return [[iTermCopyModeCursorRenderer alloc] initWithDevice:device
                                            vertexFunctionName:@"iTermTextureCursorVertexShader"
                                          fragmentFunctionName:@"iTermTextureCursorFragmentShader"];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
            vertexFunctionName:(NSString *)vertexFunctionName
          fragmentFunctionName:(NSString *)fragmentFunctionName {
    self = [super init];
    if (self) {
        _color = [NSColor colorWithRed:1 green:1 blue:1 alpha:1];
        _cellRenderer = [[iTermMetalCellRenderer alloc] initWithDevice:device
                                                    vertexFunctionName:vertexFunctionName
                                                  fragmentFunctionName:fragmentFunctionName
                                                              blending:YES
                                                        piuElementSize:0];
    }
    return self;
}
    
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    return [self initWithDevice:device
             vertexFunctionName:@"iTermCursorVertexShader"
           fragmentFunctionName:@"iTermCursorFragmentShader"];
}

- (void)setCellSize:(CGSize)cellSize {
    [_cellRenderer setCellSize:cellSize];
}

- (void)setGridSize:(VT100GridSize)gridSize {
    [_cellRenderer setGridSize:gridSize];
}

- (void)setViewportSize:(vector_uint2)viewportSize {
    [_cellRenderer setViewportSize:viewportSize];
}

- (void)setColor:(NSColor *)color {
    _color = color;
}

- (void)setCoord:(VT100GridCoord)coord {
    _coord = coord;
}

- (void)drawWithRenderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder {
    iTermCursorDescription description = {
        .origin = {
            _cellRenderer.cellSize.width * _coord.x,
            _cellRenderer.cellSize.height * (_cellRenderer.gridSize.height - _coord.y - 1),
        },
        .color = {
            _color.redComponent,
            _color.greenComponent,
            _color.blueComponent,
            1
        }
    };
    id<MTLBuffer> descriptionBuffer = [_cellRenderer.device newBufferWithBytes:&description
                                                                        length:sizeof(description)
                                                                       options:MTLResourceStorageModeManaged];

    [_cellRenderer drawPipeline:_cellRenderer.pipelineState
                  renderEncoder:renderEncoder
               numberOfVertices:6
                   numberOfPIUs:_cellRenderer.gridSize.width
                  vertexBuffers:@{ @(iTermVertexInputIndexVertices): _cellRenderer.vertexBuffer,
                                   @(iTermVertexInputIndexCursorDescription): descriptionBuffer,
                                   @(iTermVertexInputIndexOffset): _cellRenderer.offsetBuffer }
                       textures:@{ } ];
}

@end

@implementation iTermUnderlineCursorRenderer

- (void)setCellSize:(CGSize)cellSize {
    [super setCellSize:cellSize];
    _cellRenderer.vertexBuffer = [_cellRenderer newQuadOfSize:CGSizeMake(cellSize.width, 2)];
}

@end

@implementation iTermBarCursorRenderer

- (void)setCellSize:(CGSize)cellSize {
    [super setCellSize:cellSize];
    _cellRenderer.vertexBuffer = [_cellRenderer newQuadOfSize:CGSizeMake(2, cellSize.height)];
}

@end

@implementation iTermBlockCursorRenderer

- (void)setCellSize:(CGSize)cellSize {
    [super setCellSize:cellSize];
    _cellRenderer.vertexBuffer = [_cellRenderer newQuadOfSize:CGSizeMake(cellSize.width, cellSize.height)];
}

@end

@implementation iTermCopyModeCursorRenderer {
    id<MTLTexture> _texture;
}

- (void)setCellSize:(CGSize)cellSize {
    [super setCellSize:cellSize];
    _texture = nil;
    _cellRenderer.vertexBuffer = [_cellRenderer newQuadOfSize:CGSizeMake(cellSize.width, cellSize.height)];

}

- (void)setSelecting:(BOOL)selecting {
    _selecting = selecting;
    _color = selecting ? [NSColor colorWithRed:0xc1 / 255.0 green:0xde / 255.0 blue:0xff / 255.0 alpha:1] : [NSColor whiteColor];
    _texture = nil;
}

- (NSImage *)newImage {
    NSImage *image = [[NSImage alloc] initWithSize:_cellRenderer.cellSize];

    [image lockFocus];
    const CGFloat heightFraction = 1 / 3.0;
    const CGFloat scale = 2;
    NSRect rect = NSMakeRect(scale / 2,
                             scale / 2,
                             _cellRenderer.cellSize.width,
                             _cellRenderer.cellSize.height - scale / 2);
    NSRect cursorRect = NSMakeRect(scale / 2,
                                   rect.size.height * (1 - heightFraction) + scale / 2,
                                   rect.size.width,
                                   _cellRenderer.cellSize.height * heightFraction - scale / 2);
    const CGFloat r = (self.selecting ? 2 : 1) * scale;

    NSBezierPath *path = [[NSBezierPath alloc] init];
    [path moveToPoint:NSMakePoint(NSMinX(cursorRect), NSMaxY(cursorRect))];
    [path lineToPoint:NSMakePoint(NSMidX(cursorRect) - r, NSMinY(cursorRect))];
    [path lineToPoint:NSMakePoint(NSMidX(cursorRect) - r, NSMinY(rect))];
    [path lineToPoint:NSMakePoint(NSMidX(cursorRect) + r, NSMinY(rect))];
    [path lineToPoint:NSMakePoint(NSMidX(cursorRect) + r, NSMinY(cursorRect))];
    [path lineToPoint:NSMakePoint(NSMaxX(cursorRect), NSMaxY(cursorRect))];
    [path lineToPoint:NSMakePoint(NSMinX(cursorRect), NSMaxY(cursorRect))];
    [_color set];
    [path fill];

    [[NSColor blackColor] set];
    [path setLineWidth:scale];
    [path stroke];
    [image unlockFocus];

    return image;
}

- (void)drawWithRenderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder {
    iTermCursorDescription description = {
        .origin = {
            _cellRenderer.cellSize.width * _coord.x - _cellRenderer.cellSize.width / 2,
            _cellRenderer.cellSize.height * (_cellRenderer.gridSize.height - _coord.y - 1),
        },
    };
    id<MTLBuffer> descriptionBuffer = [_cellRenderer.device newBufferWithBytes:&description
                                                                        length:sizeof(description)
                                                                       options:MTLResourceStorageModeManaged];
    if (_texture == nil) {
        _texture = [_cellRenderer textureFromImage:[self newImage]];
    }
    [_cellRenderer drawPipeline:_cellRenderer.pipelineState
                  renderEncoder:renderEncoder
               numberOfVertices:6
                   numberOfPIUs:_cellRenderer.gridSize.width
                  vertexBuffers:@{ @(iTermVertexInputIndexVertices): _cellRenderer.vertexBuffer,
                                   @(iTermVertexInputIndexCursorDescription): descriptionBuffer,
                                   @(iTermVertexInputIndexOffset): _cellRenderer.offsetBuffer }
                       textures:@{ @(iTermTextureIndexPrimary): _texture } ];
}

@end

NS_ASSUME_NONNULL_END

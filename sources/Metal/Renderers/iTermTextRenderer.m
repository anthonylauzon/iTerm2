#import "iTermTextRenderer.h"
#import "iTermMetalCellRenderer.h"
#import "iTermTextureArray.h"
#import "iTermTextureMap.h"

@interface iTermTextRendererContext ()

@property (nonatomic, readonly) NSIndexSet *indexes;
@property (nonatomic, readonly) dispatch_queue_t queue;

- (void)addIndex:(NSInteger)index;

@end

@implementation iTermTextRendererContext {
    NSMutableIndexSet *_indexes;
    dispatch_group_t _group;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        _queue = queue;
        _indexes = [NSMutableIndexSet indexSet];
        _group = dispatch_group_create();
    }
    return self;
}

- (void)addIndex:(NSInteger)index {
    [_indexes addIndex:index];
}

@end

@implementation iTermTextRenderer {
    iTermMetalCellRenderer *_cellRenderer;
    iTermTextureMap *_textureMap;
    iTermTextPIU *_piuContents;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _cellRenderer = [[iTermMetalCellRenderer alloc] initWithDevice:device
                                                    vertexFunctionName:@"iTermTextVertexShader"
                                                  fragmentFunctionName:@"iTermTextFragmentShader"
                                                              blending:YES
                                                        piuElementSize:sizeof(iTermTextPIU)];
    }
    return self;
}

- (void)setCellSize:(CGSize)cellSize {
    assert(cellSize.width > 0);
    assert(cellSize.height > 0);
    NSLog(@"Cell size is %@", NSStringFromSize(cellSize));
    [_cellRenderer setCellSize:cellSize];
    _cellRenderer.vertexBuffer = [_cellRenderer newQuadOfSize:_cellRenderer.cellSize];
}

- (id<MTLBuffer>)newQuadOfSize:(CGSize)size {
    const float w = _cellRenderer.cellSize.width / _textureMap.array.atlasSize.width;
    const float h = _cellRenderer.cellSize.height / _textureMap.array.atlasSize.height;

    const iTermVertex vertices[] = {
        // Pixel Positions, Texture Coordinates
        { { size.width,           0 }, { w, 0 } },
        { { 0,                    0 }, { 0, 0 } },
        { { 0,          size.height }, { 0, h } },

        { { size.width,           0 }, { w, 0 } },
        { { 0,          size.height }, { 0, h } },
        { { size.width, size.height }, { w, h } },
    };
    return [_cellRenderer.device newBufferWithBytes:vertices
                                             length:sizeof(vertices)
                                            options:MTLResourceStorageModeShared];
}

// This is called last (cell size and viewport may change before it) so it does most of the work.
- (void)setGridSize:(VT100GridSize)gridSize {
    [_cellRenderer setGridSize:gridSize];

    _textureMap = [[iTermTextureMap alloc] initWithDevice:_cellRenderer.device
                                                 cellSize:_cellRenderer.cellSize
                                                 capacity:_cellRenderer.gridSize.width * _cellRenderer.gridSize.height * 2];
    _textureMap.label = [NSString stringWithFormat:@"[texture map for %p]", self];
    _textureMap.array.texture.label = @"Texture grid for session";
    _textureMap.stage.texture.label = @"Stage for session";

    // The vertex buffer's texture coordinates depend on the texture map's atlas size so it must
    // be initialized after the texture map.
    _cellRenderer.vertexBuffer = [self newQuadOfSize:_cellRenderer.cellSize];

    [self allocateNewPIUs];
}

- (void)allocateNewPIUs {
    NSMutableData *data = [self newPerInstanceUniformData];
    _cellRenderer.pius = [_cellRenderer.device newBufferWithLength:data.length
                                                           options:MTLResourceStorageModeManaged];
    _piuContents = _cellRenderer.pius.contents;
    memcpy(_cellRenderer.pius.contents, data.bytes, data.length);
}

- (void)setViewportSize:(vector_uint2)viewportSize {
    [_cellRenderer setViewportSize:viewportSize];
}

- (void)prepareForDrawWithContext:(iTermTextRendererContext *)context
                       completion:(void (^)(void))completion {
    assert(!_preparing);
    _preparing = YES;
    [_textureMap blitNewTexturesFromStagingAreaWithCompletion:^{
        completion();
        _preparing = NO;
    }];
}

// Assumes the local texture is up to date.
- (void)drawWithRenderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder {
    [_cellRenderer.pius didModifyRange:NSMakeRange(0, _cellRenderer.pius.length)];
    _cellRenderer.vertexBuffer.label = @"text vertex buffer";
    _cellRenderer.pius.label = @"text PIUs";
    _cellRenderer.offsetBuffer.label = @"text offset";
    [_cellRenderer drawPipeline:_cellRenderer.pipelineState
                  renderEncoder:renderEncoder
               numberOfVertices:6
                   numberOfPIUs:_cellRenderer.gridSize.width * _cellRenderer.gridSize.height
                  vertexBuffers:@{ @(iTermVertexInputIndexVertices): _cellRenderer.vertexBuffer,
                                   @(iTermVertexInputIndexPerInstanceUniforms): _cellRenderer.pius,
                                   @(iTermVertexInputIndexOffset): _cellRenderer.offsetBuffer }
                       textures:@{ @(iTermTextureIndexPrimary): _textureMap.array.texture }];
    [self allocateNewPIUs];
}

- (void)setGlyphKeysData:(NSData *)glyphKeysData
          attributesData:(NSData *)attributesData
                     row:(int)row
                 context:(iTermTextRendererContext *)context
                creation:(NSImage *(NS_NOESCAPE ^)(int x))creation {
    const int width = _cellRenderer.gridSize.width;
    const iTermMetalGlyphKey *glyphKeys = (iTermMetalGlyphKey *)glyphKeysData.bytes;
    const iTermMetalGlyphAttributes *attributes = (iTermMetalGlyphAttributes *)attributesData.bytes;
    const float w = 1.0 / _textureMap.array.atlasSize.width;
    const float h = 1.0 / _textureMap.array.atlasSize.height;
    iTermTextureArray *array = _textureMap.array;

    for (int x = 0; x < width; x++) {
        NSInteger index =
            [_textureMap findOrAllocateIndexOfLockedTextureWithKey:&glyphKeys[x]
                                                            column:x
                                                          creation:creation];
        if (index >= 0) {
            // Update the PIU with the session index. It may not be a legit value yet.
            const size_t i = x + row * _cellRenderer.gridSize.width;
            iTermTextPIU *piu = &_piuContents[i];
            MTLOrigin origin = [array offsetForIndex:index];
            piu->textureOffset = (vector_float2){ origin.x * w, origin.y * h };
            piu->color = (vector_float4){
                attributes[x].foregroundColor[0],
                attributes[x].foregroundColor[1],
                attributes[x].foregroundColor[2],
                attributes[x].foregroundColor[3],
            };
            [context addIndex:index];
        }
    }
}

- (void)releaseContext:(iTermTextRendererContext *)context {
    [context.indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL * _Nonnull stop) {
        [_textureMap unlockTextureWithIndex:idx];
    }];
}

#pragma mark - Private

// Useful for debugging
- (iTermTextPIU *)piuArray {
    return (iTermTextPIU *)_cellRenderer.pius.contents;
}

- (iTermVertex *)vertexArray {
    return (iTermVertex *)_cellRenderer.vertexBuffer.contents;
}

- (nonnull NSMutableData *)newPerInstanceUniformData  {
    NSMutableData *data = [[NSMutableData alloc] initWithLength:sizeof(iTermTextPIU) * _cellRenderer.gridSize.width * _cellRenderer.gridSize.height];
    [self initializePIUData:data];
    return data;
}

- (void)initializePIUData:(NSMutableData *)data {
    void *bytes = data.mutableBytes;
    NSInteger i = 0;
    for (NSInteger y = 0; y < _cellRenderer.gridSize.height; y++) {
        for (NSInteger x = 0; x < _cellRenderer.gridSize.width; x++) {
            const iTermTextPIU uniform = {
                .offset = {
                    x * _cellRenderer.cellSize.width,
                    (_cellRenderer.gridSize.height - y - 1) * _cellRenderer.cellSize.height
                },
                .textureOffset = { 0, 0 }
            };
            memcpy(bytes + i * sizeof(uniform), &uniform, sizeof(uniform));
            i++;
        }
    }
}

@end

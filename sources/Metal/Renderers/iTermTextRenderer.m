#import "iTermTextRenderer.h"

#import "iTermMetalCellRenderer.h"
#import "iTermSubpixelModelBuilder.h"
#import "iTermTextureArray.h"
#import "iTermTextureMap.h"

@interface iTermTextRendererContext ()

@property (nonatomic, readonly) NSIndexSet *indexes;
@property (nonatomic, readonly) dispatch_queue_t queue;
@property (nonatomic, strong) NSData *subpixelModelData;
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

    NSMutableArray<iTermSubpixelModel *> *_models;
    NSMutableDictionary<NSNumber *, NSNumber *> *_modelTable;  // Maps a 48 bit fg/bg color to an index into _models.
    NSMutableData *_modelData;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _models = [NSMutableArray array];
        _modelTable = [NSMutableDictionary dictionary];
        _modelData = [NSMutableData data];
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
    // TODO: This is slow and not necessary to do every time.
    context.subpixelModelData = [self newSubpixelModelData];
    [_textureMap blitNewTexturesFromStagingAreaWithCompletion:^{
        completion();
        _preparing = NO;
    }];
}

// Assumes the local texture is up to date.
- (void)drawWithRenderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
                      context:(nonnull iTermTextRendererContext *)context {
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
                       textures:@{ @(iTermTextureIndexPrimary): _textureMap.array.texture,
                                   @(iTermTextureIndexColorModels): [self subpixelTextureFromContext:context] }];
    [self allocateNewPIUs];
}

- (id<MTLTexture>)subpixelTextureFromContext:(nonnull iTermTextRendererContext *)context {
    MTLTextureDescriptor *textureDescriptor = [[MTLTextureDescriptor alloc] init];

    textureDescriptor.textureType = MTLTextureType1D;
    textureDescriptor.pixelFormat = MTLPixelFormatRGBA16Uint;  // Ordinary format with four 16-bit unsigned integer components in RGBA order
    const NSUInteger width = context.subpixelModelData.length / (4 * sizeof(unsigned short));
    textureDescriptor.width = width;
    id<MTLTexture> texture = [_cellRenderer.device newTextureWithDescriptor:textureDescriptor];
    MTLRegion region = MTLRegionMake1D(0, width);
    [texture replaceRegion:region
               mipmapLevel:0
                 withBytes:context.subpixelModelData.bytes
               bytesPerRow:context.subpixelModelData.length];
    return texture;
}

- (void)startNewFrame {
    [_textureMap startNewFrame];
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
            piu->colorModelIndex = [self colorModelIndexForAttributes:&attributes[x]];
            [context addIndex:index];
        }
    }
}

- (NSData *)newSubpixelModelData {
    const size_t tableSize = 256 * 4 * sizeof(unsigned short);
    NSMutableData *data = [NSMutableData dataWithLength:_models.count * tableSize];
    unsigned char *output = (unsigned char *)data.mutableBytes;
    [_models enumerateObjectsUsingBlock:^(iTermSubpixelModel * _Nonnull model, NSUInteger idx, BOOL * _Nonnull stop) {
        const size_t offset = idx * tableSize;
        memcpy(output + offset, model.table.bytes, tableSize);
    }];
    return data;
}

- (int)colorModelIndexForAttributes:(const iTermMetalGlyphAttributes *)attributes {
    NSUInteger key = ((((NSUInteger)attributes->foreground[0]) << 40) |
                      (((NSUInteger)attributes->foreground[1]) << 32) |
                      (((NSUInteger)attributes->foreground[2]) << 24) |
                      (((NSUInteger)attributes->background[0]) << 16) |
                      (((NSUInteger)attributes->background[1]) << 8) |
                      (((NSUInteger)attributes->background[2]) << 0));
    NSNumber *index = _modelTable[@(key)];
    if (!index) {
        vector_float4 fg = (vector_float4){
            attributes->foreground[0] / 255.0,
            attributes->foreground[1] / 255.0,
            attributes->foreground[2] / 255.0,
            1
        };
        vector_float4 bg = (vector_float4){
            attributes->background[0] / 255.0,
            attributes->background[1] / 255.0,
            attributes->background[2] / 255.0,
            1
        };
        // TODO: Expire old models
        const NSInteger index = _models.count;
        [_models addObject:[[iTermSubpixelModelBuilder sharedInstance] modelForForegoundColor:fg
                                                                              backgroundColor:bg]];
        _modelTable[@(key)] = @(index);
        return index;
    } else {
        return index.intValue;
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

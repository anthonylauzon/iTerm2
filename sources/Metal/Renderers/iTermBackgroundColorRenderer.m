#import "iTermBackgroundColorRenderer.h"

@implementation iTermBackgroundColorRenderer {
    iTermMetalCellRenderer *_cellRenderer;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _cellRenderer = [[iTermMetalCellRenderer alloc] initWithDevice:device
                                                    vertexFunctionName:@"iTermBackgroundColorVertexShader"
                                                  fragmentFunctionName:@"iTermBackgroundColorFragmentShader"
                                                              blending:YES
                                                        piuElementSize:sizeof(iTermBackgroundColorPIU)];
    }
    return self;
}

- (void)setCellSize:(CGSize)cellSize {
    [_cellRenderer setCellSize:cellSize];
    _cellRenderer.vertexBuffer = [_cellRenderer newQuadOfSize:_cellRenderer.cellSize];
}

- (void)setGridSize:(VT100GridSize)gridSize {
    [_cellRenderer setGridSize:gridSize];
    NSMutableData *data = [self newPerInstanceUniformData];
    _cellRenderer.pius = [_cellRenderer.device newBufferWithLength:data.length
                                                           options:MTLResourceStorageModeManaged];
    memcpy(_cellRenderer.pius.contents, data.bytes, data.length);
}

- (void)setViewportSize:(vector_uint2)viewportSize {
    [_cellRenderer setViewportSize:viewportSize];
}

- (void)drawWithRenderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder {
    [_cellRenderer.pius didModifyRange:NSMakeRange(0, _cellRenderer.pius.length)];
    [_cellRenderer drawPipeline:_cellRenderer.pipelineState
                  renderEncoder:renderEncoder
               numberOfVertices:6
                   numberOfPIUs:_cellRenderer.gridSize.width * _cellRenderer.gridSize.height
                  vertexBuffers:@{ @(iTermVertexInputIndexVertices): _cellRenderer.vertexBuffer,
                                   @(iTermVertexInputIndexPerInstanceUniforms): _cellRenderer.pius,
                                   @(iTermVertexInputIndexOffset): _cellRenderer.offsetBuffer }
                       textures:@{} ];
}

- (void)setColorData:(NSData *)colorData
                 row:(int)row
               width:(int)width {
    iTermBackgroundColorPIU *pius = (iTermBackgroundColorPIU *)[_cellRenderer piuForCoord:VT100GridCoordMake(0, row)];
    const vector_float4 *colors = (const vector_float4 *)colorData.bytes;
    for (int x = 0; x < width; x++) {
        pius[x].color = colors[x];
    }
}

#pragma mark - Private

- (nonnull NSMutableData *)newPerInstanceUniformData  {
    NSMutableData *data = [[NSMutableData alloc] initWithLength:sizeof(iTermBackgroundColorPIU) * _cellRenderer.gridSize.width * _cellRenderer.gridSize.height];
    [self initializePIUData:data];
    return data;
}

- (void)initializePIUData:(NSMutableData *)data {
    void *bytes = data.mutableBytes;
    NSInteger i = 0;
    for (NSInteger y = 0; y < _cellRenderer.gridSize.height; y++) {
        for (NSInteger x = 0; x < _cellRenderer.gridSize.width; x++) {
            const iTermBackgroundColorPIU uniform = {
                .offset = {
                    x * _cellRenderer.cellSize.width,
                    (_cellRenderer.gridSize.height - y - 1) * _cellRenderer.cellSize.height
                },
                .color = (vector_float4){ 1, 0, 0, 1 }
            };
            memcpy(bytes + i * sizeof(uniform), &uniform, sizeof(uniform));
            i++;
        }
    }
}

@end

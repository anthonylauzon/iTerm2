#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

#import "iTermShaderTypes.h"

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
    int colorModelIndex;
} iTermTextVertexFunctionOutput;

vertex iTermTextVertexFunctionOutput
iTermTextVertexShader(uint vertexID [[ vertex_id ]],
                      constant float2 *offset [[ buffer(iTermVertexInputIndexOffset) ]],
                      constant iTermVertex *vertexArray [[ buffer(iTermVertexInputIndexVertices) ]],
                      constant vector_uint2 *viewportSizePointer  [[ buffer(iTermVertexInputIndexViewportSize) ]],
                      constant iTermTextPIU *perInstanceUniforms [[ buffer(iTermVertexInputIndexPerInstanceUniforms) ]],
                      unsigned int iid [[instance_id]]) {
    iTermTextVertexFunctionOutput out;

    float2 pixelSpacePosition = vertexArray[vertexID].position.xy + perInstanceUniforms[iid].offset.xy + offset[0];
    float2 viewportSize = float2(*viewportSizePointer);

    out.clipSpacePosition.xy = pixelSpacePosition / viewportSize;
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1;

    out.textureCoordinate = vertexArray[vertexID].textureCoordinate + perInstanceUniforms[iid].textureOffset;
    out.colorModelIndex = perInstanceUniforms[iid].colorModelIndex;

    return out;
}

fragment float4
iTermTextFragmentShader(iTermTextVertexFunctionOutput in [[stage_in]],
                        texture2d<half> texture [[ texture(iTermTextureIndexPrimary) ]],
                        texture1d<ushort> colorModels [[ texture(iTermTextureIndexColorModels) ]]) {
    constexpr sampler textureSampler(mag_filter::linear,
                                     min_filter::linear);

    const half4 bwColor = texture.sample(textureSampler, in.textureCoordinate);
    const short4 bwIntColor = static_cast<short4>(bwColor * 255);

    // Base index for this color model
    const int i = in.colorModelIndex * 256;
    const half alpha = 255 * (1 - (bwColor.x + bwColor.y + bwColor.z) / 3);
    // Find RGB values to map colors in the black-on-white glyph to
    constexpr sampler modelSampler(coord::pixel);
    const ushort4 rgba = ushort4(colorModels.sample(modelSampler, i + bwIntColor.x).x,
                                 colorModels.sample(modelSampler, i + bwIntColor.y).y,
                                 colorModels.sample(modelSampler, i + bwIntColor.z).z,
                                 alpha);
    return static_cast<float4>(rgba) / 255;
}


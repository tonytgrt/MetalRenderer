#include <metal_stdlib>
using namespace metal;

#include "AAPLShaderTypes.h"

struct BgRasterizerData
{
    float4 position [[position]];
    float2 texCoord;
};

vertex BgRasterizerData
backgroundVertex(uint vertexID [[ vertex_id ]], constant AAPLTexturedVertex* vertices [[ buffer(AAPLBgVertexInputIndexVertices) ]])
{
    BgRasterizerData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.texCoord = vertices[vertexID].texCoord;
    return out;
}

fragment float4
backgroundFragment(BgRasterizerData in [[ stage_in ]], texture2d<float> bgTexture [[ texture(AAPLBgTextureIndexBackground)]], sampler bgSampler [[ sampler(0) ]])
{
    return bgTexture.sample(bgSampler, in.texCoord);
}

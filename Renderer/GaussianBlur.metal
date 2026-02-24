// Renderer/GaussianBlur.metal
#include <metal_stdlib>
using namespace metal;

#include "AAPLShaderTypes.h"

// ── Rasterizer data (reuse background quad layout) ────────────────────────────
struct BlurRasterizerData
{
    float4 position [[ position ]];
    float2 texCoord;
};

// ── Vertex shader — full-screen quad, identical to backgroundVertex ────────────
vertex BlurRasterizerData
blurVertex(uint                         vertexID [[ vertex_id ]],
           constant AAPLTexturedVertex* vertices [[ buffer(AAPLBgVertexInputIndexVertices) ]])
{
    BlurRasterizerData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.texCoord = vertices[vertexID].texCoord;
    return out;
}

// ── Fragment shader ────────────────────────────────────────────────────────────
// 'step'  – (1/W, 0) for the H-pass, (0, 1/H) for the V-pass
// 'sigma' – Gaussian standard deviation in pixels
// 'radius'– number of taps on each side = ceil(2.5 * sigma), clamped to ≤ 64
fragment float4
gaussianBlurFragment(BlurRasterizerData  in        [[ stage_in ]],
                     texture2d<float>    src       [[ texture(0) ]],
                     sampler             smp       [[ sampler(0) ]],
                     constant float2&    step      [[ buffer(0) ]],   // (1/W,0) or (0,1/H)
                     constant float&     sigma     [[ buffer(1) ]])
{
    // Compute radius on the fly so the kernel matches sigma exactly.
    int radius = int(ceil(2.5 * sigma));
    radius     = clamp(radius, 1, 64);   // guard against giant kernels

    float4 colour    = float4(0.0);
    float  totalW    = 0.0;
    float  twoSigSq  = 2.0 * sigma * sigma;

    for (int i = -radius; i <= radius; ++i)
    {
        float  w   = exp(-float(i * i) / twoSigSq);
        float2 uv  = in.texCoord + step * float(i);
        colour    += src.sample(smp, uv) * w;
        totalW    += w;
    }

    return colour / totalW;
}
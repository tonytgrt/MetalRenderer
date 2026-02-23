//
//  AAPLShaderTypes.metal
//  MetalKitAndRenderingSetup
//
//  Created by Tony Tian on 2/23/26.
//  Copyright © 2026 Apple. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

#include "AAPLShaderTypes.h"

struct RasterizerData {
    float4 position [[position]]; // clip-space output
    float4 color;
};

vertex RasterizerData
vertexShader(uint                 vertexID  [[ vertex_id ]],
             constant AAPLVertex* vertices  [[ buffer(AAPLVertexInputIndexVertices) ]])
{
    RasterizerData out;

    // Index into the vertex buffer — Metal vertex shaders fetch manually,
    // unlike OpenGL which wires attributes automatically via VAO.
    // This is the same pattern as Vulkan SSBO indexing in a vertex shader.
    float2 pixelPos = vertices[vertexID].position;

    // Positions are already in NDC, so just forward them.
    // The w = 1.0 makes this a proper homogeneous coordinate.
    out.position = float4(pixelPos, 0.0, 1.0);
    out.color    = vertices[vertexID].color;

    return out;
}

fragment float4
fragmentShader(RasterizerData in [[ stage_in ]])
{
    // Return the interpolated colour directly as the pixel colour.
    return in.color;
}

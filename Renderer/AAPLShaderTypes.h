//
//  AAPLShaderTypes.h
//  MetalKitAndRenderingSetup
//
//  Created by Tony Tian on 2/23/26.
//  Copyright © 2026 Apple. All rights reserved.
//

#pragma once

#include <simd/simd.h>

typedef enum AAPLVertexInputIndex
{
    AAPLVertexInputIndexVertices = 0,
} AAPLVertexInputIndex;

typedef struct {
    simd_float2 position;
    simd_float4 color;
} AAPLVertex;


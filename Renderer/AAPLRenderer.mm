// Renderer/AAPLRenderer.mm
#import <simd/simd.h>
#import <MetalKit/MetalKit.h>

#import "AAPLRenderer.h"
#import "AAPLShaderTypes.h"   // shared C++ struct

@implementation AAPLRenderer
{
    id<MTLDevice>              _device;
    id<MTLCommandQueue>        _commandQueue;
    id<MTLRenderPipelineState> _pipelineState;   // compiled shader pair + fixed state
    id<MTLBuffer>              _vertexBuffer;    // GPU-visible triangle data
}


- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
{
    self = [super init];
    if (!self) { return self; }

    _device       = mtkView.device;
    _commandQueue = [_device newCommandQueue];

    // ── 1. Vertex data (pure C++) ─────────────────────────────────────────────
    //
    // Positions in NDC.  Metal NDC:  X -1 (left)  … +1 (right)
    //                                Y -1 (bottom) … +1 (top)     (same as OpenGL)
    //                                Z  0 (near)   …  1 (far)     (different: GL uses -1…1)
    //
    // C++ aggregate initialisation of a plain struct array — no ObjC here.
    static const AAPLVertex triangleVertices[] =
    {
    //   position (NDC)       color (RGBA)
        { { 0.0f,  0.5f },  { 1.0f, 0.0f, 0.0f, 1.0f } },   // top    — red
        { {-0.5f, -0.5f },  { 0.0f, 1.0f, 0.0f, 1.0f } },   // left   — green
        { { 0.5f, -0.5f },  { 0.0f, 0.0f, 1.0f, 1.0f } },   // right  — blue
    };

    // Upload vertices to a MTLBuffer.
    // MTLStorageModeShared = CPU-writable and GPU-readable (like a GL_DYNAMIC_DRAW VBO
    // or a Vulkan HOST_VISIBLE | HOST_COHERENT buffer).
    // For static geometry, MTLStorageModeManaged (macOS) or a blit to a private buffer
    // is more efficient, but Shared is fine for learning.
    _vertexBuffer = [_device newBufferWithBytes:triangleVertices
                                         length:sizeof(triangleVertices)
                                        options:MTLResourceStorageModeShared];

    // ── 2. Load shaders from the default Metal library ────────────────────────
    //
    // Xcode compiles all .metal files in the target into a single
    // default.metallib at build time (analogous to linking SPIR-V modules).
    // newDefaultLibrary loads that binary.
    NSError *error = nil;
    id<MTLLibrary> defaultLibrary = [_device newDefaultLibrary];

    id<MTLFunction> vertexFunction   = [defaultLibrary newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragmentFunction = [defaultLibrary newFunctionWithName:@"fragmentShader"];

    // ── 3. Build the render pipeline state ───────────────────────────────────
    //
    // MTLRenderPipelineDescriptor is the Metal equivalent of VkGraphicsPipelineCreateInfo
    // or the combination of glLinkProgram + glEnable/glBlend/etc. in OpenGL.
    // It is compiled once and cached; switching pipelines at draw time is cheap.
    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.label                = @"Triangle Pipeline";
    pipelineDescriptor.vertexFunction       = vertexFunction;
    pipelineDescriptor.fragmentFunction     = fragmentFunction;

    // The PSO must know the pixel format of the render target it will write to.
    // MTKView exposes this as colorPixelFormat — it matches the drawable texture format.
    // If this does not match the actual attachment format at draw time, Metal will
    // raise a validation error (similar to a Vulkan render pass compatibility error).
    pipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat;

    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineDescriptor
                                                             error:&error];
    if (!_pipelineState)
    {
        NSLog(@"Failed to create pipeline state: %@", error);
    }

    return self;
}


// ── Per-frame rendering ───────────────────────────────────────────────────────

- (void)drawInMTKView:(nonnull MTKView *)view
{
    MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;
    if (renderPassDescriptor == nil) { return; }

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];

    // A MTLRenderCommandEncoder is a single render pass.
    // In Vulkan terms: begin render pass + record draw commands + end render pass.
    // In OpenGL terms: the implicit "draw into the current FBO" state.
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

    // Bind the compiled pipeline state (shaders + blend mode + pixel format).
    [encoder setRenderPipelineState:_pipelineState];

    // Bind the vertex buffer to slot 0 — matches [[buffer(AAPLVertexInputIndexVertices)]]
    // in the vertex shader.  Offset 0 = start from the beginning of the buffer.
    // In OpenGL terms: glBindBuffer + glVertexAttribPointer.
    // In Vulkan terms: vkCmdBindVertexBuffers.
    [encoder setVertexBuffer:_vertexBuffer
                      offset:0
                     atIndex:AAPLVertexInputIndexVertices];

    // Issue the draw call.
    // MTLPrimitiveTypeTriangle = one triangle per 3 vertices (GL_TRIANGLES).
    // vertexStart:0 vertexCount:3 = draw vertices 0, 1, 2.
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];

    [encoder endEncoding];

    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
}


- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
    // No projection matrix yet — vertices are already in NDC.
}

@end

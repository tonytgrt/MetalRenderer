// Renderer/AAPLRenderer.mm
#import <simd/simd.h>
#import <MetalKit/MetalKit.h>

#import "AAPLRenderer.h"
#import "AAPLShaderTypes.h"

@implementation AAPLRenderer
{
    id<MTLDevice>              _device;
    id<MTLCommandQueue>        _commandQueue;

    // ── Coloured triangle ─────────────────────────────────────────────────────
    id<MTLRenderPipelineState> _pipelineState;
    id<MTLBuffer>              _vertexBuffer;

    // ── Background quad ───────────────────────────────────────────────────────
    id<MTLRenderPipelineState> _backgroundPipelineState;
    id<MTLBuffer>              _quadVertexBuffer;
    id<MTLTexture>             _backgroundTexture;   // nil until user picks a file
    id<MTLSamplerState>        _samplerState;
}


- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
{
    self = [super init];
    if (!self) { return self; }

    _device       = mtkView.device;
    _commandQueue = [_device newCommandQueue];

    [self _buildTrianglePipelineWithView:mtkView];
    [self _buildBackgroundPipelineWithView:mtkView];
    [self _buildSamplerState];

    return self;
}


// ── Triangle pipeline (same as the triangle guide) ────────────────────────────

- (void)_buildTrianglePipelineWithView:(MTKView *)mtkView
{
    static const AAPLVertex triangleVertices[] =
    {
        { { 0.0f,  0.5f },  { 1.0f, 0.0f, 0.0f, 1.0f } },
        { {-0.5f, -0.5f },  { 0.0f, 1.0f, 0.0f, 1.0f } },
        { { 0.5f, -0.5f },  { 0.0f, 0.0f, 1.0f, 1.0f } },
    };

    _vertexBuffer = [_device newBufferWithBytes:triangleVertices
                                         length:sizeof(triangleVertices)
                                        options:MTLResourceStorageModeShared];

    id<MTLLibrary>  lib  = [_device newDefaultLibrary];
    NSError        *err  = nil;

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label                              = @"Triangle Pipeline";
    desc.vertexFunction                     = [lib newFunctionWithName:@"vertexShader"];
    desc.fragmentFunction                   = [lib newFunctionWithName:@"fragmentShader"];
    desc.colorAttachments[0].pixelFormat    = mtkView.colorPixelFormat;

    _pipelineState = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!_pipelineState) { NSLog(@"Triangle PSO error: %@", err); }
}


// ── Background pipeline ───────────────────────────────────────────────────────

- (void)_buildBackgroundPipelineWithView:(MTKView *)mtkView
{
    // Full-screen quad as a triangle strip (4 vertices, 2 triangles).
    //
    // Triangle strip winding:  v0─v1
    //                           │╲  │
    //                          v2─v3
    //
    // Strip order: v0, v1, v2 → triangle 1
    //              v1, v2, v3 → triangle 2  (Metal re-uses last 2 vertices)
    //
    // NDC position     UV
    static const AAPLTexturedVertex quadVertices[] =
    {
        { {-1.0f,  1.0f},  {0.0f, 0.0f} },   // v0  top-left
        { { 1.0f,  1.0f},  {1.0f, 0.0f} },   // v1  top-right
        { {-1.0f, -1.0f},  {0.0f, 1.0f} },   // v2  bottom-left
        { { 1.0f, -1.0f},  {1.0f, 1.0f} },   // v3  bottom-right
    };

    _quadVertexBuffer = [_device newBufferWithBytes:quadVertices
                                             length:sizeof(quadVertices)
                                            options:MTLResourceStorageModeShared];

    id<MTLLibrary>  lib = [_device newDefaultLibrary];
    NSError        *err = nil;

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label              = @"Background Pipeline";
    desc.vertexFunction     = [lib newFunctionWithName:@"backgroundVertex"];
    desc.fragmentFunction   = [lib newFunctionWithName:@"backgroundFragment"];
    desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat;

    _backgroundPipelineState = [_device newRenderPipelineStateWithDescriptor:desc
                                                                       error:&err];
    if (!_backgroundPipelineState) { NSLog(@"Background PSO error: %@", err); }
}


// ── Sampler state ─────────────────────────────────────────────────────────────
//
// MTLSamplerState is the Metal equivalent of:
//   OpenGL:  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR) etc.
//   Vulkan:  VkSamplerCreateInfo → vkCreateSampler
//
// Created once, reused every frame.

- (void)_buildSamplerState
{
    MTLSamplerDescriptor *desc = [[MTLSamplerDescriptor alloc] init];

    // Linear filtering: smooth interpolation between texels.
    // Use MTLSamplerMinMagFilterNearest for a pixelated / retro look.
    desc.minFilter = MTLSamplerMinMagFilterLinear;
    desc.magFilter = MTLSamplerMinMagFilterLinear;

    // ClampToEdge: pixels outside [0,1] UV get the edge colour.
    // Equivalent to GL_CLAMP_TO_EDGE / VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE.
    desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
    desc.tAddressMode = MTLSamplerAddressModeClampToEdge;

    _samplerState = [_device newSamplerStateWithDescriptor:desc];
}


// ── Public: load image from file ──────────────────────────────────────────────

- (void)loadBackgroundFromURL:(nonnull NSURL *)url
{
    // MTKTextureLoader is the high-level path for loading images into MTLTexture.
    // It handles PNG, JPEG, HEIC, TIFF, and any format NSImage/CGImage can decode.
    // The low-level path (manual CGImage decode + MTLTexture blit) is only needed
    // when you need fine-grained control over formats or mip generation.
    MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:_device];

    NSDictionary *options = @{
        // Generate no mipmaps — background is drawn at full screen size so
        // minification mipmaps are wasted memory here.
        MTKTextureLoaderOptionGenerateMipmaps : @(NO),

        // SRGB = NO: load raw pixel values, no gamma correction applied by the
        // loader.  Set to YES if you want the loader to tag the texture as sRGB
        // so the GPU converts to linear on reads (correct for colour-managed apps).
        MTKTextureLoaderOptionSRGB : @(NO),

        // TextureUsage: ShaderRead is sufficient — we only sample, never write.
        MTKTextureLoaderOptionTextureUsage :
            @(MTLTextureUsageShaderRead),

        // StorageMode: Private places the texture in GPU-only memory (fastest
        // read).  The loader handles the CPU→GPU upload internally via a blit.
        // Equivalent to a Vulkan DEVICE_LOCAL image after a staging upload.
        MTKTextureLoaderOptionTextureStorageMode :
            @(MTLStorageModePrivate),
    };

    NSError *error = nil;
    id<MTLTexture> tex = [loader newTextureWithContentsOfURL:url
                                                     options:options
                                                       error:&error];
    if (tex)
    {
        _backgroundTexture = tex;
    }
    else
    {
        NSLog(@"Failed to load background texture: %@", error);
    }
}


// ── Per-frame rendering ───────────────────────────────────────────────────────

- (void)drawInMTKView:(nonnull MTKView *)view
{
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (rpd == nil) { return; }

    id<MTLCommandBuffer>        cmd     = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [cmd renderCommandEncoderWithDescriptor:rpd];

    // ── Draw background (only when a texture has been loaded) ─────────────────
    //
    // Draw order matters: background first, then triangle on top.
    // There is no depth test here — we rely on painter's algorithm (draw order).
    if (_backgroundTexture != nil)
    {
        [encoder setRenderPipelineState:_backgroundPipelineState];

        // Vertex buffer — full-screen quad
        [encoder setVertexBuffer:_quadVertexBuffer
                          offset:0
                         atIndex:AAPLBgVertexInputIndexVertices];

        // Texture — bound to slot 0, matches [[texture(AAPLBgTextureIndexBackground)]]
        [encoder setFragmentTexture:_backgroundTexture
                            atIndex:AAPLBgTextureIndexBackground];

        // Sampler — bound to slot 0, matches [[sampler(0)]]
        [encoder setFragmentSamplerState:_samplerState
                                 atIndex:0];

        // Triangle strip: 4 vertices → 2 triangles → full-screen quad
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0
                    vertexCount:4];
    }

    // ── Draw coloured triangle (on top of background) ─────────────────────────
    [encoder setRenderPipelineState:_pipelineState];
    [encoder setVertexBuffer:_vertexBuffer
                      offset:0
                     atIndex:AAPLVertexInputIndexVertices];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];

    [encoder endEncoding];

    [cmd presentDrawable:view.currentDrawable];
    [cmd commit];
}


- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {}

@end

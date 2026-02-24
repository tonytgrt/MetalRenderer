// Renderer/AAPLRenderer.mm
#import <simd/simd.h>
#import <MetalKit/MetalKit.h>

#import "AAPLRenderer.h"
#import "AAPLShaderTypes.h"

@implementation AAPLRenderer
{
    id<MTLDevice>              _device;
    id<MTLCommandQueue>        _commandQueue;

    // ── Background ────────────────────────────────────────────────────────────
    id<MTLRenderPipelineState> _backgroundPipelineState;
    id<MTLBuffer>              _quadVertexBuffer;   // shared by bg and glass
    id<MTLTexture>             _backgroundTexture;  // nil until user loads an image
    id<MTLSamplerState>        _samplerState;

    // ── Liquid glass ──────────────────────────────────────────────────────────
    id<MTLRenderPipelineState> _glassPipelineState;
    id<MTLTexture>             _defaultTexture;     // 1×1 white fallback

    // ── Per-frame state ───────────────────────────────────────────────────────
    simd_float2                _viewportSize;
}


- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
{
    self = [super init];
    if (!self) { return self; }

    _device            = mtkView.device;
    _commandQueue      = [_device newCommandQueue];
    _viewportSize      = simd_make_float2(mtkView.drawableSize.width,
                                          mtkView.drawableSize.height);

    [self _buildQuadBuffer];
    [self _buildSamplerState];
    [self _buildBackgroundPipelineWithView:mtkView];
    [self _buildGlassPipelineWithView:mtkView];
    [self _buildDefaultTexture];

    return self;
}


// ── Shared geometry: full-screen quad (triangle strip) ────────────────────────

- (void)_buildQuadBuffer
{
    static const AAPLTexturedVertex quadVertices[] =
    {
        { {-1.0f,  1.0f}, {0.0f, 0.0f} },  // top-left
        { { 1.0f,  1.0f}, {1.0f, 0.0f} },  // top-right
        { {-1.0f, -1.0f}, {0.0f, 1.0f} },  // bottom-left
        { { 1.0f, -1.0f}, {1.0f, 1.0f} },  // bottom-right
    };

    _quadVertexBuffer = [_device newBufferWithBytes:quadVertices
                                             length:sizeof(quadVertices)
                                            options:MTLResourceStorageModeShared];
}


// ── Sampler ───────────────────────────────────────────────────────────────────

- (void)_buildSamplerState
{
    MTLSamplerDescriptor *desc  = [[MTLSamplerDescriptor alloc] init];
    desc.minFilter              = MTLSamplerMinMagFilterLinear;
    desc.magFilter              = MTLSamplerMinMagFilterLinear;
    desc.sAddressMode           = MTLSamplerAddressModeClampToEdge;
    desc.tAddressMode           = MTLSamplerAddressModeClampToEdge;
    _samplerState               = [_device newSamplerStateWithDescriptor:desc];
}


// ── Background pipeline ───────────────────────────────────────────────────────

- (void)_buildBackgroundPipelineWithView:(MTKView *)mtkView
{
    id<MTLLibrary> lib = [_device newDefaultLibrary];
    NSError       *err = nil;

    MTLRenderPipelineDescriptor *desc   = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label                          = @"Background Pipeline";
    desc.vertexFunction                 = [lib newFunctionWithName:@"backgroundVertex"];
    desc.fragmentFunction               = [lib newFunctionWithName:@"backgroundFragment"];
    desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat;

    _backgroundPipelineState = [_device newRenderPipelineStateWithDescriptor:desc
                                                                       error:&err];
    if (!_backgroundPipelineState) { NSLog(@"Background PSO error: %@", err); }
}


// ── Liquid glass pipeline ─────────────────────────────────────────────────────

- (void)_buildGlassPipelineWithView:(MTKView *)mtkView
{
    id<MTLLibrary> lib = [_device newDefaultLibrary];
    NSError       *err = nil;

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label            = @"Liquid Glass Pipeline";
    desc.vertexFunction   = [lib newFunctionWithName:@"glassVertex"];
    desc.fragmentFunction = [lib newFunctionWithName:@"glassFragment"];

    // Alpha blending: glass composites over the background using its alpha channel.
    MTLRenderPipelineColorAttachmentDescriptor *att = desc.colorAttachments[0];
    att.pixelFormat                 = mtkView.colorPixelFormat;
    att.blendingEnabled             = YES;
    att.sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
    att.destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
    att.sourceAlphaBlendFactor      = MTLBlendFactorOne;
    att.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    _glassPipelineState = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!_glassPipelineState) { NSLog(@"Glass PSO error: %@", err); }
}


// ── Default 1×1 white texture ─────────────────────────────────────────────────
// Used when no background image has been loaded yet.
// Ensures the glass effect is always visible (renders as frosted white glass).

- (void)_buildDefaultTexture
{
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:1
                                                          height:1
                                                       mipmapped:NO];
    _defaultTexture = [_device newTextureWithDescriptor:desc];

    uint8_t white[4] = {255, 255, 255, 255};
    uint8_t clr[4] = {0x1f, 0x1e, 0x33, 0xff};
    [_defaultTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                       mipmapLevel:0
                         withBytes:white
                       bytesPerRow:4];
}


// ── Public: load background image ────────────────────────────────────────────

- (void)loadBackgroundFromURL:(nonnull NSURL *)url
{
    MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:_device];
    NSDictionary *options = @{
        MTKTextureLoaderOptionGenerateMipmaps    : @(NO),
        MTKTextureLoaderOptionSRGB               : @(NO),
        MTKTextureLoaderOptionTextureUsage       : @(MTLTextureUsageShaderRead),
        MTKTextureLoaderOptionTextureStorageMode : @(MTLStorageModePrivate),
    };

    NSError *error = nil;
    id<MTLTexture> tex = [loader newTextureWithContentsOfURL:url
                                                     options:options
                                                       error:&error];
    if (tex)  { _backgroundTexture = tex; }
    else      { NSLog(@"Texture load failed: %@", error); }
}


// ── Per-frame rendering ───────────────────────────────────────────────────────

- (void)drawInMTKView:(nonnull MTKView *)view
{
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (rpd == nil) { return; }

    id<MTLCommandBuffer>        cmd     = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [cmd renderCommandEncoderWithDescriptor:rpd];

    // ── Pass 1: background ────────────────────────────────────────────────────
    if (_backgroundTexture != nil)
    {
        [encoder setRenderPipelineState:_backgroundPipelineState];
        [encoder setVertexBuffer:_quadVertexBuffer offset:0
                         atIndex:AAPLBgVertexInputIndexVertices];
        [encoder setFragmentTexture:_backgroundTexture
                            atIndex:AAPLBgTextureIndexBackground];
        [encoder setFragmentSamplerState:_samplerState atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0 vertexCount:4];
    }

    // ── Pass 2: liquid glass ──────────────────────────────────────────────────
    // Use the real background texture if loaded; fall back to 1×1 white.
    id<MTLTexture> glassSource = _backgroundTexture ?: _defaultTexture;

    [encoder setRenderPipelineState:_glassPipelineState];
    [encoder setVertexBuffer:_quadVertexBuffer offset:0
                     atIndex:AAPLBgVertexInputIndexVertices];
    [encoder setFragmentTexture:glassSource atIndex:AAPLBgTextureIndexBackground];
    [encoder setFragmentSamplerState:_samplerState atIndex:0];

    // Pass viewport size as an inline constant (Vulkan equivalent: push constant).
    // The glass fragment shader uses this to convert pixel coordinates to NDC
    // and to correct for the window aspect ratio.
    [encoder setFragmentBytes:&_viewportSize
                       length:sizeof(_viewportSize)
                      atIndex:0];

    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0 vertexCount:4];

    [encoder endEncoding];
    [cmd presentDrawable:view.currentDrawable];
    [cmd commit];
}


- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
    _viewportSize = simd_make_float2((float)size.width, (float)size.height);
}

@end

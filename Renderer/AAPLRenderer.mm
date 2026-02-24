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

    // Two off-screen textures for the H→V blur chain
    id<MTLTexture>              _blurIntermediate;   // H-pass output / V-pass input
    id<MTLTexture>              _blurTexture;         // final blurred result bound to glass

    id<MTLRenderPipelineState>  _blurPipelineState;

    float                       _blurSigma;           // set once; change for tuning
    bool                        _blurDirty;           // re-blur only when image changes
}

- (void)_buildBlurPipelineWithView:(MTKView *)view
{
    id<MTLLibrary> lib = [_device newDefaultLibrary];

    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.label                        = @"Gaussian Blur";
    desc.vertexFunction               = [lib newFunctionWithName:@"blurVertex"];
    desc.fragmentFunction             = [lib newFunctionWithName:@"gaussianBlurFragment"];

    // Off-screen target — match the background texture pixel format.
    // MTLPixelFormatBGRA8Unorm is a safe default; use RGBA16Float if HDR.
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    NSError *err;
    _blurPipelineState = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
    NSAssert(_blurPipelineState, @"Blur pipeline: %@", err);
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
    [self _buildBlurPipelineWithView:mtkView];
    _blurSigma = 20.0f;   // Dock-like starting point
    _blurDirty = false;
    [self _rebuildBlurTexturesWithSize:mtkView.drawableSize];

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
    _blurDirty = true;
}

- (void)_encodeBlurPassesWithCommandBuffer:(id<MTLCommandBuffer>)cmdBuf
                                   texture:(id<MTLTexture>)source
{
    float sigma    = _blurSigma;
    float stepH[2] = { 1.0f / (float)source.width,  0.0f };
    float stepV[2] = { 0.0f, 1.0f / (float)source.height };

    // Pass 1: horizontal  (source → _blurIntermediate)
    {
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor new];
        rpd.colorAttachments[0].texture     = _blurIntermediate;
        rpd.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
        enc.label = @"BlurH";
        [enc setRenderPipelineState:_blurPipelineState];
        [enc setVertexBuffer:_quadVertexBuffer offset:0 atIndex:AAPLBgVertexInputIndexVertices];
        [enc setFragmentTexture:source atIndex:0];
        [enc setFragmentSamplerState:_samplerState atIndex:0];
        [enc setFragmentBytes:stepH  length:sizeof(float) * 2 atIndex:0];
        [enc setFragmentBytes:&sigma length:sizeof(float)     atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [enc endEncoding];
    }

    // Pass 2: vertical    (_blurIntermediate → _blurTexture)
    {
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor new];
        rpd.colorAttachments[0].texture     = _blurTexture;
        rpd.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
        enc.label = @"BlurV";
        [enc setRenderPipelineState:_blurPipelineState];
        [enc setVertexBuffer:_quadVertexBuffer offset:0 atIndex:AAPLBgVertexInputIndexVertices];
        [enc setFragmentTexture:_blurIntermediate atIndex:0];
        [enc setFragmentSamplerState:_samplerState atIndex:0];
        [enc setFragmentBytes:stepV  length:sizeof(float) * 2 atIndex:0];
        [enc setFragmentBytes:&sigma length:sizeof(float)     atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [enc endEncoding];
    }
}

// ── Per-frame rendering ───────────────────────────────────────────────────────

- (void)drawInMTKView:(nonnull MTKView *)view
{
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (rpd == nil) { return; }

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];

    // ── Off-screen blur passes (only when image changes) ─────────────────────
    // Must run before the on-screen encoder so the blur textures are ready.
    if (_blurDirty && _backgroundTexture)
    {
        [self _encodeBlurPassesWithCommandBuffer:cmd texture:_backgroundTexture];
        _blurDirty = false;
    }

    // ── On-screen render pass ─────────────────────────────────────────────────
    id<MTLRenderCommandEncoder> encoder = [cmd renderCommandEncoderWithDescriptor:rpd];

    // ── Sub-pass 1: background ────────────────────────────────────────────────
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

    // ── Sub-pass 2: liquid glass ──────────────────────────────────────────────
    id<MTLTexture> bgTex        = _backgroundTexture ?: _defaultTexture;
    id<MTLTexture> glassFrostTex = _blurTexture ?: _defaultTexture;

    [encoder setRenderPipelineState:_glassPipelineState];
    [encoder setVertexBuffer:_quadVertexBuffer offset:0
                     atIndex:AAPLBgVertexInputIndexVertices];
    [encoder setFragmentTexture:bgTex         atIndex:AAPLBgTextureIndexBackground];
    [encoder setFragmentTexture:glassFrostTex atIndex:AAPLBgTextureIndexBlur];
    [encoder setFragmentSamplerState:_samplerState atIndex:0];
    [encoder setFragmentBytes:&_viewportSize
                       length:sizeof(_viewportSize)
                      atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0 vertexCount:4];

    [encoder endEncoding];
    [cmd presentDrawable:view.currentDrawable];
    [cmd commit];
}

- (void)_rebuildBlurTexturesWithSize:(CGSize)size
{
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:(NSUInteger)size.width
                                                          height:(NSUInteger)size.height
                                                       mipmapped:NO];

    // Both textures are render targets (written by a blur pass) and
    // shader resources (read by the next pass / glass fragment shader).
    desc.usage        = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode  = MTLStorageModePrivate;   // GPU-only; fastest

    _blurIntermediate = [_device newTextureWithDescriptor:desc];
    _blurTexture      = [_device newTextureWithDescriptor:desc];

    _blurIntermediate.label = @"BlurIntermediate";
    _blurTexture.label      = @"BlurOutput";

    _blurDirty = true;   // force a re-blur with the new size
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
    _viewportSize = simd_make_float2((float)size.width, (float)size.height);
    [self _rebuildBlurTexturesWithSize:size];
}

@end

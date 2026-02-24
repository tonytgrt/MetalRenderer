// Renderer/LiquidGlass.metal
#include <metal_stdlib>
using namespace metal;

#include "AAPLShaderTypes.h"

// ── SDF: rounded rectangle ────────────────────────────────────────────────────
float sdRoundedBox(float2 p, float2 b, float r)
{
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// ── Height field: convex lens profile ────────────────────────────────────────
float lensHeight(float dist, float lensRadius)
{
    float t = saturate(dist / lensRadius);
    return t * (2.0 - t);
}

// ── Rasterizer data ───────────────────────────────────────────────────────────
struct GlassRasterizerData
{
    float4 position [[position]];
    float2 texCoord;
};

// ── Vertex shader ─────────────────────────────────────────────────────────────
// Reuses the same full-screen quad as the background pass.
vertex GlassRasterizerData
glassVertex(uint                         vertexID [[ vertex_id ]],
            constant AAPLTexturedVertex* vertices [[ buffer(AAPLBgVertexInputIndexVertices) ]])
{
    GlassRasterizerData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.texCoord = vertices[vertexID].texCoord;
    return out;
}

// ── Fragment shader ───────────────────────────────────────────────────────────
fragment float4
glassFragment(GlassRasterizerData   in        [[ stage_in ]],
              texture2d<float>      bgTexture [[ texture(AAPLBgTextureIndexBackground) ]],
              texture2d<float>      blurTexture  [[ texture(AAPLBgTextureIndexBlur) ]],
              sampler               bgSampler [[ sampler(0) ]],
              constant float2&      viewport  [[ buffer(0) ]])   // (width, height) in pixels
{
    // ── 1. Coordinate setup ───────────────────────────────────────────────────
    // Metal [[position]] gives pixel coordinates with Y+ downward.
    // Convert to NDC ([-1,+1], Y+ upward) then into aspect-corrected space
    // where 1 unit = view height, so the glass shape is screen-independent.
    float aspect = viewport.x / viewport.y;
    float2 pixelPos = in.position.xy;
    float2 ndc;
    ndc.x =  (pixelPos.x / viewport.x) * 2.0 - 1.0;
    ndc.y = -((pixelPos.y / viewport.y) * 2.0 - 1.0);  // flip Y
    float2 p = float2(ndc.x / aspect, ndc.y);           // aspect-corrected

    // ── 2. Glass shape via SDF ────────────────────────────────────────────────
    // boxHalf and cornerR are in aspect-corrected units (1 = view height).
    // 0.38 half-extent means the panel spans 76% of the view height.
    // cornerR = 0.12 gives the rounded squircle-like corner of iOS icons.
    float2 boxHalf  = float2(0.38, 0.38);
    float  cornerR  = 0.12;
    float  sdf      = sdRoundedBox(p, boxHalf, cornerR);

    // ── 3. AA boundary mask ───────────────────────────────────────────────────
    float  aa   = fwidth(sdf);                          // 1-pixel AA kernel
    float  mask = 1.0 - smoothstep(-aa, aa, sdf);
    if (mask < 0.001) discard_fragment();               // fast-out outside glass

    // ── 4. Interior distance and lens height ──────────────────────────────────
    float intDist = -sdf;                               // positive inside, 0 at edge
    float lensR   = min(boxHalf.x, boxHalf.y) * 0.85;  // reference depth for t=1
    float t       = saturate(intDist / lensR);          // 0 = edge, 1 = deep inside

    // ── 5. Surface normal via finite differences ──────────────────────────────
    float eps = 0.004;
    float hL  = lensHeight(max(0.0, -(sdRoundedBox(p - float2(eps, 0.0), boxHalf, cornerR))), lensR);
    float hR  = lensHeight(max(0.0, -(sdRoundedBox(p + float2(eps, 0.0), boxHalf, cornerR))), lensR);
    float hD  = lensHeight(max(0.0, -(sdRoundedBox(p - float2(0.0, eps), boxHalf, cornerR))), lensR);
    float hU  = lensHeight(max(0.0, -(sdRoundedBox(p + float2(0.0, eps), boxHalf, cornerR))), lensR);

    // Express as rise/run slope then scale for visual steepness.
    // Dividing by (2*eps) normalises the gradient so nScale has an intuitive range
    // and N.z stays well-behaved regardless of eps.
    float  nScale = 1.2;
    float3 N      = normalize(float3((hL - hR) / (2.0 * eps) * nScale,
                                     (hD - hU) / (2.0 * eps) * nScale,
                                     1.0));
    // N.z ≈ 1 at centre (flat), small at silhouette (steep tilt)

    // ── 6. Refraction ─────────────────────────────────────────────────────────
    // refract(I, N, eta): bends the incoming ray through the glass surface.
    // Incident ray I points toward the screen (0,0,1).
    // eta = n_air / n_glass = 1.0 / 1.5 ≈ 0.667.
    float3 I          = float3(0.0, 0.0, 1.0);
    float3 refractDir = refract(I, N, 0.667);

    float  refractStr = 0.03;   // normals are now stronger so less UV offset needed
    float  edgeBlend  = 1.0 - smoothstep(0.0, 0.25, t);   // strong at edge, 0 at centre
    float2 uvDistort  = refractDir.xy * refractStr * edgeBlend;

    float4 refracted  = bgTexture.sample(bgSampler, saturate(in.texCoord + uvDistort));

    // ── 7. Frosted interior ───────────────────────────────────────────────────
    // The blur texture contains a full two-pass Gaussian of the background.
    // No UV distortion here: frost is about diffusion, not refraction.
    float4 frosted = blurTexture.sample(bgSampler, in.texCoord);
    frosted        = mix(frosted, float4(1.0), 0.08);

    // ── 8. Fresnel (Schlick) ──────────────────────────────────────────────────
    // F(θ) = F₀ + (1–F₀)(1–cosθ)⁵,  F₀ ≈ 0.04 for glass in air.
    // cosθ = N.z (dot of surface normal with straight-on view direction).
    float fresnel = 0.04 + 0.96 * pow(1.0 - saturate(N.z), 5.0);

    // ── 9. Rim highlight ──────────────────────────────────────────────────────
    float rimW  = 0.0012;
    float rim   = smoothstep(0.0, rimW * 0.3, intDist) *
                  (1.0 - smoothstep(rimW * 0.3, rimW * 1.5, intDist));

    // ── 10. Edge glow ─────────────────────────────────────────────────────────
    float edgeGlow = (1.0 - smoothstep(0.0, 0.04, intDist)) * 0.022;

    // ── 11. Caustic at centre ─────────────────────────────────────────────────
    // A convex lens focuses light toward the centre — subtle brightness boost.
    float caustic = pow(saturate(t), 5.0) * 0.08;

    // ── 12. Composite ─────────────────────────────────────────────────────────
    float  frostBlend = smoothstep(0.35, 0.70, t);     // edge stays sharp, frost only in deep centre
    float4 color      = mix(refracted, frosted, frostBlend);

    color.rgb  = mix(color.rgb, float3(1.0), fresnel * 0.55);   // Fresnel brightness
    color.rgb += float3(1.00, 1.00, 1.00) * rim      * 0.75;    // rim highlight
    color.rgb += float3(0.88, 0.94, 1.00) * edgeGlow;           // edge glow
    color.rgb += caustic;                                         // centre caustic
    color.a    = mask;                                            // AA alpha

    return color;
}

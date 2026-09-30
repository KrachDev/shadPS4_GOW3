// SPDX-FileCopyrightText: Copyright Aston89 (Baudelaire)
// SPDX-License-Identifier: GPL-3.0-only

#include "common.hlsl"
static const float TDAA_Temporal_Stability = 0.80;
static const float TDAA_Temporal_GhostProtection = 8.0;
static const float TDAA_Temporal_SearchRadius = 2.0;
static const float TDAA_Detail_Sharpness = 0.20;
static const float TDAA_Detail_NoiseProtection = 0.50;
static const float TDAA_Polish_MicroContrast = 0.00;
static const float TDAA_Polish_Saturation = 0.00;
static const bool TDAA_Debug_Enable = false;
static const int TDAA_Debug_View = 0;
#define BACKBUFFER MakeTex(tex0)
namespace ReShade { static Tex BackBuffer = MakeTex(tex0); }
namespace tdaa { static Tex PastColorSamp = MakeTex(tex1,false); static Tex PastStateSamp = MakeTex(tex2,false); static Tex TempColorSamp = MakeTex(tex0); static Tex TempStateSamp = MakeTex(tex1,false); }
float Luma(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// Color space conversions. YCoCg is used because it separates luminance from
// chrominance, preventing color bleeding during temporal clamping.
float3 RGBToYCoCg(float3 rgb) {
    return float3(dot(rgb, float3(0.25, 0.50, 0.25)), dot(rgb, float3(0.50, 0.0, -0.50)), dot(rgb, float3(-0.25, 0.50, -0.25)));
}
float3 YCoCgToRGB(float3 ycc) {
    return float3(ycc.x + ycc.y - ycc.z, ycc.x + ycc.z, ycc.x - ycc.y - ycc.z);
}

// =============================================================================
// PASS 1: TEMPORAL RESOLVE
// Reads: BackBuffer, PastColor, PastState
// Writes: TempColor, TempState
// =============================================================================
struct TemporalOut {
    float4 color : SV_Target0;
    float4 state : SV_Target1;
};

TemporalOut PS_Temporal(float4 pos : SV_Position, float2 uv : TEXCOORD) {
    float2 px = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float3 current = tex2D(ReShade::BackBuffer, uv).rgb;
    float3 currentYCoCg = RGBToYCoCg(current);

    // 1. 3x3 Variance Clipping (Neighborhood Min/Max in YCoCg)
    float3 nbMin = currentYCoCg;
    float3 nbMax = currentYCoCg;
    float3 avgNb = 0.0;

    [unroll]
    for(int i=0; i<9; i++) {
        float2 off = float2(i%3-1, i/3-1) * px;
        float3 c = RGBToYCoCg(tex2D(ReShade::BackBuffer, uv + off).rgb);
        if(i != 4) { avgNb += c; nbMin = min(nbMin, c); nbMax = max(nbMax, c); }
    }
    avgNb /= 8.0;
    float localVariance = length(currentYCoCg - avgNb);

    // 2. Fetch History (Past Frame)
    float4 bestHist = tex2D(tdaa::PastColorSamp, uv);
    float4 oldState = tex2D(tdaa::PastStateSamp, uv);
    float prevStab = oldState.g;

    float bestDiff = abs(Luma(bestHist.rgb) - Luma(current));

    // 3. Neighborhood Search
    // Note: HLSL compilers struggle with unrolling dynamic loops fully.
    // We split the search into fixed 1px, 2px, and 3px radius blocks to
    // guarantee optimal compilation and avoid performance cliffs.
    int searchRadius = (int)TDAA_Temporal_SearchRadius;

    // Radius 1 (3x3 area)
    if (searchRadius >= 1) {
        [unroll] for(int y=-1; y<=1; y++)
        [unroll] for(int x=-1; x<=1; x++) {
            if (!(x==0 && y==0)) {
                float4 h = tex2D(tdaa::PastColorSamp, uv + float2(x, y) * px);
                float d = abs(Luma(h.rgb) - Luma(current));
                if(d < bestDiff) { bestDiff = d; bestHist = h; }
            }
        }
    }
    // Radius 2 (5x5 area outer ring)
    if (searchRadius >= 2) {
        [unroll] for(int y=-2; y<=2; y++)
        [unroll] for(int x=-2; x<=2; x++) {
            if (abs(x)==2 || abs(y)==2) {
                float4 h = tex2D(tdaa::PastColorSamp, uv + float2(x, y) * px);
                float d = abs(Luma(h.rgb) - Luma(current));
                if(d < bestDiff) { bestDiff = d; bestHist = h; }
            }
        }
    }
    // Radius 3 (7x7 area outer ring)
    if (searchRadius >= 3) {
        [unroll] for(int y=-3; y<=3; y++)
        [unroll] for(int x=-3; x<=3; x++) {
            if (abs(x)==3 || abs(y)==3) {
                float4 h = tex2D(tdaa::PastColorSamp, uv + float2(x, y) * px);
                float d = abs(Luma(h.rgb) - Luma(current));
                if(d < bestDiff) { bestDiff = d; bestHist = h; }
            }
        }
    }

    // 4. Clamp History to current neighborhood (Variance Clipping)
    float3 ext = (nbMax - nbMin) * 0.25;
    float3 clampedHistYCoCg = clamp(RGBToYCoCg(bestHist.rgb), nbMin - ext, nbMax + ext);
    float3 clampedHist = YCoCgToRGB(clampedHistYCoCg);

    // 5. Calculate Stability and Blending Weight
    float match = exp(-bestDiff * 20.0);
    float newStab = saturate(prevStab + match * 0.05 - (1.0 - match) * 0.20);

    // Disocclusion mask (rejects history if pixel changed drastically)
    float disoc = saturate(bestDiff * TDAA_Temporal_GhostProtection);
    float baseWeight = TDAA_Temporal_Stability * newStab * (1.0 - disoc);
    float finalWeight = saturate(baseWeight);

    float3 blendedColor = lerp(current, clampedHist, finalWeight);

    TemporalOut outData;
    outData.color = float4(blendedColor, Luma(blendedColor));
    // Pack state: R=unused, G=Stability, B=Local Variance, A=Final Blend Weight
    outData.state = float4(0.0, newStab, localVariance, finalWeight);
    return outData;
}

// =============================================================================
// PASS 2: DETAIL & OUTPUT
// Reads: TempColor, TempState
// Writes: BackBuffer (Screen)
// =============================================================================
float4 PS_DetailAndPolish(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target {
    float2 px = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float3 current = tex2D(tdaa::TempColorSamp, uv).rgb;
    float4 state = tex2D(tdaa::TempStateSamp, uv);
    float finalWeight = state.a;
    float localVariance = state.b;

    // 4-tap cross pattern for local Laplacian
    float3 n1 = tex2D(tdaa::TempColorSamp, uv + float2( px.x,  0.0)).rgb;
    float3 n2 = tex2D(tdaa::TempColorSamp, uv + float2(-px.x,  0.0)).rgb;
    float3 n3 = tex2D(tdaa::TempColorSamp, uv + float2( 0.0,  px.y)).rgb;
    float3 n4 = tex2D(tdaa::TempColorSamp, uv + float2( 0.0, -px.y)).rgb;

    float3 blur = (n1 + n2 + n3 + n4) * 0.25;
    float contrast = Luma(current - blur);

    // --- DEBUG VIEWS ---
    if (TDAA_Debug_Enable) {
        if (TDAA_Debug_View == 1) {
            // History Blend Weight: White = trusting history, Black = rejecting history
            return float4(finalWeight.xxx, 1.0);
        }
        if (TDAA_Debug_View == 2) {
            // Detail Sharpen Mask: White = high detail (will be sharpened), Black = noise/flat
            float noiseThresh = lerp(0.001, 0.04, TDAA_Detail_NoiseProtection);
            float noiseMask = saturate(abs(contrast) / (noiseThresh + 1e-5));
            return float4(noiseMask.xxx, 1.0);
        }
        if (TDAA_Debug_View == 3) {
            // Variance Energy: Local YCoCg variance
            float varColor = saturate(localVariance * 5.0);
            return float4(varColor.xxx, 1.0);
        }
    }

    // --- DETAIL & POLISH LOGIC ---
    float noiseThresh = lerp(0.001, 0.04, TDAA_Detail_NoiseProtection);
    float noiseMask = saturate(abs(contrast) / (noiseThresh + 1e-5));

    // Selective sharpening: only applies to areas with valid high-frequency contrast
    float sharpAmount = TDAA_Detail_Sharpness * noiseMask;
    float3 sharp = current + (current - blur) * sharpAmount;

    // Micro-contrast polish
    float3 microContrast = sharp + (sharp - blur) * TDAA_Polish_MicroContrast;

    // Saturation adjustment
    float l = Luma(microContrast);
    float3 gray = float3(l, l, l);
    float3 finalColor = lerp(microContrast, lerp(gray, microContrast, 1.0 + TDAA_Polish_Saturation), abs(TDAA_Polish_Saturation) > 0.001);

    return float4(saturate(finalColor), 1.0);
}

// =============================================================================
// PASS 3: STATE SAVE (History Buffer Ping-Pong)
// Reads: TempColor, TempState
// Writes: PastColor, PastState
// =============================================================================
struct SaveOut {
    float4 color : SV_Target0;
    float4 state : SV_Target1;
};

SaveOut PS_Save(float4 pos : SV_Position, float2 uv : TEXCOORD) {
    SaveOut res;
    res.color = tex2D(tdaa::TempColorSamp, uv);
    res.state = tex2D(tdaa::TempStateSamp, uv);
    return res;
}


[numthreads(8,8,1)] void main(uint3 id : SV_DispatchThreadID) {
 if (any(id.xy >= uint2(params.target.zw))) return;
 float2 uv = (float2(id.xy) + 0.5) * params.metrics.xy;
#if STAGE == 0
 TemporalOut t;
 if (params.history_valid == 0) { t.color = tex0.Load(int3(id.xy,0)); t.color.a = Luma(t.color.rgb); t.state = 0; }
 else t = PS_Temporal(float4(id,1),uv);
 output0[id.xy] = t.color; output1[id.xy] = t.state;
#else
 output0[id.xy] = PS_DetailAndPolish(float4(id,1),uv);
#endif
}

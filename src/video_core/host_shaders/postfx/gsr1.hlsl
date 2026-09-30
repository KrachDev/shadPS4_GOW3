// SPDX-FileCopyrightText: Copyright 2023 Qualcomm Innovation Center, Inc.
// SPDX-License-Identifier: BSD-3-Clause

#include "common.hlsl"
#define SGSR_MOBILE 1
#define ViewportInfo params.metrics
#define  SGSR_H 1

half4 SGSRRH(float2 p)
{
    half4 res = tex0.GatherRed(linear_sampler, p);
    return res;
}
half4 SGSRGH(float2 p)
{
    half4 res = tex0.GatherGreen(linear_sampler, p);
    return res;
}
half4 SGSRBH(float2 p)
{
    half4 res = tex0.GatherBlue(linear_sampler, p);
    return res;
}
half4 SGSRAH(float2 p)
{
    half4 res = tex0.GatherAlpha(linear_sampler, p);
    return res;
}
half4 SGSRRGBH(float2 p)
{
    half4 res = tex0.SampleLevel(linear_sampler, p, 0);
    return res;
}

half4 SGSRH(float2 p, uint channel)
{
    if (channel == 0)
        return SGSRRH(p);
    if (channel == 1)
        return SGSRGH(p);
    if (channel == 2)
        return SGSRBH(p);
    return SGSRAH(p);
}

#include "gsr1.h"
// =====================================================================================
//
// SNAPDRAGON GAME SUPER RESOLUTION
//
// =====================================================================================
half4 SnapdragonGameSuperResolution(float2 uv)
{
	half4 OutColor = half4(0, 0, 0, 1);
    SgsrYuvH(OutColor, uv, ViewportInfo);
    return OutColor;
}

[numthreads(8,8,1)] void main(uint3 id : SV_DispatchThreadID) {
 if (any(id.xy >= uint2(params.target.zw))) return;
 output0[id.xy] = SnapdragonGameSuperResolution((float2(id.xy)+0.5)*params.target.xy);
}

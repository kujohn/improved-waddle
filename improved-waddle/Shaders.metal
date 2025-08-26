#include "../../Shared/MSDFFontKit/Sources/MSDFFontKit/Metal/text.metal"
#include "../../Shared/common.metal"
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
  float2 position [[attribute(0)]];
  float2 texCoord [[attribute(1)]];
};

struct VertexOut {
  float4 position [[position]];
  float2 texCoord;
};

struct Uniforms {
  float time;
  float2 resolution;
  int charCount;
};

vertex VertexOut vertexShader(VertexIn in [[stage_in]]) {
  VertexOut out;
  out.position = float4(in.position, 0.0, 1.0);
  out.texCoord = in.texCoord;
  return out;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               constant Uniforms &uniforms [[buffer(0)]],
                               constant FontUniforms &fontUniforms
                               [[buffer(1)]],
                               constant CharMetrics *textMetrics [[buffer(2)]],
                               texture2d<float> fontTexture [[texture(0)]]) {
  float2 uv = in.texCoord;
  constexpr sampler msdfSampler(mag_filter::linear, min_filter::linear);

  // Transform UV coordinates
  float2 msdfUV = uv * 2.0 - 1.0;
  msdfUV.x *= uniforms.resolution.x / uniforms.resolution.y;

  // Render text with MSDF
  float textMask = renderTextWithMetrics(
      fontUniforms, textMetrics, uniforms.charCount, float2(0.0, 0.0), 0.005,
      msdfUV, fontTexture, msdfSampler, true, 1.0);

  float3 color = float3(0.0);

  color = textMask;

  return float4(color, 1.0);
}

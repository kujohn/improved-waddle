#include <metal_stdlib>
using namespace metal;

struct Particle {
  float2 position;
  float2 velocity;
  float size;
  float rotation;
  float opacity;
  float2 targetPos;
  float state; // -1=DELAYED, 0=FLOWING_IN, 2=HOLDING
  float holdTime;
};

struct ParticleUniforms {
  float time;
  float deltaTime;
  uint particleCount;
};

// GPU-optimized compute shader with built-in culling
kernel void updateParticles(device Particle *particles [[buffer(0)]],
                            constant ParticleUniforms &uniforms [[buffer(1)]],
                            texture2d<float> textMask [[texture(0)]],
                            uint id [[thread_position_in_grid]]) {
  if (id >= uniforms.particleCount)
    return;

  Particle p = particles[id];

  // Constants for particle states
  const float DEAD = -2.0;
  const float DELAYED = -1.0;
  const float FLOWING_IN = 0.0;
  const float HOLDING = 2.0;

  // Handle delayed particles
  if (p.state == DELAYED) {
    p.holdTime -= uniforms.deltaTime;
    if (p.holdTime <= 0.0) {
      p.state = FLOWING_IN; // Start flowing toward text
      p.opacity = 0.8;      // Start clearly visible
      // Ensure particle starts from left edge
      if (p.position.x < 0.0) {
        p.position.x = 0.0;
      }
    } else {
      p.opacity = 0.0; // Keep invisible until time to start
      particles[id] = p;
      return;
    }
  }

  // For incoming flow, we'll check text mask only when settling
  constexpr sampler maskSampler(mag_filter::linear, min_filter::linear);
  float msdfDistance = 1.0; // Default to fully visible

  // Only check text mask when particle is settling or holding
  if (p.state == HOLDING) {
    msdfDistance = textMask.sample(maskSampler, p.targetPos).r;
    if (msdfDistance < 0.45) {
      p.opacity = 0.0;
      particles[id] = p;
      return;
    }
  }

  // Calculate edge smoothness using MSDF distance
  float edgeSmoothness = smoothstep(0.45, 0.52, msdfDistance);

  // State machine for particle behavior - flow in and settle
  if (p.state == HOLDING) {
    // Particles permanently hold their position in the text
    p.velocity = float2(0, 0);
    p.position = p.targetPos;         // Keep locked to target position
    p.opacity = edgeSmoothness * 0.8; // Visible when settled in text area
  } else if (p.state == FLOWING_IN) {
    // Calculate direction to target
    float2 toTarget = p.targetPos - p.position;
    float distanceToTarget = length(toTarget);

    // Direct movement toward target with some variation
    float particleRandom = float(id % 1000) / 1000.0;

    if (distanceToTarget > 0.008) {
      // Check if target position is actually within text using text mask
      float textMaskValue = textMask.sample(maskSampler, p.targetPos).r;
      if (textMaskValue < 0.45) {
        // Target is outside text - find a new valid target
        bool foundValidTarget = false;

        // Try up to 15 times to find a valid target position
        for (int attempt = 0; attempt < 15; attempt++) {
          // Generate more varied hash-based random position using time + id +
          // attempt
          float seed1 =
              float(id) + float(attempt) * 123.456 + uniforms.time * 0.1;
          float seed2 = float(id) * 7.89 + float(attempt) * 234.567 +
                        uniforms.time * 0.13;
          float seed3 = float(id) * 3.21 + float(attempt) * 456.789;

          float hash1 = fract(sin(seed1) * 43758.5453);
          float hash2 = fract(sin(seed2) * 43758.5453);
          float hash3 = fract(sin(seed3) * 43758.5453);

          // More uniform distribution across text area to prevent clustering
          float2 testTarget;
          testTarget.x = 0.15 + hash1 * 0.7; // Full text width
          testTarget.y = 0.35 + hash2 * 0.3; // Full text height

          // Add small random offset to break up patterns
          testTarget.x += (hash3 - 0.5) * 0.05;
          testTarget.y += (fract(sin(seed1 + seed2) * 12345.6789) - 0.5) * 0.04;

          // Test if this position is within text
          float testMaskValue = textMask.sample(maskSampler, testTarget).r;
          if (testMaskValue >= 0.45) {
            // Found valid target!
            p.targetPos = testTarget;
            foundValidTarget = true;
            break;
          }
        }

        if (!foundValidTarget) {
          // Still no valid target after 15 attempts - hide particle temporarily
          p.opacity = 0.0;
          p.state = DEAD;
          particles[id] = p;
          return;
        }
      }

      // Move toward target with speed based on distance
      float2 direction = normalize(toTarget);

      // Slow down as we approach target to prevent overshooting
      float speedMultiplier = min(distanceToTarget * 5.0, 1.0);
      float baseSpeed = 0.2 + particleRandom * 0.15;
      float speed = baseSpeed * speedMultiplier;

      // Calculate movement for this frame
      float2 movement = direction * speed * uniforms.deltaTime;

      // Don't move past the target
      if (length(movement) >= distanceToTarget) {
        // Would overshoot - just move to target
        p.position = p.targetPos;
        p.state = HOLDING;
        p.velocity = float2(0, 0);
      } else {
        // Safe to move normally
        float timeVariation = uniforms.time * 0.2 + particleRandom * 6.28318;
        float2 variation =
            float2(sin(timeVariation), cos(timeVariation)) * 0.005;

        p.velocity = direction * speed + variation * speedMultiplier;
        p.position += movement + variation * uniforms.deltaTime;

        // Gradually increase opacity as particle approaches target
        float approachFactor = 1.0 - (distanceToTarget / 0.5);
        p.opacity =
            clamp(approachFactor * (0.7 + particleRandom * 0.2), 0.0, 1.0);
      }
    } else {
      // Close enough - settle permanently at target
      p.state = HOLDING;
      p.position = p.targetPos;
      p.velocity = float2(0, 0);
    }
  }

  // Update rotation only for moving particles
  if (p.state == FLOWING_IN) {
    p.rotation += (length(p.velocity) * 0.3 + 0.1) * uniforms.deltaTime;
  }

  // Update opacity based on state
  if (p.state == HOLDING) {
    p.opacity = edgeSmoothness * 0.9; // Slightly transparent when settled
  }

  // Final check - ensure no particle drifts from its target
  if (p.state == HOLDING) {
    p.position = p.targetPos;  // Force exact position
    p.velocity = float2(0, 0); // Force zero velocity
  } else if (p.state == FLOWING_IN) {
    // Double-check distance in case of floating point errors
    float finalDistance = length(p.targetPos - p.position);
    if (finalDistance <= 0.008) {
      p.state = HOLDING;
      p.position = p.targetPos;
      p.velocity = float2(0, 0);
    }
  }

  particles[id] = p;
}

// Vertex shader for particle rendering
struct ParticleVertexIn {
  float2 position [[attribute(0)]];
};

struct ParticleVertexOut {
  float4 position [[position]];
  float2 texCoord;
  float opacity;
  float size [[point_size]];
};

vertex ParticleVertexOut particleVertex(ParticleVertexIn in [[stage_in]],
                                        constant Particle *particles
                                        [[buffer(1)]],
                                        constant float2 &resolution
                                        [[buffer(2)]],
                                        uint instanceID [[instance_id]]) {
  ParticleVertexOut out;

  Particle p = particles[instanceID];

  // Early culling: skip only truly dead particles
  if (p.state == -2.0 || (p.opacity <= 0.01 && p.state != -1.0)) {
    out.position = float4(-10.0, -10.0, 0.0, 1.0); // Move offscreen
    out.opacity = 0.0;
    out.texCoord = float2(0.0);
    out.size = 0.0;
    return out;
  }

  // Optimized rotation using precomputed values
  float c = cos(p.rotation);
  float s = sin(p.rotation);
  float2x2 rot = float2x2(c, -s, s, c);
  float2 rotatedPos = rot * (in.position * p.size);

  // Convert to screen space with aspect ratio correction
  float aspectRatio = resolution.x / resolution.y;
  float2 screenPos = p.position * 2.0 - 1.0;
  screenPos.y = -screenPos.y; // Flip Y
  screenPos += rotatedPos * float2(1.0 / aspectRatio, 1.0);

  out.position = float4(screenPos, 0.0, 1.0);
  out.texCoord = in.position * 0.5 + 0.5;
  out.opacity = p.opacity;
  out.size = p.size * resolution.y * 0.5;

  return out;
}

// Fragment shader for particle rendering
fragment float4 particleFragment(ParticleVertexOut in [[stage_in]]) {
  float3 color = float3(1, 1, 1);
  return float4(color, 1);
}

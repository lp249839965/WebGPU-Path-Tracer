#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_GOOGLE_include_directive : enable
#extension GL_EXT_nonuniform_qualifier : enable
#pragma shader_stage(closest)

#include "utils.glsl"

ShadingData shading;

#include "disney.glsl"

hitAttributeEXT vec3 Hit;

layout (location = 0) rayPayloadInEXT RayPayload Ray;
layout (location = 1) rayPayloadEXT ShadowRayPayload ShadowRay;

layout (binding = 0, set = 0) uniform accelerationStructureEXT topLevelAS;

layout (binding = 3) uniform CameraBuffer {
  vec4 forward;
  mat4 viewInverse;
  mat4 projectionInverse;
  mat4 viewProjection;
  mat4 previousViewInverse;
  mat4 previousProjectionInverse;
  float aperture;
  float focusDistance;
  float zNear;
  float zFar;
} Camera;

layout (binding = 4) uniform SettingsBuffer {
  uint sampleCount;
  uint totalSampleCount;
  uint lightCount;
  uint screenWidth;
  uint screenHeight;
  uint pad_0;
  uint pad_1;
  uint pad_2;
} Settings;

layout (binding = 5, std430) readonly buffer AttributeBuffer {
  Vertex Vertices[];
};

layout (binding = 6, std430) readonly buffer FaceBuffer {
  uint Faces[];
};

layout (binding = 7, std140, row_major) readonly buffer InstanceBuffer {
  Instance Instances[];
};

layout (binding = 8, std430) readonly buffer MaterialBuffer {
  Material Materials[];
};

layout (binding = 9, std430) readonly buffer LightBuffer {
  Light Lights[];
};

layout (binding = 10) uniform sampler TextureSampler;
layout (binding = 11) uniform texture2DArray TextureArray;

LightSource PickRandomLightSource(inout uint seed, in vec3 surfacePos, out vec3 lightDirection, out float lightDistance) {
  const uint lightIndex = 1 + uint(Randf01(seed) * Settings.lightCount);
  const uint geometryInstanceId = Lights[nonuniformEXT(lightIndex)].instanceIndex;
  const Instance instance = Instances[nonuniformEXT(geometryInstanceId)];

  const uint faceIndex = instance.faceIndex + uint(Randf01(seed) * instance.faceCount);

  const vec2 attribs = SampleTriangle(vec2(Randf01(seed), Randf01(seed)));

  const Vertex v0 = Vertices[instance.vertexIndex + Faces[faceIndex + 0]];
  const Vertex v1 = Vertices[instance.vertexIndex + Faces[faceIndex + 1]];
  const Vertex v2 = Vertices[instance.vertexIndex + Faces[faceIndex + 2]];

  const vec3 p0 = (instance.transformMatrix * vec4(v0.position.xyz, 1.0)).xyz;
  const vec3 p1 = (instance.transformMatrix * vec4(v1.position.xyz, 1.0)).xyz;
  const vec3 p2 = (instance.transformMatrix * vec4(v2.position.xyz, 1.0)).xyz;
  const vec3 pw = blerp(attribs, p0, p1, p2);

  const vec3 n0 = v0.normal.xyz;
  const vec3 n1 = v1.normal.xyz;
  const vec3 n2 = v2.normal.xyz;
  const vec3 nw = normalize(mat3x3(instance.normalMatrix) * blerp(attribs, n0.xyz, n1.xyz, n2.xyz));

  const float triangleArea = 0.5 * length(cross(p1 - p0, p2 - p0));

  const vec3 lightSurfacePos = pw;
  const vec3 lightEmission = Materials[instance.materialIndex].color.rgb;
  const vec3 lightNormal = normalize(lightSurfacePos - surfacePos);

  const vec3 lightPos = lightSurfacePos - surfacePos;
  const float lightDist = length(lightPos);
  const float lightDistSq = lightDist * lightDist;
  const vec3 lightDir = lightPos / lightDist;

  const float lightPdf = lightDistSq / (triangleArea * abs(dot(lightNormal, lightDir)));

  const vec4 emissionAndGeometryId = vec4(
    lightEmission, geometryInstanceId
  );
  const vec4 directionAndPdf = vec4(
    lightDir, lightPdf
  );

  // backface
  /*float cosTheta = dot(nw, normalize(lightPos));
  if (max(cosTheta, 0.0) >= EPSILON) {
    return LightSource(
      emissionAndGeometryId,
      vec4(lightDir, 0)
    );
  }*/

  lightDirection = lightDir;
  lightDistance = lightDist;

  return LightSource(
    emissionAndGeometryId,
    directionAndPdf
  );
}

vec3 DirectLight(const uint instanceId, in vec3 normal) {
  vec3 Lo = vec3(0.0);

  const LightSource lightSource = Ray.lightSource;

  const vec4 directionAndPdf = lightSource.directionAndPdf;
  const vec4 emissionAndGeometryId = lightSource.emissionAndGeometryId;

  const vec3 lightEmission = emissionAndGeometryId.xyz;
  const uint lightGeometryInstanceId = uint(emissionAndGeometryId.w);

  // if we hit a light source, then just returns its emission directly
  if (instanceId == lightGeometryInstanceId) return lightEmission;

  // abort if we are occluded
  if (Ray.shadowed) return Lo;

  const vec3 lightDir = directionAndPdf.xyz;
  const float lightPdf = directionAndPdf.w;
  const vec3 powerPdf = lightEmission * Settings.lightCount;

  const vec3 N = normal;
  const vec3 V = -gl_WorldRayDirectionEXT;
  const vec3 L = lightDir;
  const vec3 H = normalize(V + L);

  const float NdotH = max(0.0, dot(N, H));
  const float NdotL = max(0.0, dot(L, N));
  const float HdotL = max(0.0, dot(H, L));
  const float NdotV = max(0.0, dot(N, V));

  const float bsdfPdf = DisneyPdf(NdotH, NdotL, HdotL);

  const vec3 f = DisneyEval(NdotL, NdotV, NdotH, HdotL);

  Lo += powerHeuristic(lightPdf, bsdfPdf) * f * powerPdf / max(0.001, lightPdf);

  return max(vec3(0), Lo);
}

void main() {
  const vec3 surfacePosition = gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT * gl_RayTmaxEXT;
  const uint instanceId = gl_InstanceCustomIndexEXT;

  const Instance instance = Instances[nonuniformEXT(instanceId)];

  const Vertex v0 = Vertices[instance.vertexIndex + Faces[instance.faceIndex + gl_PrimitiveID * 3 + 0]];
  const Vertex v1 = Vertices[instance.vertexIndex + Faces[instance.faceIndex + gl_PrimitiveID * 3 + 1]];
  const Vertex v2 = Vertices[instance.vertexIndex + Faces[instance.faceIndex + gl_PrimitiveID * 3 + 2]];

  const vec2 u0 = v0.uv.xy, u1 = v1.uv.xy, u2 = v2.uv.xy;
  const vec3 n0 = v0.normal.xyz, n1 = v1.normal.xyz, n2 = v2.normal.xyz;
  const vec3 t0 = v0.tangent.xyz, t1 = v1.tangent.xyz, t2 = v2.tangent.xyz;

  const Material material = Materials[instance.materialIndex];

  const vec2 uv = blerp(Hit.xy, u0.xy, u1.xy, u2.xy) * material.textureScaling;
  const vec3 no = blerp(Hit.xy, n0.xyz, n1.xyz, n2.xyz);
  const vec3 ta = blerp(Hit.xy, t0.xyz, t1.xyz, t2.xyz);

  const vec3 nw = normalize(mat3x3(instance.normalMatrix) * no);
  const vec3 tw = normalize(mat3x3(instance.normalMatrix) * ta);
  const vec3 bw = cross(nw, tw);

  const vec3 tex0 = texture(sampler2DArray(TextureArray, TextureSampler), vec3(uv, material.albedoIndex)).rgb;
  const vec3 tex1 = texture(sampler2DArray(TextureArray, TextureSampler), vec3(uv, material.normalIndex)).rgb;
  const vec3 tex2 = texture(sampler2DArray(TextureArray, TextureSampler), vec3(uv, material.metalRoughnessIndex)).rgb;
  const vec3 tex3 = texture(sampler2DArray(TextureArray, TextureSampler), vec3(uv, material.emissionIndex)).rgb;

  // material color
  vec3 color = tex0 + material.color.rgb;
  // material normal
  const vec3 normal = normalize(
    material.normalIndex > 0 ?
    mat3(tw, bw, nw) * normalize((pow(tex1, vec3(INV_GAMMA))) * 2.0 - 1.0).xyz :
    nw
  );
  // material metalness/roughness
  const vec2 metalRoughness = pow(vec2(tex2.r, tex2.g), vec2(INV_GAMMA));
  // material emission
  const vec3 emission = pow(tex3, vec3(GAMMA)) * material.emissionIntensity;

  uint seed = Ray.seed;
  float t = gl_HitTEXT;

  vec3 radiance = vec3(0);
  vec3 throughput = Ray.throughput.rgb;

  radiance += emission * throughput;

  shading.base_color = color;
  shading.metallic = clamp(metalRoughness.r + material.metalness, 0.001, 0.999) * material.metalnessIntensity;
  shading.specular = material.specular;
  shading.roughness = clamp(metalRoughness.g + material.roughness, 0.001, 0.999) * material.roughnessIntensity;
  {
    const vec3 cd_lin = shading.base_color;
    const float cd_lum = dot(cd_lin, vec3(0.3, 0.6, 0.1));
    const vec3 c_spec0 = mix(shading.specular * vec3(0.3), cd_lin, shading.metallic);
    const float cs_lum = dot(c_spec0, vec3(0.3, 0.6, 0.1));
    const float cs_w = cs_lum / (cs_lum + (1.0 - shading.metallic) * cd_lum);
    shading.csw = cs_w;
  }

  // pick a random light source
  // also returns a direction which we will shoot our shadow ray to
  vec3 lightDirection = vec3(0);
  float lightDistance = 0.0;
  LightSource lightSource = PickRandomLightSource(Ray.seed, surfacePosition, lightDirection, lightDistance);
  Ray.lightSource = lightSource;

  // shoot the shadow ray
  traceRayEXT(topLevelAS, gl_RayFlagsTerminateOnFirstHitEXT, 0xFF, 1, 0, 1, surfacePosition, EPSILON, lightDirection, lightDistance - EPSILON, 1);
  Ray.shadowed = ShadowRay.shadowed;

  radiance += DirectLight(instanceId, normal) * throughput;

  const vec3 bsdfDir = DisneySample(seed, -gl_WorldRayDirectionEXT, normal);

  const vec3 N = normal;
  const vec3 V = -gl_WorldRayDirectionEXT;
  const vec3 L = bsdfDir;
  const vec3 H = normalize(V + L);

  const float NdotH = abs(dot(N, H));
  const float NdotL = abs(dot(L, N));
  const float HdotL = abs(dot(H, L));
  const float NdotV = abs(dot(N, V));

  const float pdf = DisneyPdf(NdotH, NdotL, HdotL);
  if (pdf > 0.0) {
    throughput *= DisneyEval(NdotL, NdotV, NdotH, HdotL) / pdf;
  } else {
    t = -1.0;
  }

  Ray.radianceAndDistance = vec4(radiance, t);
  Ray.scatterDirection = vec4(bsdfDir, t);
  Ray.throughput = vec4(throughput, 1);
  Ray.seed = seed;
}

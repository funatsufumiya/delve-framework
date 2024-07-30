//------------------------------------------------------------------------------
//  Shader code for the built in default shader, plus an emissive term.
//
//  NOTE: This source file also uses the '#pragma sokol' form of the
//  custom tags.
//------------------------------------------------------------------------------
#pragma sokol @header const m = @import("../../math.zig")
#pragma sokol @ctype mat4 m.Mat4

#pragma sokol @vs vs
uniform vs_params {
    mat4 u_projViewMatrix;
    mat4 u_modelMatrix;
    vec4 u_color;
};

in vec4 pos;
in vec4 color0;
in vec2 texcoord0;
in vec3 normals;
in vec4 tangents;

out vec4 color;
out vec2 uv;
out vec3 normal;
out vec4 tangent;
out vec4 position;

void main() {
    color = color0 * u_color;
    uv = texcoord0;

    // have to use these attributes to keep them from being stripped out
    normal = normals;
    tangent = tangents;

    position = u_modelMatrix * pos;
    gl_Position = u_projViewMatrix * position;
}
#pragma sokol @end

#pragma sokol @fs fs
uniform texture2D tex;
uniform texture2D tex_emissive;
uniform sampler smp;

uniform fs_params {
    vec4 u_cameraPos;
    vec4 u_color_override;
    float u_alpha_cutoff;
    vec4 u_dir_light_dir;
    vec4 u_dir_light_color;
    float u_num_point_lights;
    vec4 u_point_light_data[16]; // each light is packed as two vec4s
};

in vec4 color;
in vec2 uv;
in vec3 normal;
in vec4 tangent;
in vec4 position;
out vec4 frag_color;

void main() {
    vec4 c = texture(sampler2D(tex, smp), uv) * color;
    vec4 lit_color = vec4(0.0, 0.0, 0.0, 1.0);

    // to make sprite drawing easier, discard full alpha pixels
    if(c.a <= u_alpha_cutoff) {
        discard;
    }

    // simple lighting!
    for(int i = 0; i < int(u_num_point_lights); ++i) {
        vec4 point_light_pos_data = u_point_light_data[i * 2];
        vec4 point_light_color_data = u_point_light_data[(i * 2) + 1];

        vec3 lightPosEye = point_light_pos_data.xyz;
        vec3 lightColor = point_light_color_data.xyz;

        vec3 lightMinusPos = (lightPosEye - position.xyz);
        vec3 lightDir = normalize(lightMinusPos);
        float lightBrightness = max(dot( lightDir, normal), 0.0);

        float dist = length(lightMinusPos);
        float radius = point_light_pos_data.w;
        float attenuation = clamp(1.0 - dist/radius, 0.0, 1.0);

        // testing out a specular term
        vec3 cameraLocN = vec3(normalize(u_cameraPos));
        vec3 reflectAmt = normalize(reflect(-vec3(lightPosEye), normal));
        float specularAmt = max(0.0, dot(cameraLocN, reflectAmt));
        specularAmt = pow(specularAmt, 50.0);
        specularAmt = 0.0;

        lit_color.rgb += (lightBrightness * lightColor * attenuation) + (specularAmt * normalize(lightColor));
    }

    {
        // directional light
        vec4 lightDir = vec4(u_dir_light_dir.x, u_dir_light_dir.y, u_dir_light_dir.z, 0.0);
        vec4 lightColor = u_dir_light_color;

        float lightBrightness = max(dot( lightDir, vec4(normal, 0.0)), 0.0) * u_dir_light_dir.w;

        // testing out a specular term
        vec3 cameraLocN = vec3(normalize(u_cameraPos));
        vec3 reflectAmt = normalize(reflect(vec3(-lightDir), normal));
        float specularAmt = max(0.0, dot(cameraLocN, reflectAmt));
        specularAmt = pow(specularAmt, 30.0);
        specularAmt = 0.0;

        lit_color.rgb += (lightBrightness * lightColor.rgb) + (specularAmt * lightColor.rgb);
    }

    // apply lighting color on top of the base diffuse color
    c *= lit_color;

    // add the emissive term
    vec4 e = texture(sampler2D(tex_emissive, smp), uv);

    float e_amt = min(e.r + e.g + e.b, 1.0);
    c.rgb = (c.rgb * (1.0 - e_amt)) + (e.rgb);

    // for flash effects, allow a color to take over the final output
    float override_mod = 1.0 - u_color_override.a;
    c.rgb = (c.rgb * override_mod) + (u_color_override.rgb * u_color_override.a);

    frag_color = c;
}
#pragma sokol @end

#pragma sokol @program emissive vs fs

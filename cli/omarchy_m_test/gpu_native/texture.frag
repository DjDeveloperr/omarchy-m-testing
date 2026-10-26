#version 450
layout(set=0,binding=0) uniform sampler2D source_image;
layout(location=0) out vec4 color;
layout(push_constant) uniform Params { uint seed; } settings;
void main() {
    ivec2 p=ivec2(gl_FragCoord.xy)*ivec2(13,17);
    p+=ivec2(settings.seed*7u,settings.seed*11u);
    uvec4 total=uvec4(round(texelFetch(source_image,p&1023,0)*255.0))+
                uvec4(round(texelFetch(source_image,(p+ivec2(37,0))&1023,0)*255.0))+
                uvec4(round(texelFetch(source_image,(p+ivec2(0,53))&1023,0)*255.0))+
                uvec4(round(texelFetch(source_image,(p+ivec2(37,53))&1023,0)*255.0));
    color=vec4(total>>4u)/255.0;
}

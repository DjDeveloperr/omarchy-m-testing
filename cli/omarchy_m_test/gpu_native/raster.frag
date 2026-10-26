#version 450
layout(location=0) out vec4 color;
layout(push_constant) uniform Params { uint seed; } settings;
void main() {
    uvec2 p=uvec2(gl_FragCoord.xy);
    p+=uvec2(settings.seed,settings.seed*3u);
    color=vec4(float(p.x&15u),float(p.y&15u),float((p.x^p.y)&15u),15.0)/255.0;
}

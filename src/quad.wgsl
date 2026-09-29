@group(0) @binding(0) var<uniform> ortho: mat4x4<f32>;

struct VertexOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) fill: vec4<f32>,
};

@vertex
fn vs_main(
    @location(0) unit: vec2<f32>,
    @location(1) rect: vec4<f32>,
    @location(2) fill: vec4<f32>,
) -> VertexOut {
    var out: VertexOut;
    let pos = rect.xy + unit * rect.zw;
    out.clip = ortho * vec4<f32>(pos, 0.0, 1.0);
    out.fill = fill;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    return in.fill;
}

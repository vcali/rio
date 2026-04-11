// Per-instance text glyph pipeline.
//
// One instance per glyph quad. The vertex shader synthesises the four
// corners of a triangle-strip unit quad from `vertex_id`, scales them
// into screen space using the per-instance `pos` + `size`, and computes
// the atlas UV from the per-instance `uv_min` / `uv_max`.
//
// The fragment shader picks between sampling the color atlas (for color
// glyphs / emoji) or the mask atlas (for subpixel-rendered text) based
// on which of `color_layer` / `mask_layer` is non-zero. Mask samples
// are tinted by the per-instance `color`; color samples are output
// as-is (with `color` acting as a tint, typically white).

struct Globals {
    transform: mat4x4<f32>,
}

@group(0) @binding(0) var<uniform> globals: Globals;
@group(0) @binding(1) var glyph_sampler: sampler;
@group(1) @binding(0) var color_texture: texture_2d<f32>; // RGBA color atlas
@group(1) @binding(1) var mask_texture: texture_2d<f32>;  // R8 alpha-mask atlas

struct InstanceInput {
    // Top-left of the glyph quad in physical pixels.
    @location(0) pos: vec2<f32>,
    // Width / height of the glyph quad in physical pixels.
    @location(1) size: vec2<f32>,
    // Atlas UV of the top-left corner (normalised 0..1).
    @location(2) uv_min: vec2<f32>,
    // Atlas UV of the bottom-right corner (normalised 0..1).
    @location(3) uv_max: vec2<f32>,
    // RGBA tint (white for color glyphs, text color for mask glyphs).
    @location(4) color: vec4<f32>,
    // [color_atlas_layer, mask_atlas_layer]. Exactly one is non-zero.
    @location(5) layers: vec2<i32>,
    // [x, y, w, h] in physical pixels. [0,0,0,0] = no clip.
    @location(6) clip_rect: vec4<f32>,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) @interpolate(flat) color: vec4<f32>,
    @location(2) @interpolate(flat) color_layer: i32,
    @location(3) @interpolate(flat) mask_layer: i32,
    @location(4) @interpolate(flat) clip_rect: vec4<f32>,
    @location(5) screen_pos: vec2<f32>,
}

@vertex
fn vs_main(
    @builtin(vertex_index) vid: u32,
    instance: InstanceInput,
) -> VertexOutput {
    // Triangle strip: 4 vertices → quad
    //   0 → 1
    //   |  /|
    //   2 → 3
    var corner: vec2<f32>;
    corner.x = f32(vid == 1u || vid == 3u);
    corner.y = f32(vid == 2u || vid == 3u);

    // Screen-space position
    let screen_pos = instance.pos + instance.size * corner;
    // Atlas UV
    let uv = instance.uv_min + (instance.uv_max - instance.uv_min) * corner;

    var out: VertexOutput;
    out.position = globals.transform * vec4<f32>(screen_pos, 0.0, 1.0);
    out.uv = uv;
    out.color = instance.color;
    out.color_layer = instance.layers.x;
    out.mask_layer = instance.layers.y;
    out.clip_rect = instance.clip_rect;
    out.screen_pos = screen_pos;
    return out;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    // Pixel-space clip-rect test. `[0,0,0,0]` => no clipping.
    if (input.clip_rect.z > 0.0 && input.clip_rect.w > 0.0) {
        let p = input.screen_pos;
        if (p.x < input.clip_rect.x ||
            p.y < input.clip_rect.y ||
            p.x > input.clip_rect.x + input.clip_rect.z ||
            p.y > input.clip_rect.y + input.clip_rect.w) {
            return vec4<f32>(0.0);
        }
    }

    if (input.mask_layer > 0) {
        // Subpixel-rendered text: sample R8 alpha and tint by color.
        let alpha = textureSample(mask_texture, glyph_sampler, input.uv).r;
        return vec4<f32>(input.color.rgb, input.color.a * alpha);
    }

    if (input.color_layer > 0) {
        // Color glyph (e.g. emoji): sample full RGBA, modulate by color
        // (which is typically opaque white for emoji but can be used to
        //  fade glyphs).
        let sample = textureSample(color_texture, glyph_sampler, input.uv);
        return sample * input.color;
    }

    return vec4<f32>(0.0);
}

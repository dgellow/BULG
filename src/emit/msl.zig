//! What the MSL text needs beyond the printer it shares with GLSL: type names, the layout
//! of structs in Metal's memory, the names Metal and C++ keep for themselves, and the
//! prelude: the GLSL built-ins Metal spells differently, written once as functions of
//! the same name, so the body keeps the source's calls.

const std = @import("std");
const types = @import("../sema/types.zig");
const Type = types.Type;

pub const header =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
;

/// The MSL name of a built-in type (`half` is `float` in v0, as on GL).
pub fn typeName(t: Type) []const u8 {
    return switch (t) {
        .void => "void",
        .bool => "bool",
        .int => "int",
        .uint => "uint",
        .float, .half => "float",
        .bvec2 => "bool2",
        .bvec3 => "bool3",
        .bvec4 => "bool4",
        .ivec2 => "int2",
        .ivec3 => "int3",
        .ivec4 => "int4",
        .uvec2 => "uint2",
        .uvec3 => "uint3",
        .uvec4 => "uint4",
        .vec2, .hvec2 => "float2",
        .vec3, .hvec3 => "float3",
        .vec4, .hvec4 => "float4",
        .mat2, .hmat2 => "float2x2",
        .mat3, .hmat3 => "float3x3",
        .mat4, .hmat4 => "float4x4",
        .sampler2D => "sampler2D",
        else => unreachable,
    };
}

pub const Layout = struct { size: u32, alignment: u32 };

/// Size and alignment of a built-in type in Metal's memory (MSL specification, 2.2).
pub fn layout(t: Type) Layout {
    return switch (t) {
        .bool => .{ .size = 1, .alignment = 1 },
        .int, .uint, .float, .half => .{ .size = 4, .alignment = 4 },
        .bvec2 => .{ .size = 2, .alignment = 2 },
        .bvec3, .bvec4 => .{ .size = 4, .alignment = 4 },
        .ivec2, .uvec2, .vec2, .hvec2 => .{ .size = 8, .alignment = 8 },
        .ivec3, .uvec3, .vec3, .hvec3, .ivec4, .uvec4, .vec4, .hvec4 => .{ .size = 16, .alignment = 16 },
        .mat2, .hmat2 => .{ .size = 16, .alignment = 8 },
        .mat3, .hmat3 => .{ .size = 48, .alignment = 16 },
        .mat4, .hmat4 => .{ .size = 64, .alignment = 16 },
        else => unreachable,
    };
}

pub fn alignUp(x: u32, a: u32) u32 {
    return (x + a - 1) / a * a;
}

/// Names a text must not give its own declarations: C++ and Metal keywords, Metal's types
/// and the functions the emitter calls. A declaration, local or field with one of them is
/// printed as `bulg_<name>`, and the `bulg_` prefix is the emitter's own.
pub fn reserved(n: []const u8) bool {
    if (std.mem.startsWith(u8, n, "bulg_")) return true;
    return reserved_set.has(n);
}

const reserved_set = std.StaticStringMap(void).initComptime(blk: {
    const words = [_][]const u8{
        // C++ (MSL is C++14), with the alternative tokens
        "alignas",                "alignof",                 "and",                       "and_eq",                  "asm",
        "auto",                   "bitand",                  "bitor",                     "case",                    "catch",
        "char",                   "char16_t",                "char32_t",                  "class",                   "compl",
        "const_cast",             "constexpr",               "decltype",                  "default",                 "delete",
        "double",                 "dynamic_cast",            "enum",                      "explicit",                "export",
        "extern",                 "false",                   "friend",                    "goto",                    "inline",
        "long",                   "mutable",                 "namespace",                 "new",                     "noexcept",
        "not",                    "not_eq",                  "nullptr",                   "operator",                "or",
        "or_eq",                  "private",                 "protected",                 "public",                  "register",
        "reinterpret_cast",       "short",                   "signed",                    "sizeof",                  "static",
        "static_assert",          "static_cast",             "switch",                    "template",                "this",
        "thread_local",           "throw",                   "true",                      "try",                     "typedef",
        "typeid",                 "typename",                "union",                     "unsigned",                "using",
        "virtual",                "volatile",                "wchar_t",                   "xor",                     "xor_eq",
        "main0",
        // Metal: address spaces, stages, attributes, types
                         "constant",                "device",                    "thread",                  "threadgroup",
        "threadgroup_imageblock", "ray_data",                "object_data",               "kernel",                  "vertex",
        "fragment",               "visible",                 "stage_in",                  "sampler",                 "texture",
        "texture1d",              "texture2d",               "texture3d",                 "texturecube",             "texture2d_array",
        "depth2d",                "access",                  "coord",                     "filter",                  "address",
        "mip_filter",             "compare_func",            "level",                     "bias",                    "gradient2d",
        "min_lod_clamp",          "array",                   "array_ref",                 "packed_float2",           "packed_float3",
        "packed_float4",          "metal",                   "uchar",                     "ushort",                  "ulong",
        "size_t",                 "ptrdiff_t",               "float2",                    "float3",                  "float4",
        "float2x2",               "float3x3",                "float4x4",                  "int2",                    "int3",
        "int4",                   "uint2",                   "uint3",                     "uint4",                   "bool2",
        "bool3",                  "bool4",                   "half2",                     "half3",                   "half4",
        "vec",                    "matrix",                  "atomic",                    "imageblock",              "patch_control_point",
        // the functions the text calls by Metal's names
        "as_type",                "atan2",                   "rsqrt",                     "dfdx",                    "dfdy",
        "rint",                   "select",                  "discard_fragment",          "saturate",                "fmod",
        "fma",                    "pack_float_to_snorm2x16", "unpack_snorm2x16_to_float", "pack_float_to_unorm2x16", "unpack_unorm2x16_to_float",
        "sample",                 "read",                    "get_width",                 "get_height",
        // the prelude
                     "sampler2D",
        "mod",                    "radians",                 "degrees",                   "lessThan",                "lessThanEqual",
        "greaterThan",            "greaterThanEqual",        "equal",                     "notEqual",                "matrixCompMult",
        "outerProduct",           "inverse",                 "texture2D",                 "textureLod",              "texelFetch",
        "textureSize",
    };
    var kv: [words.len]struct { []const u8 } = undefined;
    for (words, 0..) |w, i| kv[i] = .{w};
    break :blk kv;
});

/// A piece of the prelude, written only when the text uses it.
pub const Helper = enum {
    sampler,
    mod,
    radians,
    degrees,
    relational,
    comp_mult2,
    comp_mult3,
    comp_mult4,
    outer2,
    outer3,
    outer4,
    inverse2,
    inverse3,
    inverse4,
    diag2,
    diag3,
    diag4,
    // a matrix from one of another size: to N from M
    mat2_3,
    mat2_4,
    mat3_2,
    mat3_4,
    mat4_2,
    mat4_3,

    pub fn matFrom(to: u8, from: u8) Helper {
        return switch (to) {
            2 => if (from == 3) .mat2_3 else .mat2_4,
            3 => if (from == 2) .mat3_2 else .mat3_4,
            else => if (from == 2) .mat4_2 else .mat4_3,
        };
    }
};

/// The sampler in a vertex stage: there are no derivatives there, so `texture` reads level 0
/// (as GLSL defines it for vertex shaders).
pub const sampler_vertex =
    \\struct sampler2D { texture2d<float> t; sampler s; };
    \\static inline float4 texture(sampler2D x, float2 uv) { return x.t.sample(x.s, uv, level(0.0f)); }
    \\static inline float4 texture(sampler2D x, float2 uv, float b) { return x.t.sample(x.s, uv, level(0.0f)); }
    \\static inline float4 textureLod(sampler2D x, float2 uv, float l) { return x.t.sample(x.s, uv, level(l)); }
    \\static inline float4 texelFetch(sampler2D x, int2 p, int l) { return x.t.read(uint2(p), uint(l)); }
    \\static inline int2 textureSize(sampler2D x, int l) { return int2(int(x.t.get_width(uint(l))), int(x.t.get_height(uint(l)))); }
    \\
;

pub fn helperText(h: Helper) []const u8 {
    return switch (h) {
        .sampler =>
        \\struct sampler2D { texture2d<float> t; sampler s; };
        \\static inline float4 texture(sampler2D x, float2 uv) { return x.t.sample(x.s, uv); }
        \\static inline float4 texture(sampler2D x, float2 uv, float b) { return x.t.sample(x.s, uv, bias(b)); }
        \\static inline float4 textureLod(sampler2D x, float2 uv, float l) { return x.t.sample(x.s, uv, level(l)); }
        \\static inline float4 texelFetch(sampler2D x, int2 p, int l) { return x.t.read(uint2(p), uint(l)); }
        \\static inline int2 textureSize(sampler2D x, int l) { return int2(int(x.t.get_width(uint(l))), int(x.t.get_height(uint(l)))); }
        \\
        ,
        // GLSL's mod floors; Metal's fmod truncates
        .mod =>
        \\template<typename T> inline T mod(T x, T y) { return x - y * floor(x / y); }
        \\
        ,
        .radians =>
        \\template<typename T> inline T radians(T x) { return x * 0.01745329251994329577f; }
        \\
        ,
        .degrees =>
        \\template<typename T> inline T degrees(T x) { return x * 57.2957795130823208768f; }
        \\
        ,
        .relational =>
        \\template<typename T> inline decltype(T() < T()) lessThan(T a, T b) { return a < b; }
        \\template<typename T> inline decltype(T() < T()) lessThanEqual(T a, T b) { return a <= b; }
        \\template<typename T> inline decltype(T() < T()) greaterThan(T a, T b) { return a > b; }
        \\template<typename T> inline decltype(T() < T()) greaterThanEqual(T a, T b) { return a >= b; }
        \\template<typename T> inline decltype(T() == T()) equal(T a, T b) { return a == b; }
        \\template<typename T> inline decltype(T() == T()) notEqual(T a, T b) { return a != b; }
        \\
        ,
        .comp_mult2 => "static inline float2x2 matrixCompMult(float2x2 a, float2x2 b) { return float2x2(a[0] * b[0], a[1] * b[1]); }\n",
        .comp_mult3 => "static inline float3x3 matrixCompMult(float3x3 a, float3x3 b) { return float3x3(a[0] * b[0], a[1] * b[1], a[2] * b[2]); }\n",
        .comp_mult4 => "static inline float4x4 matrixCompMult(float4x4 a, float4x4 b) { return float4x4(a[0] * b[0], a[1] * b[1], a[2] * b[2], a[3] * b[3]); }\n",
        .outer2 => "static inline float2x2 outerProduct(float2 c, float2 r) { return float2x2(c * r.x, c * r.y); }\n",
        .outer3 => "static inline float3x3 outerProduct(float3 c, float3 r) { return float3x3(c * r.x, c * r.y, c * r.z); }\n",
        .outer4 => "static inline float4x4 outerProduct(float4 c, float4 r) { return float4x4(c * r.x, c * r.y, c * r.z, c * r.w); }\n",
        .inverse2 => "static inline float2x2 inverse(float2x2 m) { return float2x2(float2(m[1][1], -m[0][1]), float2(-m[1][0], m[0][0])) * (1.0f / determinant(m)); }\n",
        // the rows of the inverse are the cross products of the columns, over the determinant
        .inverse3 => "static inline float3x3 inverse(float3x3 m) { float3 a = m[0], b = m[1], c = m[2]; float3 r0 = cross(b, c), r1 = cross(c, a), r2 = cross(a, b); return transpose(float3x3(r0, r1, r2)) * (1.0f / dot(a, r0)); }\n",
        .inverse4 =>
        \\static inline float4x4 inverse(float4x4 m) {
        \\  float a00 = m[0][0], a01 = m[0][1], a02 = m[0][2], a03 = m[0][3];
        \\  float a10 = m[1][0], a11 = m[1][1], a12 = m[1][2], a13 = m[1][3];
        \\  float a20 = m[2][0], a21 = m[2][1], a22 = m[2][2], a23 = m[2][3];
        \\  float a30 = m[3][0], a31 = m[3][1], a32 = m[3][2], a33 = m[3][3];
        \\  float b00 = a00 * a11 - a01 * a10, b01 = a00 * a12 - a02 * a10, b02 = a00 * a13 - a03 * a10;
        \\  float b03 = a01 * a12 - a02 * a11, b04 = a01 * a13 - a03 * a11, b05 = a02 * a13 - a03 * a12;
        \\  float b06 = a20 * a31 - a21 * a30, b07 = a20 * a32 - a22 * a30, b08 = a20 * a33 - a23 * a30;
        \\  float b09 = a21 * a32 - a22 * a31, b10 = a21 * a33 - a23 * a31, b11 = a22 * a33 - a23 * a32;
        \\  float det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
        \\  return float4x4(
        \\    float4(a11 * b11 - a12 * b10 + a13 * b09, a02 * b10 - a01 * b11 - a03 * b09, a31 * b05 - a32 * b04 + a33 * b03, a22 * b04 - a21 * b05 - a23 * b03),
        \\    float4(a12 * b08 - a10 * b11 - a13 * b07, a00 * b11 - a02 * b08 + a03 * b07, a32 * b02 - a30 * b05 - a33 * b01, a20 * b05 - a22 * b02 + a23 * b01),
        \\    float4(a10 * b10 - a11 * b08 + a13 * b06, a01 * b08 - a00 * b10 - a03 * b06, a30 * b04 - a31 * b02 + a33 * b00, a21 * b02 - a20 * b04 - a23 * b00),
        \\    float4(a11 * b07 - a10 * b09 - a12 * b06, a00 * b09 - a01 * b07 + a02 * b06, a31 * b01 - a30 * b03 - a32 * b00, a20 * b03 - a21 * b01 + a22 * b00)) * (1.0f / det);
        \\}
        \\
        ,
        .diag2 => "static inline float2x2 bulg_diag2(float s) { return float2x2(float2(s, 0.0f), float2(0.0f, s)); }\n",
        .diag3 => "static inline float3x3 bulg_diag3(float s) { return float3x3(float3(s, 0.0f, 0.0f), float3(0.0f, s, 0.0f), float3(0.0f, 0.0f, s)); }\n",
        .diag4 => "static inline float4x4 bulg_diag4(float s) { return float4x4(float4(s, 0.0f, 0.0f, 0.0f), float4(0.0f, s, 0.0f, 0.0f), float4(0.0f, 0.0f, s, 0.0f), float4(0.0f, 0.0f, 0.0f, s)); }\n",
        // GLSL: the columns cut to size, or filled from the identity
        .mat2_3 => "static inline float2x2 bulg_mat2(float3x3 m) { return float2x2(m[0].xy, m[1].xy); }\n",
        .mat2_4 => "static inline float2x2 bulg_mat2(float4x4 m) { return float2x2(m[0].xy, m[1].xy); }\n",
        .mat3_2 => "static inline float3x3 bulg_mat3(float2x2 m) { return float3x3(float3(m[0], 0.0f), float3(m[1], 0.0f), float3(0.0f, 0.0f, 1.0f)); }\n",
        .mat3_4 => "static inline float3x3 bulg_mat3(float4x4 m) { return float3x3(m[0].xyz, m[1].xyz, m[2].xyz); }\n",
        .mat4_2 => "static inline float4x4 bulg_mat4(float2x2 m) { return float4x4(float4(m[0], 0.0f, 0.0f), float4(m[1], 0.0f, 0.0f), float4(0.0f, 0.0f, 1.0f, 0.0f), float4(0.0f, 0.0f, 0.0f, 1.0f)); }\n",
        .mat4_3 => "static inline float4x4 bulg_mat4(float3x3 m) { return float4x4(float4(m[0], 0.0f), float4(m[1], 0.0f), float4(m[2], 0.0f), float4(0.0f, 0.0f, 0.0f, 1.0f)); }\n",
    };
}

test "layouts follow Metal's rules" {
    try std.testing.expectEqual(Layout{ .size = 16, .alignment = 16 }, layout(.vec3));
    try std.testing.expectEqual(Layout{ .size = 48, .alignment = 16 }, layout(.mat3));
    try std.testing.expectEqual(@as(u32, 32), alignUp(17, 16));
}

test "reserved names" {
    try std.testing.expect(reserved("sampler"));
    try std.testing.expect(reserved("bulg_x"));
    try std.testing.expect(reserved("not"));
    try std.testing.expect(!reserved("pal"));
}

//! Reflection as JSON, for hosts that are not Zig and for tools. The format is versioned:
//! `"format": "glint.reflection/1"`. A change that a reader could trip on (a field
//! renamed or removed, a meaning changed) takes the next number; new fields do not.
//!
//!     { "format": "glint.reflection/1", "programs": [ {
//!         "name": "reef",
//!         "blocks": [ { "name", "module", "size", "stages": ["fragment"],
//!                       "members": [ { "name", "type", "offset", "size", "default": [1, 0] | null } ] } ],
//!         "uniforms": [ { "name", "type", "stages", "meta" } ],
//!         "samplers": [ { "name", "slot", "stages" } ],
//!         "params": [ { "name", "type", "default": [..], "stages", "meta" } ],
//!         "specs": [ { "name", "type", "value", "default", "meta" } ],
//!         "inputs" | "varyings" | "outputs": [ { "name", "type", "location": 0 | null, "flat" } ],
//!         "uses": { "vertex": [...], "fragment": [...] },
//!         "files": [ "path", ... ] } ] }
//!
//! Types are GLSL's names (`vec3`, `float[9]`, a struct's name). Numbers are numbers;
//! bools in values are `true`/`false`. Metadata is `{ "key", "args": [ 1.5 | {"string": ".."} | {"word": ".."} ] }`.

const std = @import("std");
const Session = @import("../Session.zig");
const Ir = @import("../ir/Ir.zig");
const R = @import("Reflection.zig");

pub const format = "glint.reflection/1";

pub const Error = error{ OutOfMemory, NotChecked };

/// Every program of the session that is not a template, as one JSON document.
pub fn write(s: *const Session, w: *std.Io.Writer, a: std.mem.Allocator) (Error || std.Io.Writer.Error)!void {
    var j: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try j.beginObject();
    try j.objectField("format");
    try j.write(format);
    try j.objectField("programs");
    try j.beginArray();
    for (s.programs) |*p| {
        if (p.is_template) continue;
        const r = try R.reflect(s, p, a);
        try program(s, &j, r);
    }
    try j.endArray();
    try j.endObject();
}

fn typeName(s: *const Session, t: @import("../sema/types.zig").Type, a: std.mem.Allocator) []const u8 {
    var buf: [128]u8 = undefined;
    return a.dupe(u8, s.pool.name(t, &buf)) catch "?";
}

fn program(s: *const Session, j: *std.json.Stringify, r: R.Reflection) std.Io.Writer.Error!void {
    var name_buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&name_buf);
    const a = fba.allocator();
    try j.beginObject();
    try j.objectField("name");
    try j.write(r.name);

    try j.objectField("blocks");
    try j.beginArray();
    for (r.blocks) |b| {
        try j.beginObject();
        try field(j, "name", b.name);
        try field(j, "module", b.module);
        try field(j, "size", b.size);
        try stages(j, b.stages);
        try j.objectField("members");
        try j.beginArray();
        for (b.members) |m| {
            fba.reset();
            try j.beginObject();
            try field(j, "name", m.name);
            try field(j, "type", typeName(s, m.type, a));
            try field(j, "offset", m.offset);
            try field(j, "size", m.size);
            try j.objectField("default");
            if (m.default) |d| try values(j, d) else try j.write(null);
            try j.endObject();
        }
        try j.endArray();
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("uniforms");
    try j.beginArray();
    for (r.uniforms) |u| {
        fba.reset();
        try j.beginObject();
        try field(j, "name", u.name);
        try field(j, "type", typeName(s, u.type, a));
        try stages(j, u.stages);
        try metas(j, u.meta);
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("samplers");
    try j.beginArray();
    for (r.samplers) |sm| {
        try j.beginObject();
        try field(j, "name", sm.name);
        try field(j, "slot", sm.slot);
        try stages(j, sm.stages);
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("params");
    try j.beginArray();
    for (r.params) |p| {
        fba.reset();
        try j.beginObject();
        try field(j, "name", p.name);
        try field(j, "type", typeName(s, p.type, a));
        try j.objectField("default");
        try values(j, p.default);
        try stages(j, p.stages);
        try metas(j, p.meta);
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("specs");
    try j.beginArray();
    for (r.specs) |sp| {
        fba.reset();
        try j.beginObject();
        try field(j, "name", sp.name);
        try field(j, "type", typeName(s, sp.type, a));
        try j.objectField("value");
        try value(j, sp.value);
        try j.objectField("default");
        try value(j, sp.default);
        try metas(j, sp.meta);
        try j.endObject();
    }
    try j.endArray();

    for ([_]struct { []const u8, []const R.Attribute }{ .{ "inputs", r.inputs }, .{ "varyings", r.varyings }, .{ "outputs", r.outputs } }) |list| {
        try j.objectField(list[0]);
        try j.beginArray();
        for (list[1]) |at| {
            fba.reset();
            try j.beginObject();
            try field(j, "name", at.name);
            try field(j, "type", typeName(s, at.type, a));
            try field(j, "location", at.location);
            try field(j, "flat", at.flat);
            try j.endObject();
        }
        try j.endArray();
    }

    try j.objectField("uses");
    try j.beginObject();
    try uses(j, "vertex", r.vertex_uses);
    try uses(j, "fragment", r.fragment_uses);
    try j.endObject();

    try j.objectField("files");
    try j.write(r.files);
    try j.endObject();
}

fn field(j: *std.json.Stringify, name: []const u8, v: anytype) std.Io.Writer.Error!void {
    try j.objectField(name);
    try j.write(v);
}

fn stages(j: *std.json.Stringify, st: R.Stages) std.Io.Writer.Error!void {
    try j.objectField("stages");
    try j.beginArray();
    if (st.vertex) try j.write("vertex");
    if (st.fragment) try j.write("fragment");
    try j.endArray();
}

fn value(j: *std.json.Stringify, c: Ir.Const) std.Io.Writer.Error!void {
    switch (c) {
        .bool => |b| try j.write(b),
        .int => |i| try j.write(i),
        .uint => |u| try j.write(u),
        .float => |f| try j.write(f),
    }
}

fn values(j: *std.json.Stringify, cs: []const Ir.Const) std.Io.Writer.Error!void {
    try j.beginArray();
    for (cs) |c| try value(j, c);
    try j.endArray();
}

fn metas(j: *std.json.Stringify, ms: []const R.Meta) std.Io.Writer.Error!void {
    try j.objectField("meta");
    try j.beginArray();
    for (ms) |m| {
        try j.beginObject();
        try field(j, "key", m.key);
        try j.objectField("args");
        try j.beginArray();
        for (m.args) |arg| switch (arg) {
            .value => |c| try value(j, c),
            .string => |str| {
                try j.beginObject();
                try field(j, "string", str);
                try j.endObject();
            },
            .word => |str| {
                try j.beginObject();
                try field(j, "word", str);
                try j.endObject();
            },
        };
        try j.endArray();
        try j.endObject();
    }
    try j.endArray();
}

fn uses(j: *std.json.Stringify, name: []const u8, u: Ir.Uses) std.Io.Writer.Error!void {
    try j.objectField(name);
    try j.beginArray();
    inline for (.{ "discard", "derivatives", "textures", "frag_coord", "front_facing", "point_coord", "position", "point_size", "vertex_id", "instance_id" }) |f| {
        if (@field(u, f)) try j.write(f);
    }
    try j.endArray();
}

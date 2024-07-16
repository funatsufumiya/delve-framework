const std = @import("std");
const graphics = @import("../platform/graphics.zig");
const debug = @import("../debug.zig");
const zmesh = @import("zmesh");
const math = @import("../math.zig");
const mem = @import("../mem.zig");
const colors = @import("../colors.zig");
const boundingbox = @import("../spatial/boundingbox.zig");
const mesh = @import("mesh.zig");
const interpolation = @import("../utils/interpolation.zig");

const Vertex = graphics.Vertex;
const Color = colors.Color;
const Rect = @import("../spatial/rect.zig").Rect;
const Frustum = @import("../spatial/frustum.zig").Frustum;
const Vec3 = math.Vec3;
const Vec2 = math.Vec2;
const Mesh = mesh.Mesh;
const MeshConfig = mesh.MeshConfig;

// For now, support just 64 bones
pub const max_joints: usize = 64;

pub fn getSkinnedShaderAttributes() []const graphics.ShaderAttribute {
    return mesh.getSkinnedShaderAttributes();
}

pub const PlayingAnimation = struct {
    anim_idx: usize = 0,
    time: f32 = 0.0,
    speed: f32 = 0.0,
    playing: bool = true,
    looping: bool = true,
    blend_alpha: f32 = 1.0,

    // lerp into or out of an animation
    lerp_time: f32 = 0.0,// how long it takes to blend into this animation
    lerp_timer: f32 = 0.0, // current lerp time
    lerp_start_amount: f32 = 0.0,   // eg: set start to 1 and end to 0 to blend out
    lerp_end_amount: f32 = 1.0,

    // length of animation. calculated on play
    duration: f32 = 0.0,

    // calced transforms of all joints in the animation (excluding skeleton)
    joint_transforms: ?std.ArrayList(AnimationTransform) = null,

    // calced transform matrices of all joints (including skeleton)
    joint_calced_matrices: ?std.ArrayList(math.Mat4) = null,

    pub fn isDonePlaying(self: *PlayingAnimation) bool {
        return self.time >= self.duration;
    }
};

const AnimationTransform = struct {
    translation: math.Vec3 = math.Vec3.zero,
    scale: math.Vec3 = math.Vec3.one,
    rotation: math.Quaternion = math.Quaternion.identity,

    // cache the calculated mat4
    calced_matrix: math.Mat4 = undefined,

    pub fn toMat4(self: *AnimationTransform) math.Mat4 {
        const mat = math.Mat4.recompose(self.translation, self.rotation, self.scale);

        // cache this calc to use later
        self.calced_matrix = mat;

        return mat;
    }
};

/// A skinned mesh is a mesh that can play animations based on joint data
pub const SkinnedMesh = struct {
    mesh: Mesh = undefined,

    joint_transforms: ?std.ArrayList(AnimationTransform) = null,
    joint_transform_mats: [max_joints]math.Mat4 = [_]math.Mat4{math.Mat4.identity} ** max_joints,

    joint_locations: [max_joints]math.Mat4 = [_]math.Mat4{math.Mat4.identity} ** max_joints,

    pub fn initFromFile(allocator: std.mem.Allocator, filename: [:0]const u8, cfg: MeshConfig) ?SkinnedMesh {
        const loaded_mesh = Mesh.initFromFile(allocator, filename, cfg);
        if (loaded_mesh) |loaded| {
            var transforms = std.ArrayList(AnimationTransform).init(allocator);
            for(0..max_joints) |_| {
                transforms.append(.{}) catch { };
            }
            return .{ .mesh = loaded, .joint_transforms = transforms };
        }
        return null;
    }

    pub fn deinit(self: *SkinnedMesh) void {
        self.mesh.deinit();
        if(self.joint_transforms) |transforms| {
            transforms.deinit();
        }
    }

    /// Draw this mesh
    pub fn draw(self: *SkinnedMesh, proj_view_matrix: math.Mat4, model_matrix: math.Mat4) void {
        self.mesh.material.params.joints = &self.joint_locations;
        graphics.drawWithMaterial(&self.mesh.bindings, &self.mesh.material, proj_view_matrix, model_matrix);
    }

    /// Draw this mesh, using the specified material instead of the set one
    pub fn drawWithMaterial(self: *SkinnedMesh, material: *graphics.Material, proj_view_matrix: math.Mat4, model_matrix: math.Mat4) void {
        self.mesh.material.params.joints = &self.joint_locations;
        graphics.drawWithMaterial(&self.mesh.bindings, material, proj_view_matrix, model_matrix);
    }

    pub fn resetJoints(self: *SkinnedMesh) void {
        for (0..self.joint_locations.len) |i| {
            self.joint_locations[i] = math.Mat4.identity;
        }
    }

    pub fn getAnimationsCount(self: *SkinnedMesh) usize {
        return self.mesh.zmesh_data.?.animations_count;
    }

    pub fn createAnimation(self: *SkinnedMesh, anim_idx: usize, speed: f32, loop: bool) !PlayingAnimation {
        var new_anim: PlayingAnimation = .{ .anim_idx = anim_idx, .speed = speed, .looping = loop };

        if(self.mesh.zmesh_data == null) {
            debug.log("warning: mesh skin data not found!", .{});
            return new_anim;
        }

        if (anim_idx >= self.mesh.zmesh_data.?.animations_count) {
            debug.log("warning: animation {} not found!", .{anim_idx});
            new_anim.playing = false;
            return new_anim;
        }

        new_anim.joint_transforms = std.ArrayList(AnimationTransform).init(mem.getAllocator());
        new_anim.joint_calced_matrices = std.ArrayList(math.Mat4).init(mem.getAllocator());

        // assume 64 joints for now!
        for(0..max_joints) |_| {
            try new_anim.joint_transforms.?.append(.{});
            try new_anim.joint_calced_matrices.?.append(math.Mat4.identity);
        }

        // save the duration
        const animation = self.mesh.zmesh_data.?.animations.?[anim_idx];
        new_anim.duration = zmesh.io.computeAnimationDuration(&animation);

        return new_anim;
    }

    pub fn createAnimationByName(self: *SkinnedMesh, anim_name: []const u8, speed: f32, loop: bool) !PlayingAnimation {
        // convert to a sentinel terminated pointer
        const anim_name_z = @as([*:0]u8, @constCast(@ptrCast(anim_name)));

        // Go find the animation whose name matches
        for (0..self.mesh.zmesh_data.?.animations_count) |i| {
            if (self.mesh.zmesh_data.?.animations.?[i].name) |name| {
                const result = std.mem.orderZ(u8, name, anim_name_z);
                if (result == .eq) {
                    return self.createAnimation(i, speed, loop);
                }
            }
        }

        debug.log("Could not find skined mesh animation to play: '{s}'", .{anim_name});
        return self.createAnimation(0, speed, loop);
    }

    pub fn updateAnimation(self: *SkinnedMesh, playing_animation: *PlayingAnimation, delta_time: f32) void {
        if (self.mesh.zmesh_data.?.skins == null or self.mesh.zmesh_data.?.animations == null)
            return;

        // todo: blend multiple animations
        if(playing_animation.joint_transforms == null)
            return;

        if (!playing_animation.playing)
            return;


        playing_animation.time += delta_time * playing_animation.speed;

        if(playing_animation.lerp_timer < playing_animation.lerp_time) {
            playing_animation.lerp_timer += delta_time * playing_animation.speed;
        } else if(playing_animation.lerp_end_amount == 0.0) {
            // if we were lerping out, just stop the animation when done
            playing_animation.playing = false;
            return;
        }


        const animation = self.mesh.zmesh_data.?.animations.?[playing_animation.anim_idx];
        const animation_duration = playing_animation.duration;

        // loop if we need to!
        var t = playing_animation.time;
        if (playing_animation.looping) {
            t = @mod(t, animation_duration);
        }

        const nodes = self.mesh.zmesh_data.?.skins.?[0].joints;
        const nodes_count = self.mesh.zmesh_data.?.skins.?[0].joints_count;

        var local_transforms = playing_animation.joint_transforms.?.items;
        if(local_transforms.len == 0)
            return;

        for (0..nodes_count) |i| {
            const node = nodes[i];
            local_transforms[i] = .{
                .translation = math.Vec3.fromArray(node.translation),
                .scale = math.Vec3.fromArray(node.scale),
                .rotation = math.Quaternion.new(node.rotation[0], node.rotation[1], node.rotation[2], node.rotation[3]),
            };
        }

        for (0..animation.channels_count) |i| {
            const channel = animation.channels[i];
            const sampler = animation.samplers[i];

            var node_idx: usize = 0;
            var found_node = false;
            for (0..nodes_count) |ni| {
                if (nodes[ni] == channel.target_node.?) {
                    node_idx = ni;
                    found_node = true;
                    break;
                }
            }

            if (!found_node)
                continue;

            const lerp_alpha = if(playing_animation.lerp_time <= 0.0) 1.0 else playing_animation.lerp_timer / playing_animation.lerp_time;
            const anim_lerp_amt = interpolation.Lerp.applyIn(playing_animation.lerp_start_amount, playing_animation.lerp_end_amount, @min(lerp_alpha, 1.0));
            const alpha: f32 = playing_animation.blend_alpha * anim_lerp_amt;

            switch (channel.target_path) {
                .translation => {
                    const sampled_translation = self.sampleAnimation(math.Vec3, sampler, t);
                    if(alpha == 1.0) {
                        local_transforms[node_idx].translation = sampled_translation;
                    } else {
                        local_transforms[node_idx].translation = math.Vec3.lerp(local_transforms[node_idx].translation, sampled_translation, alpha);
                    }
                },
                .scale => {
                    const sampled_scale = self.sampleAnimation(math.Vec3, sampler, t);
                    if(alpha == 1.0) {
                        local_transforms[node_idx].scale = sampled_scale;
                    } else {
                        local_transforms[node_idx].scale = math.Vec3.lerp(local_transforms[node_idx].scale, sampled_scale, alpha);
                    }
                },
                .rotation => {
                    const sampled_quaternion = self.sampleAnimation(math.Quaternion, sampler, t);
                    if(alpha == 1.0) {
                        local_transforms[node_idx].rotation = sampled_quaternion;
                    } else {
                        local_transforms[node_idx].rotation = math.Quaternion.slerp(local_transforms[node_idx].rotation, sampled_quaternion, alpha);
                    }
                },
                else => {
                    // unhandled!
                },
            }
        }
    }

    // Reset back to the base pose
    pub fn resetAnimation(self: *SkinnedMesh) void {
        if (self.mesh.zmesh_data.?.skins == null or self.mesh.zmesh_data.?.animations == null)
            return;

        if(self.joint_transforms == null)
            return;

        const nodes = self.mesh.zmesh_data.?.skins.?[0].joints;
        const nodes_count = self.mesh.zmesh_data.?.skins.?[0].joints_count;

        var local_transforms = self.joint_transforms.?.items;
        if(local_transforms.len == 0)
            return;

        // set initial bone positions
        for (0..nodes_count) |i| {
            const node = nodes[i];
            local_transforms[i] = .{
                .translation = math.Vec3.fromArray(node.translation),
                .scale = math.Vec3.fromArray(node.scale),
                .rotation = math.Quaternion.new(node.rotation[0], node.rotation[1], node.rotation[2], node.rotation[3]),
            };
        }

        self.applySkeletonTransforms();
    }

    // Turns the local joint transforms into the final world space transforms
    pub fn applySkeletonTransforms(self: *SkinnedMesh) void {
        var local_transforms = self.joint_transforms.?.items;
        const nodes = self.mesh.zmesh_data.?.skins.?[0].joints;
        const nodes_count = self.mesh.zmesh_data.?.skins.?[0].joints_count;

        // apply bone heirarchy
        for (0..nodes_count) |i| {
            var node = nodes[i];
            self.joint_transform_mats[i] = local_transforms[i].toMat4();

            while (node.parent) |parent| : (node = parent) {
                var parent_idx: usize = 0;
                var found_node = false;

                for (0..nodes_count) |ni| {
                    if (nodes[ni] == parent) {
                        parent_idx = ni;
                        found_node = true;
                        break;
                    }
                }

                if (!found_node)
                    continue;

                const parent_transform = local_transforms[parent_idx].toMat4();
                self.joint_transform_mats[i] = parent_transform.mul(self.joint_transform_mats[i]);
            }
        }

        // apply the inverse bind matrices
        const inverse_bind_mat_data = zmesh.io.getAnimationSamplerData(self.mesh.zmesh_data.?.skins.?[0].inverse_bind_matrices.?);
        for (0..nodes_count) |i| {
            const inverse_mat = access(math.Mat4, inverse_bind_mat_data, i);
            self.joint_locations[i] = self.joint_transform_mats[i].mul(inverse_mat);
        }
    }

    pub fn applyAnimation(self: *SkinnedMesh, playing_animation: *const PlayingAnimation, blend_alpha: f32) void {
        if(playing_animation.joint_transforms == null)
            return;

        const nodes_count = self.mesh.zmesh_data.?.skins.?[0].joints_count;
        const alpha = blend_alpha;

        var local_transforms = self.joint_transforms.?.items;
        const anim_transforms = playing_animation.joint_transforms.?.items;

        if(blend_alpha == 1.0) {
            // easy case, just grab the transforms without blending
            for(0..nodes_count) |i| {
                local_transforms[i] = playing_animation.joint_transforms.?.items[i];
            }
        } else {
            for(0..nodes_count) |i| {
                local_transforms[i].translation = math.Vec3.lerp(local_transforms[i].translation, anim_transforms[i].translation, alpha);
                local_transforms[i].scale = math.Vec3.lerp(local_transforms[i].scale, anim_transforms[i].scale, alpha);
                local_transforms[i].rotation = math.Quaternion.slerp(local_transforms[i].rotation, anim_transforms[i].rotation, alpha);
            }
        }

        self.applySkeletonTransforms();
    }

    pub fn sampleAnimation(self: *SkinnedMesh, comptime T: type, sampler: zmesh.io.zcgltf.AnimationSampler, t: f32) T {
        _ = self;

        const samples = zmesh.io.getAnimationSamplerData(sampler.input);
        const data = zmesh.io.getAnimationSamplerData(sampler.output);

        switch (sampler.interpolation) {
            .step => {
                return access(T, data, stepInterpolation(samples, t));
            },
            .linear => {
                const r = linearInterpolation(samples, t);
                const v0 = access(T, data, r.prev_i);
                const v1 = access(T, data, r.next_i);

                if (T == math.Quaternion) {
                    return T.slerp(v0, v1, r.alpha);
                }

                return T.lerp(v0, v1, r.alpha);
            },
            .cubic_spline => {
                @panic("Cubicspline in animations not implemented!");
            },
        }
    }

    /// Returns the index of the last sample less than `t`.
    fn stepInterpolation(samples: []const f32, t: f32) usize {
        std.debug.assert(samples.len > 0);
        const S = struct {
            fn lessThan(_: void, lhs: f32, rhs: f32) bool {
                return lhs < rhs;
            }
        };
        const i = std.sort.lowerBound(f32, t, samples, {}, S.lessThan);
        return if (i > 0) i - 1 else 0;
    }

    /// Returns the indices of the samples around `t` and `alpha` to interpolate between those.
    fn linearInterpolation(samples: []const f32, t: f32) struct {
        prev_i: usize,
        next_i: usize,
        alpha: f32,
    } {
        const i = stepInterpolation(samples, t);
        if (i == samples.len - 1) return .{ .prev_i = i, .next_i = i, .alpha = 0 };

        const d = samples[i + 1] - samples[i];
        std.debug.assert(d > 0);
        const alpha = std.math.clamp((t - samples[i]) / d, 0, 1);

        return .{ .prev_i = i, .next_i = i + 1, .alpha = alpha };
    }

    pub fn access(comptime T: type, data: []const f32, i: usize) T {
        return switch (T) {
            Vec3 => Vec3.new(data[3 * i + 0], data[3 * i + 1], data[3 * i + 2]),
            math.Quaternion => math.Quaternion.new(data[4 * i + 0], data[4 * i + 1], data[4 * i + 2], data[4 * i + 3]),
            math.Mat4 => math.Mat4.fromSlice(data[16 * i ..][0..16]),
            else => @compileError("unexpected type"),
        };
    }
};

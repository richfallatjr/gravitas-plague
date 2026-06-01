# ============================================================
# Gravitas Plague - Explicit Head / Body / Tail USDZ Stitcher
# Version: 1.7
#
# Fixes:
#   - You can select the top parent/group/empty.
#   - The tool finds the nested Armature automatically.
#   - You no longer need to select the Armature directly.
#   - Creates a clean output action.
#   - Adds explicit head and tail keyframes.
#   - Forces scene/action/export frame range.
#
# UI:
#   3D Viewport -> N-panel -> Gravitas -> Explicit Stitcher v1.7
# ============================================================

bl_info = {
    "name": "Gravitas Explicit Stitcher v1.7",
    "author": "OpenAI / Gravitas Plague Pipeline",
    "version": (1, 7, 0),
    "blender": (4, 0, 0),
    "location": "3D Viewport > Sidebar > Gravitas > Explicit Stitcher v1.7",
    "description": "Builds a clean head/body/tail stitched USDZ action while allowing parent/group selection.",
    "category": "Animation",
}

import bpy
import os
import math
import traceback

from mathutils import Matrix, Vector

from bpy.props import (
    BoolProperty,
    EnumProperty,
    FloatProperty,
    IntProperty,
    PointerProperty,
    StringProperty,
)

from bpy.types import Operator, Panel, PropertyGroup


LOG_TEXT_BLOCK_NAME = "Gravitas_Explicit_Stitcher_Log"
TEMP_COLLECTION_NAME = "__GRAVITAS_EXPLICIT_STITCHER_TEMP__"
TEMPLATE_COLLECTION_NAME = "__GRAVITAS_MANUAL_TEMPLATE__"


# ============================================================
# Remove older Gravitas panels so only v1.7 remains visible
# ============================================================

def _safe_unregister_class_by_name(class_name):
    cls = getattr(bpy.types, class_name, None)
    if cls is not None:
        try:
            bpy.utils.unregister_class(cls)
        except Exception:
            pass


def _cleanup_old_gravitas_tools():
    old_scene_props = [
        "gravitas_pose_handoff",
        "gravitas_three_way_handoff",
        "gravitas_clip_handoff",
        "gravitas_explicit_stitcher",
        "gravitas_explicit_stitcher_v17",
    ]

    for prop in old_scene_props:
        if hasattr(bpy.types.Scene, prop):
            try:
                delattr(bpy.types.Scene, prop)
            except Exception:
                pass

    old_classes = [
        "GRAVITAS_PT_pose_handoff_panel",
        "GRAVITAS_OT_pose_handoff_stitch",
        "GravitasPoseHandoffSettings",

        "GRAVITAS_PT_three_way_handoff_panel",
        "GRAVITAS_OT_three_way_handoff_stitch",
        "GravitasThreeWayHandoffSettings",

        "GRAVITAS_PT_clip_handoff_panel",
        "GRAVITAS_OT_clip_handoff",
        "GravitasClipHandoffSettings",

        "GRAVITAS_PT_explicit_stitcher_panel",
        "GRAVITAS_OT_explicit_stitcher_build",
        "GravitasExplicitStitcherSettings",

        "GRAVITAS_PT_explicit_stitcher_panel_v17",
        "GRAVITAS_OT_explicit_stitcher_build_v17",
        "GRAVITAS_OT_explicit_stitcher_capture_body_range_v17",
        "GravitasExplicitStitcherSettingsV17",
    ]

    for class_name in old_classes:
        _safe_unregister_class_by_name(class_name)


# ============================================================
# Basic helpers
# ============================================================

def _force_object_mode():
    try:
        bpy.ops.object.mode_set(mode="OBJECT")
    except Exception:
        pass


def _safe_report(operator, level, message):
    try:
        operator.report(level, message)
    except Exception:
        print(message)


def _write_log(lines):
    text = bpy.data.texts.get(LOG_TEXT_BLOCK_NAME)

    if text is None:
        text = bpy.data.texts.new(LOG_TEXT_BLOCK_NAME)

    text.clear()
    text.write("\n".join(lines))


def _stash_selection(context):
    active_name = (
        context.view_layer.objects.active.name
        if context.view_layer.objects.active is not None
        else None
    )

    selected_names = [obj.name for obj in context.selected_objects]
    return active_name, selected_names


def _restore_selection(context, active_name, selected_names):
    _force_object_mode()

    try:
        bpy.ops.object.select_all(action="DESELECT")
    except Exception:
        pass

    for name in selected_names:
        obj = bpy.data.objects.get(name)
        if obj is not None:
            obj.select_set(True)

    active_obj = bpy.data.objects.get(active_name) if active_name else None

    if active_obj is not None:
        context.view_layer.objects.active = active_obj


def _call_operator_with_supported_kwargs(operator_proxy, **kwargs):
    try:
        rna_type = operator_proxy.get_rna_type()

        supported = {
            prop.identifier
            for prop in rna_type.properties
            if prop.identifier != "rna_type"
        }

        filtered = {
            key: value
            for key, value in kwargs.items()
            if key in supported
        }

        return operator_proxy(**filtered)

    except Exception as original_error:
        if "filepath" in kwargs:
            try:
                return operator_proxy(filepath=kwargs["filepath"])
            except Exception:
                raise original_error

        raise original_error


def _iter_action_fcurves(action):
    """
    Works with both legacy Action.fcurves and Blender 4.4+/5 slotted actions:
    action.layers -> strips -> channelbags -> fcurves.
    """
    if action is None:
        return

    seen = set()

    legacy_fcurves = getattr(action, "fcurves", None)
    if legacy_fcurves is not None:
        try:
            for fcurve in legacy_fcurves:
                pointer = fcurve.as_pointer()
                if pointer not in seen:
                    seen.add(pointer)
                    yield fcurve
        except Exception:
            pass

    layers = getattr(action, "layers", None)
    if layers is not None:
        try:
            for layer in layers:
                strips = getattr(layer, "strips", None)
                if strips is None:
                    continue

                for strip in strips:
                    channelbags = getattr(strip, "channelbags", None)
                    if channelbags is not None:
                        try:
                            for channelbag in channelbags:
                                fcurves = getattr(channelbag, "fcurves", None)
                                if fcurves is None:
                                    continue

                                for fcurve in fcurves:
                                    pointer = fcurve.as_pointer()
                                    if pointer not in seen:
                                        seen.add(pointer)
                                        yield fcurve
                        except Exception:
                            pass

                    channelbag_fn = getattr(strip, "channelbag", None)
                    slots = getattr(action, "slots", None)

                    if callable(channelbag_fn) and slots is not None:
                        try:
                            for slot in slots:
                                channelbag = channelbag_fn(slot)
                                if channelbag is None:
                                    continue

                                fcurves = getattr(channelbag, "fcurves", None)
                                if fcurves is None:
                                    continue

                                for fcurve in fcurves:
                                    pointer = fcurve.as_pointer()
                                    if pointer not in seen:
                                        seen.add(pointer)
                                        yield fcurve
                        except Exception:
                            pass
        except Exception:
            pass


def _iter_action_fcurves_safe(action):
    yield from _iter_action_fcurves(action)


def _delete_action_keys_outside_range(action, start_frame, end_frame, log):
    start_frame = float(start_frame)
    end_frame = float(end_frame)
    deleted = 0

    for fcurve in _iter_action_fcurves_safe(action):
        for key in list(reversed(fcurve.keyframe_points)):
            frame = key.co.x

            if frame < start_frame or frame > end_frame:
                fcurve.keyframe_points.remove(key)
                deleted += 1

        fcurve.update()

    log.append(
        f"Deleted {deleted} keyframes outside range {int(start_frame)} -> {int(end_frame)}."
    )
    return deleted


def _delete_action_keys_after_frame(action, frame, log):
    frame = float(frame)
    deleted = 0

    for fcurve in _iter_action_fcurves_safe(action):
        for key in list(reversed(fcurve.keyframe_points)):
            if key.co.x > frame:
                fcurve.keyframe_points.remove(key)
                deleted += 1

        fcurve.update()

    log.append(f"Deleted {deleted} keyframes after frame {int(frame)}.")
    return deleted


def _shift_action_keys(action, delta, log):
    if abs(delta) < 0.0001:
        log.append("No action key shift needed.")
        return 0

    shifted = 0

    for fcurve in _iter_action_fcurves_safe(action):
        for key in fcurve.keyframe_points:
            key.co.x += delta
            key.handle_left.x += delta
            key.handle_right.x += delta
            shifted += 1

        fcurve.update()

    log.append(f"Shifted {shifted} keys by {delta} frames.")
    return shifted


def _count_keys_after_frame(action, frame):
    frame = float(frame)
    count = 0

    for fcurve in _iter_action_fcurves_safe(action):
        for key in fcurve.keyframe_points:
            if key.co.x > frame:
                count += 1

    return count


def _action_fcurve_count(action):
    return sum(1 for _ in _iter_action_fcurves(action))


def _action_has_keys(action):
    for fcurve in _iter_action_fcurves(action):
        if len(fcurve.keyframe_points) > 0:
            return True

    return False


def _detected_action_bounds(action):
    if action is None:
        return None

    min_frame = None
    max_frame = None

    for fcurve in _iter_action_fcurves(action):
        for key in fcurve.keyframe_points:
            frame = key.co.x

            if min_frame is None or frame < min_frame:
                min_frame = frame

            if max_frame is None or frame > max_frame:
                max_frame = frame

    if min_frame is not None and max_frame is not None:
        return int(math.floor(min_frame)), int(math.ceil(max_frame))

    frame_range = getattr(action, "frame_range", None)
    if frame_range is not None:
        try:
            return int(math.floor(frame_range[0])), int(math.ceil(frame_range[1]))
        except Exception:
            pass

    return None


def _action_frame_bounds(action):
    bounds = _detected_action_bounds(action)
    if bounds is not None:
        return bounds

    return 1, 1


def _ensure_action(armature):
    if armature is None:
        return None

    if armature.animation_data is None:
        return None

    return armature.animation_data.action


def _iter_descendants(obj):
    for child in obj.children:
        yield child
        yield from _iter_descendants(child)


def _iter_parent_chain(obj):
    parent = obj.parent

    while parent is not None:
        yield parent
        parent = parent.parent


def _collect_selected_hierarchy_objects(context):
    objects = set()

    if context.view_layer.objects.active is not None:
        objects.add(context.view_layer.objects.active)

    for obj in context.selected_objects:
        objects.add(obj)

    for obj in list(objects):
        for child in _iter_descendants(obj):
            objects.add(child)

    for obj in list(objects):
        for parent in _iter_parent_chain(obj):
            objects.add(parent)

            for child in _iter_descendants(parent):
                objects.add(child)

    # Meshes often point to their armature through an Armature modifier.
    for obj in list(objects):
        if obj.type == "MESH":
            for modifier in obj.modifiers:
                if modifier.type == "ARMATURE" and modifier.object is not None:
                    objects.add(modifier.object)

    return list(objects)


def _armature_score(armature, active):
    score = 0

    if active is armature:
        score += 1000

    action = _ensure_action(armature)

    if action is not None:
        score += 100

        if _action_has_keys(action):
            score += 100

    if ".001" in armature.name or ".002" in armature.name:
        score += 10

    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue

        if obj.parent is armature:
            score += 5
            break

        for modifier in obj.modifiers:
            if modifier.type == "ARMATURE" and modifier.object is armature:
                score += 5
                break

    return score


def _find_armature_from_selection_or_parent(context):
    """
    Critical v1.7 behavior:
    User may select:
      - top imported group/empty
      - mesh
      - parent transform
      - armature itself

    The tool finds the nested animated Armature automatically.
    """
    active = context.view_layer.objects.active
    objects = _collect_selected_hierarchy_objects(context)

    armatures = [obj for obj in objects if obj.type == "ARMATURE"]

    if not armatures:
        return None

    armatures.sort(
        key=lambda armature: _armature_score(armature, active),
        reverse=True,
    )
    return armatures[0]


def _find_export_root_for_armature(armature):
    root = armature

    while root.parent is not None:
        root = root.parent

    return root


def _pose_bones_parent_first(armature):
    def depth(pose_bone):
        count = 0
        parent = pose_bone.parent

        while parent is not None:
            count += 1
            parent = parent.parent

        return count

    return sorted(list(armature.pose.bones), key=depth)


def _select_armature_and_descendants(context, armature):
    _force_object_mode()

    bpy.ops.object.select_all(action="DESELECT")

    export_root = _find_export_root_for_armature(armature)

    objects_to_select = {export_root}

    for child in _iter_descendants(export_root):
        objects_to_select.add(child)

    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue

        for modifier in obj.modifiers:
            if modifier.type == "ARMATURE" and modifier.object is armature:
                objects_to_select.add(obj)

                for child in _iter_descendants(obj):
                    objects_to_select.add(child)

    for obj in objects_to_select:
        if obj.name in bpy.data.objects:
            obj.select_set(True)

    context.view_layer.objects.active = armature

    print("[Gravitas] Export root:", export_root.name)
    print("[Gravitas] Export selected objects:")
    for obj in sorted(objects_to_select, key=lambda item: item.name):
        print("  -", obj.name, obj.type)


# ============================================================
# Bone filters / channel rules
# ============================================================

def _split_tokens(raw):
    return [token.strip().lower() for token in raw.split(",") if token.strip()]


def _matches_any_token(name, tokens):
    lowered = name.lower()
    return any(token in lowered for token in tokens)


def _is_root_like_bone_name(bone_name, settings):
    return _matches_any_token(
        bone_name,
        _split_tokens(settings.root_bone_tokens),
    )


def _include_bone(bone_name, settings):
    if not settings.include_jaw:
        if _matches_any_token(bone_name, _split_tokens(settings.jaw_bone_tokens)):
            return False

    if not settings.include_fingers:
        if _matches_any_token(bone_name, _split_tokens(settings.finger_bone_tokens)):
            return False

    return True


def _copy_location_for_bone(bone_name, settings):
    if _is_root_like_bone_name(bone_name, settings):
        return settings.copy_root_location

    return settings.copy_bone_locations


def _copy_rotation_for_bone(bone_name, settings):
    if _is_root_like_bone_name(bone_name, settings):
        return settings.copy_root_rotation

    return settings.copy_bone_rotations


def _copy_scale_for_bone(_bone_name, settings):
    return settings.copy_bone_scales


# ============================================================
# Rotation / key helpers
# ============================================================

def _set_pose_bone_rotation_from_quaternion(pose_bone, quat):
    quat = quat.copy()
    quat.normalize()

    if pose_bone.rotation_mode == "QUATERNION":
        pose_bone.rotation_quaternion = quat

    elif pose_bone.rotation_mode == "AXIS_ANGLE":
        axis, angle = quat.to_axis_angle()
        pose_bone.rotation_axis_angle[0] = angle
        pose_bone.rotation_axis_angle[1] = axis.x
        pose_bone.rotation_axis_angle[2] = axis.y
        pose_bone.rotation_axis_angle[3] = axis.z

    else:
        pose_bone.rotation_euler = quat.to_euler(pose_bone.rotation_mode)


def _key_pose_bone_rotation(pose_bone, frame):
    if pose_bone.rotation_mode == "QUATERNION":
        pose_bone.keyframe_insert(data_path="rotation_quaternion", frame=frame)

    elif pose_bone.rotation_mode == "AXIS_ANGLE":
        pose_bone.keyframe_insert(data_path="rotation_axis_angle", frame=frame)

    else:
        pose_bone.keyframe_insert(data_path="rotation_euler", frame=frame)


def _key_enabled_channels(pose_bone, bone_name, settings, frame):
    if _copy_location_for_bone(bone_name, settings):
        pose_bone.keyframe_insert(data_path="location", frame=frame)

    if _copy_rotation_for_bone(bone_name, settings):
        _key_pose_bone_rotation(pose_bone, frame)

    if _copy_scale_for_bone(bone_name, settings):
        pose_bone.keyframe_insert(data_path="scale", frame=frame)


def _rotation_matrix_from_xyz_degrees(x_degrees, y_degrees, z_degrees):
    rx = Matrix.Rotation(math.radians(x_degrees), 4, "X")
    ry = Matrix.Rotation(math.radians(y_degrees), 4, "Y")
    rz = Matrix.Rotation(math.radians(z_degrees), 4, "Z")

    # Blender vertical yaw is Z.
    return rz @ ry @ rx


def _count_keys_at_frame(action, frame):
    if action is None:
        return 0

    frame = float(frame)
    count = 0

    for fcurve in _iter_action_fcurves(action):
        for key in fcurve.keyframe_points:
            if abs(key.co.x - frame) < 0.001:
                count += 1

    return count


def _set_interpolation_for_all_keys(action, interpolation):
    if action is None:
        return 0

    changed = 0

    for fcurve in _iter_action_fcurves(action):
        for key in fcurve.keyframe_points:
            key.interpolation = interpolation
            changed += 1

    return changed


# ============================================================
# Pose sampling
# ============================================================

def _sample_local_pose(armature, frame, settings, label, log=None):
    if log is None:
        log = []

    bpy.context.scene.frame_set(int(frame))
    bpy.context.view_layer.update()

    samples = {}

    for pose_bone in armature.pose.bones:
        bone_name = pose_bone.name

        if not _include_bone(bone_name, settings):
            continue

        matrix_basis = pose_bone.matrix_basis.copy()
        location, rotation, scale = matrix_basis.decompose()

        samples[bone_name] = {
            "space": "LOCAL",
            "location": location.copy(),
            "rotation": rotation.copy(),
            "scale": scale.copy(),
            "target_world_matrix": None,
        }

    log.append(f"Sampled {len(samples)} local bones from {label} at frame {frame}.")
    return samples


def _source_rotation_enabled(prefix, settings):
    if prefix == "HEAD":
        return (
            settings.head_enable_source_rotation
            and (
                abs(settings.head_rotation_x_degrees) > 0.0001
                or abs(settings.head_rotation_y_degrees) > 0.0001
                or abs(settings.head_rotation_z_degrees) > 0.0001
            )
        )

    return (
        settings.tail_enable_source_rotation
        and (
            abs(settings.tail_rotation_x_degrees) > 0.0001
            or abs(settings.tail_rotation_y_degrees) > 0.0001
            or abs(settings.tail_rotation_z_degrees) > 0.0001
        )
    )


def _source_rotation_values(prefix, settings):
    if prefix == "HEAD":
        return (
            settings.head_rotation_x_degrees,
            settings.head_rotation_y_degrees,
            settings.head_rotation_z_degrees,
            settings.head_rotation_pivot,
        )

    return (
        settings.tail_rotation_x_degrees,
        settings.tail_rotation_y_degrees,
        settings.tail_rotation_z_degrees,
        settings.tail_rotation_pivot,
    )


def _source_rotation_pivot(prefix, current_armature, source_armature, settings):
    _, _, _, pivot_mode = _source_rotation_values(prefix, settings)

    if pivot_mode == "CURRENT_ARMATURE_ORIGIN":
        return current_armature.matrix_world.translation.copy()

    if pivot_mode == "SOURCE_ARMATURE_ORIGIN":
        return source_armature.matrix_world.translation.copy()

    return Vector((0, 0, 0))


def _source_rotation_matrix(prefix, current_armature, source_armature, settings):
    if not _source_rotation_enabled(prefix, settings):
        return Matrix.Identity(4)

    x, y, z, _ = _source_rotation_values(prefix, settings)
    pivot = _source_rotation_pivot(prefix, current_armature, source_armature, settings)
    rot = _rotation_matrix_from_xyz_degrees(x, y, z)

    return Matrix.Translation(pivot) @ rot @ Matrix.Translation(-pivot)


def _sample_source_pose(prefix, current_armature, source_armature, source_frame, settings, label, log):
    bpy.context.scene.frame_set(int(source_frame))
    bpy.context.view_layer.update()

    rotate_source = _source_rotation_enabled(prefix, settings)
    source_rot_matrix = _source_rotation_matrix(prefix, current_armature, source_armature, settings)

    if rotate_source:
        x_degrees, y_degrees, z_degrees, pivot_mode = _source_rotation_values(prefix, settings)
        log.append(f"{prefix} ROTATION ROUTE: GIT_V1_7_FULL_SOURCE_WORLD_MATRIX_SOLVE")
        log.append(
            f"{prefix} rotation values: "
            f"x={x_degrees:g}, y={y_degrees:g}, z={z_degrees:g}, "
            f"pivot={pivot_mode}"
        )

    samples = {}

    for pose_bone in source_armature.pose.bones:
        bone_name = pose_bone.name

        if not _include_bone(bone_name, settings):
            continue

        if rotate_source:
            target_world_matrix = (
                source_rot_matrix
                @ source_armature.matrix_world
                @ pose_bone.matrix
            )

            location, rotation, scale = target_world_matrix.decompose()

            samples[bone_name] = {
                "space": "WORLD",
                "location": location.copy(),
                "rotation": rotation.copy(),
                "scale": scale.copy(),
                "target_world_matrix": target_world_matrix.copy(),
            }

        else:
            matrix_basis = pose_bone.matrix_basis.copy()
            location, rotation, scale = matrix_basis.decompose()

            samples[bone_name] = {
                "space": "LOCAL",
                "location": location.copy(),
                "rotation": rotation.copy(),
                "scale": scale.copy(),
                "target_world_matrix": None,
            }

    log.append(f"Sampled {len(samples)} bones from {label} at frame {source_frame}.")
    return samples


def _resolved_boundary_solve_mode(prefix, settings):
    return "FULL_POSE_MATRIX"


def _manual_template_boundary_prefix(settings):
    head_is_manual = (
        settings.enable_head_transition
        and _source_rotation_enabled("HEAD", settings)
    )
    tail_is_manual = (
        settings.enable_tail_transition
        and _source_rotation_enabled("TAIL", settings)
    )

    if (head_is_manual or tail_is_manual) and not settings.manual_template_mode_when_rotated:
        raise RuntimeError(
            "Rotated source transitions require Manual Template Mode When Rotated."
        )

    if head_is_manual and tail_is_manual:
        raise RuntimeError(
            "Manual template mode supports one rotated boundary at a time. "
            "Disable either Head or Tail rotation."
        )

    if head_is_manual:
        return "HEAD"

    if tail_is_manual:
        return "TAIL"

    return None


def _compute_enabled_transition_range(settings, log):
    body_start_in = int(settings.current_body_start)
    body_end_in = int(settings.current_body_end)

    if body_end_in < body_start_in:
        raise RuntimeError(
            f"Bad body range: {body_start_in} -> {body_end_in}"
        )

    output_start = int(settings.output_start_frame)

    head_enabled = bool(settings.enable_head_transition)
    tail_enabled = bool(settings.enable_tail_transition)

    head_frames = int(settings.head_transition_frames) if head_enabled else 0
    tail_frames = int(settings.tail_transition_frames) if tail_enabled else 0
    tail_hold = int(settings.tail_hold_frames) if tail_enabled else 0

    body_len = body_end_in - body_start_in + 1

    body_start_out = output_start + head_frames
    body_end_out = body_start_out + body_len - 1

    if tail_enabled:
        tail_target_out = body_end_out + tail_frames
        output_end = tail_target_out + tail_hold
    else:
        tail_target_out = None
        output_end = body_end_out

    expected_length = body_len + head_frames + tail_frames + tail_hold
    actual_length = output_end - output_start + 1

    if actual_length != expected_length:
        raise RuntimeError(
            f"Frame math failed. expected={expected_length}, actual={actual_length}, "
            f"body_in={body_start_in}->{body_end_in}, "
            f"head_enabled={head_enabled}, head_frames={head_frames}, "
            f"tail_enabled={tail_enabled}, tail_frames={tail_frames}, tail_hold={tail_hold}, "
            f"body_out={body_start_out}->{body_end_out}, "
            f"tail_target_out={tail_target_out}, "
            f"output={output_start}->{output_end}"
        )

    if not head_enabled and body_start_out != output_start:
        raise RuntimeError(
            f"Head disabled but body_start_out moved. "
            f"body_start_out={body_start_out}, output_start={output_start}"
        )

    if head_enabled and body_start_out != output_start + int(settings.head_transition_frames):
        raise RuntimeError(
            f"Head frame bug. body_start_out={body_start_out}, "
            f"output_start={output_start}, head_transition_frames={settings.head_transition_frames}"
        )

    if tail_enabled and tail_target_out != body_end_out + int(settings.tail_transition_frames):
        raise RuntimeError(
            f"Tail frame bug. tail_target_out={tail_target_out}, "
            f"body_end_out={body_end_out}, "
            f"tail_transition_frames={settings.tail_transition_frames}"
        )

    log.append("ENABLED TRANSITION FRAME MATH")
    log.append(f"  body_in:          {body_start_in} -> {body_end_in}")
    log.append(f"  body_len:         {body_len}")
    log.append(f"  output_start:     {output_start}")
    log.append(f"  head_enabled:     {head_enabled}")
    log.append(f"  head_frames:      {head_frames}")
    log.append(f"  body_out:         {body_start_out} -> {body_end_out}")
    log.append(f"  tail_enabled:     {tail_enabled}")
    log.append(f"  tail_frames:      {tail_frames}")
    log.append(f"  tail_hold:        {tail_hold}")
    log.append(f"  tail_target_out:  {tail_target_out}")
    log.append(f"  output_end:       {output_end}")
    log.append(f"  expected_length:  {expected_length}")
    log.append(f"  actual_length:    {actual_length}")

    return {
        "body_start_in": body_start_in,
        "body_end_in": body_end_in,
        "body_len": body_len,

        "output_start": output_start,

        "head_enabled": head_enabled,
        "head_frames": head_frames,

        "body_start_out": body_start_out,
        "body_end_out": body_end_out,

        "tail_enabled": tail_enabled,
        "tail_frames": tail_frames,
        "tail_hold": tail_hold,
        "tail_target_out": tail_target_out,

        "output_end": output_end,
        "expected_length": expected_length,
    }


def _find_pose_bone_by_candidates(armature, candidates_string):
    candidates = [
        name.strip()
        for name in candidates_string.split(",")
        if name.strip()
    ]

    for name in candidates:
        bone = armature.pose.bones.get(name)
        if bone is not None:
            return bone

    lowered = {
        bone.name.lower(): bone
        for bone in armature.pose.bones
    }

    for name in candidates:
        bone = lowered.get(name.lower())
        if bone is not None:
            return bone

    return None


def _required_landmark_bones(armature, settings, prefix, role):
    landmark_specs = [
        ("head", "head bone", settings.head_bone_candidates),
        ("left_hand", "left hand bone", settings.left_hand_bone_candidates),
        ("right_hand", "right hand bone", settings.right_hand_bone_candidates),
        ("left_foot", "left foot bone", settings.left_foot_bone_candidates),
        ("right_foot", "right foot bone", settings.right_foot_bone_candidates),
    ]

    bones = {}

    for key, label, candidates in landmark_specs:
        bone = _find_pose_bone_by_candidates(armature, candidates)

        if bone is None:
            raise RuntimeError(
                f"{prefix} IK landmark solve failed: {role} {label} not found."
            )

        bones[key] = bone

    return bones


def _sample_source_landmark_targets(
    prefix,
    current_armature,
    source_armature,
    source_frame,
    settings,
    label,
    log,
):
    bpy.context.scene.frame_set(int(source_frame))
    bpy.context.view_layer.update()

    rotate_source = _source_rotation_enabled(prefix, settings)
    source_rot_matrix = _source_rotation_matrix(
        prefix,
        current_armature,
        source_armature,
        settings,
    )

    x_degrees, y_degrees, z_degrees, pivot_mode = _source_rotation_values(prefix, settings)

    log.append(f"{prefix} source rotation: {'ON' if rotate_source else 'OFF'}")
    log.append(f"{prefix} rotation pivot: {pivot_mode}")

    if rotate_source:
        log.append(f"{prefix} ROTATION ROUTE: IK_LANDMARK_TARGETS")
        log.append(
            f"{prefix} rotation values: "
            f"x={x_degrees:g}, y={y_degrees:g}, z={z_degrees:g}, "
            f"pivot={pivot_mode}"
        )

    source_bones = _required_landmark_bones(
        armature=source_armature,
        settings=settings,
        prefix=prefix,
        role="source",
    )

    log.append(f"{prefix} landmark bones:")
    for key in ("head", "left_hand", "right_hand", "left_foot", "right_foot"):
        log.append(f"  {key} = {source_bones[key].name}")

    targets = {}

    for key, source_pose_bone in source_bones.items():
        targets[key] = (
            source_rot_matrix
            @ source_armature.matrix_world
            @ source_pose_bone.matrix
        ).copy()

    log.append(
        f"Sampled {len(targets)} IK landmark targets from {label} at frame {source_frame}."
    )

    return targets


# ============================================================
# Apply pose samples
# ============================================================

def _apply_sample_to_current_bone(current_armature, pose_bone, bone_name, sample, settings):
    old_location = pose_bone.location.copy()
    old_rotation_mode = pose_bone.rotation_mode
    old_rotation_euler = pose_bone.rotation_euler.copy()
    old_rotation_quaternion = pose_bone.rotation_quaternion.copy()
    old_rotation_axis_angle = pose_bone.rotation_axis_angle[:]
    old_scale = pose_bone.scale.copy()

    if sample["space"] == "WORLD":
        target_world_matrix = sample["target_world_matrix"]
        target_armature_space = current_armature.matrix_world.inverted() @ target_world_matrix

        try:
            pose_bone.matrix = target_armature_space
        except Exception:
            loc, rot, scl = target_armature_space.decompose()

            if _copy_location_for_bone(bone_name, settings):
                pose_bone.location = loc

            if _copy_rotation_for_bone(bone_name, settings):
                _set_pose_bone_rotation_from_quaternion(pose_bone, rot)

            if _copy_scale_for_bone(bone_name, settings):
                pose_bone.scale = scl

    else:
        if _copy_location_for_bone(bone_name, settings):
            pose_bone.location = sample["location"]

        if _copy_rotation_for_bone(bone_name, settings):
            _set_pose_bone_rotation_from_quaternion(pose_bone, sample["rotation"])

        if _copy_scale_for_bone(bone_name, settings):
            pose_bone.scale = sample["scale"]

    if not _copy_location_for_bone(bone_name, settings):
        pose_bone.location = old_location

    if not _copy_rotation_for_bone(bone_name, settings):
        pose_bone.rotation_mode = old_rotation_mode

        if pose_bone.rotation_mode == "QUATERNION":
            pose_bone.rotation_quaternion = old_rotation_quaternion

        elif pose_bone.rotation_mode == "AXIS_ANGLE":
            for i in range(4):
                pose_bone.rotation_axis_angle[i] = old_rotation_axis_angle[i]

        else:
            pose_bone.rotation_euler = old_rotation_euler

    if not _copy_scale_for_bone(bone_name, settings):
        pose_bone.scale = old_scale


def _apply_pose_and_key(current_armature, pose_sample, output_frame, settings, label, log):
    scene = bpy.context.scene
    scene.frame_set(int(output_frame))
    bpy.context.view_layer.update()

    matched = 0

    for pose_bone in _pose_bones_parent_first(current_armature):
        bone_name = pose_bone.name

        sample = pose_sample.get(bone_name)

        if sample is None:
            continue

        _apply_sample_to_current_bone(
            current_armature=current_armature,
            pose_bone=pose_bone,
            bone_name=bone_name,
            sample=sample,
            settings=settings,
        )

        matched += 1

        if settings.update_after_each_bone_matrix_set:
            bpy.context.view_layer.update()

    bpy.context.view_layer.update()

    keyed = 0

    for pose_bone in current_armature.pose.bones:
        bone_name = pose_bone.name

        if bone_name not in pose_sample:
            continue

        _key_enabled_channels(pose_bone, bone_name, settings, int(output_frame))
        keyed += 1

    log.append(f"Applied/keyed {label} at output frame {output_frame}. matched_bones={matched}, keyed_bones={keyed}")


def _create_world_empty(name, matrix_world):
    empty = bpy.data.objects.new(name, None)
    empty.empty_display_type = "SPHERE"
    empty.empty_display_size = 0.06
    bpy.context.scene.collection.objects.link(empty)
    empty.matrix_world = matrix_world
    return empty


def _add_ik_constraint(pose_bone, target_empty, chain_count):
    constraint = pose_bone.constraints.new(type="IK")
    constraint.name = "GRAVITAS_TEMP_IK"
    constraint.target = target_empty
    constraint.chain_count = int(chain_count)
    return constraint


def _remove_temp_ik_constraints(constraints):
    for pose_bone, constraint in constraints:
        try:
            pose_bone.constraints.remove(constraint)
        except Exception:
            pass


def _remove_temp_empties(empties):
    for empty in empties:
        if empty is not None and empty.name in bpy.data.objects:
            try:
                bpy.data.objects.remove(empty, do_unlink=True)
            except Exception:
                pass


def _apply_head_target(current_armature, current_head_bone, target_head_world_matrix):
    target_armature_space = (
        current_armature.matrix_world.inverted()
        @ target_head_world_matrix
    )

    current_head_bone.matrix = target_armature_space


def _apply_pose_sample_without_key(current_armature, pose_sample, settings):
    for pose_bone in _pose_bones_parent_first(current_armature):
        sample = pose_sample.get(pose_bone.name)

        if sample is None:
            continue

        _apply_sample_to_current_bone(
            current_armature=current_armature,
            pose_bone=pose_bone,
            bone_name=pose_bone.name,
            sample=sample,
            settings=settings,
        )

    bpy.context.view_layer.update()


def _apply_solved_matrices_as_fk(current_armature, solved_matrices):
    for pose_bone in _pose_bones_parent_first(current_armature):
        solved_matrix = solved_matrices.get(pose_bone.name)

        if solved_matrix is not None:
            pose_bone.matrix = solved_matrix

    bpy.context.view_layer.update()


def _apply_ik_landmark_pose_and_key(
    current_armature,
    targets,
    output_frame,
    settings,
    label,
    log,
    prefix,
    base_pose_sample,
):
    scene = bpy.context.scene
    scene.frame_set(int(output_frame))
    bpy.context.view_layer.update()

    if base_pose_sample is not None:
        _apply_pose_sample_without_key(
            current_armature=current_armature,
            pose_sample=base_pose_sample,
            settings=settings,
        )

    current_bones = _required_landmark_bones(
        armature=current_armature,
        settings=settings,
        prefix=prefix,
        role="current",
    )

    log.append(f"{prefix} current IK landmark bones:")
    for key in ("head", "left_hand", "right_hand", "left_foot", "right_foot"):
        log.append(f"  {key} = {current_bones[key].name}")

    empties = []
    constraints = []

    try:
        left_hand_empty = _create_world_empty(
            f"GRAVITAS_TEMP_{prefix}_LEFT_HAND_TARGET",
            targets["left_hand"],
        )
        right_hand_empty = _create_world_empty(
            f"GRAVITAS_TEMP_{prefix}_RIGHT_HAND_TARGET",
            targets["right_hand"],
        )
        left_foot_empty = _create_world_empty(
            f"GRAVITAS_TEMP_{prefix}_LEFT_FOOT_TARGET",
            targets["left_foot"],
        )
        right_foot_empty = _create_world_empty(
            f"GRAVITAS_TEMP_{prefix}_RIGHT_FOOT_TARGET",
            targets["right_foot"],
        )

        empties.extend([
            left_hand_empty,
            right_hand_empty,
            left_foot_empty,
            right_foot_empty,
        ])

        constraints.append((
            current_bones["left_hand"],
            _add_ik_constraint(
                current_bones["left_hand"],
                left_hand_empty,
                settings.left_hand_ik_chain_count,
            ),
        ))
        constraints.append((
            current_bones["right_hand"],
            _add_ik_constraint(
                current_bones["right_hand"],
                right_hand_empty,
                settings.right_hand_ik_chain_count,
            ),
        ))
        constraints.append((
            current_bones["left_foot"],
            _add_ik_constraint(
                current_bones["left_foot"],
                left_foot_empty,
                settings.left_foot_ik_chain_count,
            ),
        ))
        constraints.append((
            current_bones["right_foot"],
            _add_ik_constraint(
                current_bones["right_foot"],
                right_foot_empty,
                settings.right_foot_ik_chain_count,
            ),
        ))

        log.append(f"{prefix} IK constraints created: {len(constraints)}")

        scene.frame_set(int(output_frame))
        bpy.context.view_layer.update()

        _apply_head_target(
            current_armature=current_armature,
            current_head_bone=current_bones["head"],
            target_head_world_matrix=targets["head"],
        )

        bpy.context.view_layer.update()

        solved_matrices = {
            pose_bone.name: pose_bone.matrix.copy()
            for pose_bone in current_armature.pose.bones
        }

    finally:
        _remove_temp_ik_constraints(constraints)
        _remove_temp_empties(empties)
        bpy.context.view_layer.update()
        log.append(f"{prefix} temporary IK constraints removed")

    _apply_solved_matrices_as_fk(
        current_armature=current_armature,
        solved_matrices=solved_matrices,
    )

    keyed = 0

    for pose_bone in current_armature.pose.bones:
        bone_name = pose_bone.name

        if not _include_bone(bone_name, settings):
            continue

        _key_enabled_channels(pose_bone, bone_name, settings, int(output_frame))
        keyed += 1

    log.append(
        f"{prefix} IK solved and baked to FK keys at frame {output_frame}. keyed_bones={keyed}"
    )
    log.append(f"Applied/keyed {label} at output frame {output_frame}.")


# ============================================================
# Source import
# ============================================================

def _create_or_replace_temp_collection(context):
    old = bpy.data.collections.get(TEMP_COLLECTION_NAME)

    if old is not None:
        try:
            bpy.data.collections.remove(old)
        except Exception:
            pass

    collection = bpy.data.collections.new(TEMP_COLLECTION_NAME)
    context.scene.collection.children.link(collection)
    return collection


def _link_objects_to_collection(objects, collection):
    for obj in objects:
        try:
            if obj.name not in collection.objects.keys():
                collection.objects.link(obj)
        except Exception:
            pass


def _find_first_imported_armature(imported_objects):
    armatures = [obj for obj in imported_objects if obj.type == "ARMATURE"]

    if not armatures:
        return None

    animated = [
        armature
        for armature in armatures
        if _ensure_action(armature) is not None
    ]

    animated_with_keys = [
        armature
        for armature in animated
        if _action_has_keys(_ensure_action(armature))
    ]

    if animated_with_keys:
        animated_with_keys.sort(
            key=lambda armature: _armature_score(armature, None),
            reverse=True,
        )
        return animated_with_keys[0]

    if animated:
        animated.sort(
            key=lambda armature: _armature_score(armature, None),
            reverse=True,
        )
        return animated[0]

    return armatures[0]


def _import_source(context, filepath, collection, label, log):
    filepath = bpy.path.abspath(filepath)

    if not filepath:
        raise RuntimeError(f"{label} source path is empty.")

    if not os.path.isfile(filepath):
        raise FileNotFoundError(f"{label} source file does not exist: {filepath}")

    saved_start = context.scene.frame_start
    saved_end = context.scene.frame_end
    saved_current = context.scene.frame_current

    existing_objects = set(bpy.data.objects.keys())
    existing_actions = set(bpy.data.actions.keys())

    log.append(f"Importing {label} source: {filepath}")

    _call_operator_with_supported_kwargs(
        bpy.ops.wm.usd_import,
        filepath=filepath,

        # Important: do not let imported USD source take over the scene frame range.
        set_frame_range=False,

        import_cameras=False,
        import_lights=False,
        import_materials=True,
        import_meshes=True,
        import_skeletons=True,
        import_blendshapes=True,
        read_meshes=True,
        read_animation=True,
    )

    context.scene.frame_start = saved_start
    context.scene.frame_end = saved_end
    context.scene.frame_set(saved_current)
    bpy.context.view_layer.update()

    imported_objects = [
        obj for obj in bpy.data.objects
        if obj.name not in existing_objects
    ]

    _link_objects_to_collection(imported_objects, collection)

    armature = _find_first_imported_armature(imported_objects)

    if armature is None:
        raise RuntimeError(f"{label} source did not import an editable Armature.")

    action = _ensure_action(armature)

    if action is None:
        raise RuntimeError(f"{label} source armature has no animation action.")

    detected = _detected_action_bounds(action)

    if detected is None:
        raise RuntimeError(f"{label} source action has no keyframes.")

    log.append(f"{label} source armature: {armature.name}")
    log.append(f"{label} source detected action range: {detected[0]} -> {detected[1]}")

    return imported_objects, armature, detected, existing_actions


def _resolve_source_frame(mode, custom_frame, detected_range, label, log):
    start, end = detected_range

    if mode == "FIRST":
        frame = start
    elif mode == "LAST":
        frame = end
    elif mode == "CUSTOM":
        frame = int(custom_frame)
    else:
        frame = start

    log.append(f"{label} source frame resolved to {frame} using mode {mode}.")
    return frame


def _delete_temp_objects(imported_objects, collection, existing_action_names, log):
    for obj in list(imported_objects):
        if obj.name in bpy.data.objects:
            try:
                bpy.data.objects.remove(obj, do_unlink=True)
            except Exception:
                pass

    if collection is not None and collection.name in bpy.data.collections:
        try:
            bpy.data.collections.remove(collection)
        except Exception:
            pass

    for action in list(bpy.data.actions):
        if action.name not in existing_action_names and action.users == 0:
            try:
                bpy.data.actions.remove(action)
            except Exception:
                pass

    log.append("Deleted temporary imported source objects.")


# ============================================================
# Manual template setup
# ============================================================

def _source_settings_for_prefix(prefix, settings):
    if prefix == "HEAD":
        return (
            settings.head_source_path,
            settings.head_source_frame_mode,
            settings.head_custom_frame,
            "HEAD/PREVIOUS",
        )

    return (
        settings.tail_source_path,
        settings.tail_source_frame_mode,
        settings.tail_custom_frame,
        "TAIL/NEXT",
    )


def _manual_target_frame_for_prefix(prefix, timing):
    if prefix == "HEAD":
        return timing["output_start"]

    return timing["tail_target_out"]


def _imported_root_objects(imported_objects):
    imported_set = set(imported_objects)

    return [
        obj
        for obj in imported_objects
        if obj.parent not in imported_set
    ]


def _remove_template_collection():
    collection = bpy.data.collections.get(TEMPLATE_COLLECTION_NAME)

    if collection is None:
        return

    for obj in list(collection.objects):
        try:
            bpy.data.objects.remove(obj, do_unlink=True)
        except Exception:
            pass

    try:
        bpy.data.collections.remove(collection)
    except Exception:
        pass


def _template_material(label, opacity):
    material = bpy.data.materials.new(f"GRAVITAS_TEMPLATE_{label}_Material")
    material.diffuse_color = (0.25, 0.8, 1.0, opacity)

    if hasattr(material, "use_nodes"):
        material.use_nodes = True

        principled = material.node_tree.nodes.get("Principled BSDF")
        if principled is not None:
            alpha_input = principled.inputs.get("Alpha")
            base_color_input = principled.inputs.get("Base Color")

            if alpha_input is not None:
                alpha_input.default_value = opacity

            if base_color_input is not None:
                base_color_input.default_value = (0.25, 0.8, 1.0, opacity)

    if hasattr(material, "blend_method"):
        material.blend_method = "BLEND"

    if hasattr(material, "show_transparent_back"):
        material.show_transparent_back = True

    return material


def _apply_template_display(template, display_mode, material):
    if display_mode == "WIRE":
        template.display_type = "WIRE"
    elif display_mode == "SOLID":
        template.display_type = "SOLID"
    else:
        template.display_type = "TEXTURED"

        if material is not None:
            template.data.materials.append(material)

    template.show_in_front = True
    template.hide_render = True


def _create_static_template_from_imported_objects(
    context,
    imported_objects,
    template_collection_name,
    label,
    opacity,
    display_mode,
    log,
):
    depsgraph = context.evaluated_depsgraph_get()

    template_collection = bpy.data.collections.get(template_collection_name)
    if template_collection is None:
        template_collection = bpy.data.collections.new(template_collection_name)
        context.scene.collection.children.link(template_collection)

    material = None

    if display_mode == "TEXTURED_TRANSPARENT":
        material = _template_material(label, opacity)

    template_objects = []

    for obj in imported_objects:
        if obj.type != "MESH":
            continue

        evaluated = obj.evaluated_get(depsgraph)

        mesh = bpy.data.meshes.new_from_object(
            evaluated,
            depsgraph=depsgraph,
        )

        template = bpy.data.objects.new(
            f"GRAVITAS_TEMPLATE_{label}_{obj.name}",
            mesh,
        )

        template.matrix_world = evaluated.matrix_world.copy()
        _apply_template_display(template, display_mode, material)

        template_collection.objects.link(template)
        template_objects.append(template)

    log.append(
        f"Created {len(template_objects)} static template mesh objects for {label}."
    )

    return template_objects


def _hide_template_collection_for_export(log):
    collection = bpy.data.collections.get(TEMPLATE_COLLECTION_NAME)

    if collection is None:
        return

    collection.hide_render = True

    for obj in collection.objects:
        obj.hide_render = True
        obj.hide_set(True)

    log.append("Template collection hidden for export.")


def _sample_current_body(current_armature, source_action, settings, timing, log):
    current_armature.animation_data.action = source_action

    body_samples = []

    for source_frame in range(
        timing["body_start_in"],
        timing["body_end_in"] + 1,
    ):
        body_log = (
            log
            if source_frame in (
                timing["body_start_in"],
                timing["body_end_in"],
            )
            else []
        )
        sample = _sample_local_pose(
            armature=current_armature,
            frame=source_frame,
            settings=settings,
            label="CURRENT BODY",
            log=body_log,
        )

        body_samples.append((source_frame, sample))

    log.append(f"Sampled current body frames into memory: {len(body_samples)} frames.")
    return body_samples


def _create_padded_action_for_manual_template(
    current_armature,
    source_action,
    settings,
    timing,
    manual_prefix,
    log,
):
    body_samples = _sample_current_body(
        current_armature=current_armature,
        source_action=source_action,
        settings=settings,
        timing=timing,
        log=log,
    )

    current_first_sample = body_samples[0][1]
    current_last_sample = body_samples[-1][1]

    output_action_name = settings.output_action_name.strip()

    if not output_action_name:
        output_action_name = f"{source_action.name}_manual_template"

    output_action = source_action.copy()
    output_action.name = output_action_name
    output_action.use_fake_user = True

    current_armature.animation_data_create()
    current_armature.animation_data.action = output_action

    log.append("")
    log.append(f"Copied current action for manual-template padding: {output_action.name}")

    _delete_action_keys_outside_range(
        action=output_action,
        start_frame=timing["body_start_in"],
        end_frame=timing["body_end_in"],
        log=log,
    )

    shift_delta = timing["body_start_out"] - timing["body_start_in"]

    _shift_action_keys(
        action=output_action,
        delta=shift_delta,
        log=log,
    )

    if manual_prefix == "HEAD" and timing["head_frames"] > 0:
        _apply_pose_and_key(
            current_armature=current_armature,
            pose_sample=current_first_sample,
            output_frame=timing["output_start"],
            settings=settings,
            label="HEAD manual placeholder pose",
            log=log,
        )

    _apply_pose_and_key(
        current_armature=current_armature,
        pose_sample=current_first_sample,
        output_frame=timing["body_start_out"],
        settings=settings,
        label="CURRENT first body pose",
        log=log,
    )

    if manual_prefix == "TAIL":
        _apply_pose_and_key(
            current_armature=current_armature,
            pose_sample=current_last_sample,
            output_frame=timing["body_end_out"],
            settings=settings,
            label="CURRENT last body pose",
            log=log,
        )

        _delete_action_keys_after_frame(
            action=output_action,
            frame=timing["body_end_out"],
            log=log,
        )

    if manual_prefix == "TAIL":
        _apply_pose_and_key(
            current_armature=current_armature,
            pose_sample=current_last_sample,
            output_frame=timing["tail_target_out"],
            settings=settings,
            label="TAIL manual placeholder pose",
            log=log,
        )

        if timing["tail_hold"] > 0:
            _apply_pose_and_key(
                current_armature=current_armature,
                pose_sample=current_last_sample,
                output_frame=timing["output_end"],
                settings=settings,
                label="TAIL manual hold placeholder pose",
                log=log,
            )

    changed = _set_interpolation_for_all_keys(output_action, settings.interpolation)
    log.append(f"Set interpolation {settings.interpolation} on {changed} keyframes.")

    _hard_clamp_action_to_output_range(
        action=output_action,
        output_start=timing["output_start"],
        output_end=timing["output_end"],
        log=log,
    )

    _force_exact_export_range(
        context=bpy.context,
        action=output_action,
        start_frame=timing["output_start"],
        end_frame=timing["output_end"],
        log=log,
    )

    return output_action


def _build_padding_and_template(
    context,
    current_armature,
    source_action,
    settings,
    log,
):
    manual_prefix = _manual_template_boundary_prefix(settings)

    if manual_prefix is None:
        raise RuntimeError(
            "Manual template setup requires a rotated enabled Head or Tail source."
        )

    timing = _compute_enabled_transition_range(settings, log)

    manual_target_frame = _manual_target_frame_for_prefix(manual_prefix, timing)

    if manual_target_frame is None:
        raise RuntimeError(f"{manual_prefix} manual target frame could not be computed.")

    settings.manual_template_target_frame = int(manual_target_frame)
    settings.computed_output_start_frame = int(timing["output_start"])
    settings.computed_output_end_frame = int(timing["output_end"])

    output_action = _create_padded_action_for_manual_template(
        current_armature=current_armature,
        source_action=source_action,
        settings=settings,
        timing=timing,
        manual_prefix=manual_prefix,
        log=log,
    )

    source_path, source_frame_mode, custom_frame, source_label = _source_settings_for_prefix(
        manual_prefix,
        settings,
    )

    temp_collection = _create_or_replace_temp_collection(context)
    imported_objects = []
    existing_action_names = set(bpy.data.actions.keys())

    try:
        imported_objects, source_armature, source_range, source_existing_actions = _import_source(
            context=context,
            filepath=source_path,
            collection=temp_collection,
            label=source_label,
            log=log,
        )
        existing_action_names.update(source_existing_actions)

        source_frame = _resolve_source_frame(
            mode=source_frame_mode,
            custom_frame=custom_frame,
            detected_range=source_range,
            label=source_label,
            log=log,
        )

        context.scene.frame_set(int(source_frame))
        context.view_layer.update()

        rotation_matrix = _source_rotation_matrix(
            manual_prefix,
            current_armature,
            source_armature,
            settings,
        )

        root_objects = _imported_root_objects(imported_objects)

        for root_object in root_objects:
            root_object.matrix_world = rotation_matrix @ root_object.matrix_world

        context.view_layer.update()

        log.append(
            f"{manual_prefix} manual template source rotated as object hierarchy. "
            f"root_objects={len(root_objects)}"
        )

        _remove_template_collection()
        _create_static_template_from_imported_objects(
            context=context,
            imported_objects=imported_objects,
            template_collection_name=TEMPLATE_COLLECTION_NAME,
            label=manual_prefix,
            opacity=settings.template_opacity,
            display_mode=settings.template_display,
            log=log,
        )

    finally:
        _delete_temp_objects(
            imported_objects,
            temp_collection,
            existing_action_names,
            log,
        )

    current_armature.animation_data.action = output_action
    context.scene.frame_set(int(manual_target_frame))
    context.view_layer.update()

    log.append(
        f"{manual_prefix} manual template ready at frame {manual_target_frame}. "
        "Pose/key the current rig against the ghost, then run Finalize Manual Key + Export."
    )

    return timing


# ============================================================
# Frame range / export
# ============================================================

def _force_frame_range(context, action, start_frame, end_frame, log):
    start_frame = int(start_frame)
    end_frame = int(end_frame)

    context.scene.frame_start = start_frame
    context.scene.frame_end = end_frame
    context.scene.frame_set(start_frame)

    if action is not None:
        if hasattr(action, "use_frame_range"):
            action.use_frame_range = True

        if hasattr(action, "frame_start"):
            action.frame_start = float(start_frame)

        if hasattr(action, "frame_end"):
            action.frame_end = float(end_frame)

    bpy.context.view_layer.update()

    log.append(f"FORCED SCENE/ACTION FRAME RANGE: {start_frame} -> {end_frame}")


def _force_exact_export_range(context, action, start_frame, end_frame, log):
    start_frame = int(start_frame)
    end_frame = int(end_frame)

    context.scene.frame_start = start_frame
    context.scene.frame_end = end_frame
    context.scene.frame_set(start_frame)

    if action is not None:
        if hasattr(action, "use_frame_range"):
            action.use_frame_range = True

        if hasattr(action, "frame_start"):
            action.frame_start = float(start_frame)

        if hasattr(action, "frame_end"):
            action.frame_end = float(end_frame)

    bpy.context.view_layer.update()

    log.append(f"FORCED EXACT EXPORT RANGE: {start_frame} -> {end_frame}")


def _hard_clamp_action_to_output_range(action, output_start, output_end, log):
    _delete_action_keys_outside_range(
        action=action,
        start_frame=output_start,
        end_frame=output_end,
        log=log,
    )
    _delete_action_keys_after_frame(
        action=action,
        frame=output_end,
        log=log,
    )

    extra_keys = _count_keys_after_frame(action, output_end)

    if extra_keys > 0:
        raise RuntimeError(
            f"Export would still include extra frames: {extra_keys} keys exist after output_end={output_end}"
        )


def _export_usd(context, filepath, current_armature, selected_only, log):
    filepath = bpy.path.abspath(filepath)

    if not filepath:
        raise RuntimeError("Export path is empty.")

    export_dir = os.path.dirname(filepath)

    if export_dir and not os.path.isdir(export_dir):
        os.makedirs(export_dir, exist_ok=True)

    active_name, selected_names = _stash_selection(context)

    try:
        if selected_only:
            _select_armature_and_descendants(context, current_armature)

        log.append(f"Exporting USDZ/USD: {filepath}")
        log.append(f"Export range at call time: {context.scene.frame_start} -> {context.scene.frame_end}")

        _call_operator_with_supported_kwargs(
            bpy.ops.wm.usd_export,
            filepath=filepath,
            selected_objects_only=selected_only,
            visible_objects_only=False,

            export_animation=True,
            export_armatures=True,
            export_meshes=True,
            export_materials=True,
            export_textures=True,
            export_uvmaps=True,
            export_normals=True,
            export_shapekeys=True,

            evaluation_mode="RENDER",

            # Blender versions differ; unsupported args are filtered.
            frame_start=context.scene.frame_start,
            frame_end=context.scene.frame_end,
            start_frame=context.scene.frame_start,
            end_frame=context.scene.frame_end,
            animation_start=context.scene.frame_start,
            animation_end=context.scene.frame_end,
        )

    finally:
        _restore_selection(context, active_name, selected_names)


# ============================================================
# Settings
# ============================================================

class GravitasExplicitStitcherSettingsV17(PropertyGroup):
    current_body_start: IntProperty(
        name="Current Body Start",
        description="First frame of the current clip body. Set explicitly.",
        default=1,
        min=-100000,
        max=100000,
    )

    current_body_end: IntProperty(
        name="Current Body End",
        description="Last frame of the current clip body. Set explicitly.",
        default=60,
        min=-100000,
        max=100000,
    )

    output_start_frame: IntProperty(
        name="Output Start Frame",
        default=1,
        min=-100000,
        max=100000,
    )

    enable_head_transition: BoolProperty(
        name="Enable Head Transition",
        default=True,
    )

    head_source_path: StringProperty(
        name="Head / Previous Source File",
        subtype="FILE_PATH",
        default="",
    )

    head_source_frame_mode: EnumProperty(
        name="Head Source Frame",
        items=[
            ("FIRST", "First", "Sample first keyed frame."),
            ("LAST", "Last", "Sample last keyed frame."),
            ("CUSTOM", "Custom", "Use custom frame."),
        ],
        default="LAST",
    )

    head_custom_frame: IntProperty(
        name="Head Custom Frame",
        default=1,
        min=-100000,
        max=100000,
    )

    head_transition_frames: IntProperty(
        name="Head Transition Frames",
        default=5,
        min=0,
        max=240,
    )

    head_solve_mode: EnumProperty(
        name="Head Solve Mode",
        items=[
            ("AUTO", "Auto", "Use IK landmarks when source rotation is enabled, otherwise use full pose matrix."),
            ("FULL_POSE_MATRIX", "Full Pose Matrix", "Use the existing v1.7 full source-pose matrix path."),
            ("IK_LANDMARKS", "IK Landmarks", "Use landmark targets and bake the IK result to FK keys."),
        ],
        default="AUTO",
    )

    tail_source_path: StringProperty(
        name="Tail / Next Source File",
        subtype="FILE_PATH",
        default="",
    )

    tail_source_frame_mode: EnumProperty(
        name="Tail Source Frame",
        items=[
            ("FIRST", "First", "Sample first keyed frame."),
            ("LAST", "Last", "Sample last keyed frame."),
            ("CUSTOM", "Custom", "Use custom frame."),
        ],
        default="FIRST",
    )

    tail_custom_frame: IntProperty(
        name="Tail Custom Frame",
        default=1,
        min=-100000,
        max=100000,
    )

    tail_transition_frames: IntProperty(
        name="Tail Transition Frames",
        default=5,
        min=0,
        max=240,
    )

    tail_hold_frames: IntProperty(
        name="Tail Hold Frames",
        default=0,
        min=0,
        max=120,
    )

    enable_tail_transition: BoolProperty(
        name="Enable Tail Transition",
        default=True,
    )

    tail_solve_mode: EnumProperty(
        name="Tail Solve Mode",
        items=[
            ("AUTO", "Auto", "Use IK landmarks when source rotation is enabled, otherwise use full pose matrix."),
            ("FULL_POSE_MATRIX", "Full Pose Matrix", "Use the existing v1.7 full source-pose matrix path."),
            ("IK_LANDMARKS", "IK Landmarks", "Use landmark targets and bake the IK result to FK keys."),
        ],
        default="AUTO",
    )

    head_enable_source_rotation: BoolProperty(
        name="Rotate Head Source Pose",
        default=False,
    )

    head_rotation_x_degrees: FloatProperty(name="Head Rot X", default=0.0)
    head_rotation_y_degrees: FloatProperty(name="Head Rot Y", default=0.0)
    head_rotation_z_degrees: FloatProperty(name="Head Rot Z", default=0.0)

    head_rotation_pivot: EnumProperty(
        name="Head Rotation Pivot",
        items=[
            ("CURRENT_ARMATURE_ORIGIN", "Current Armature Origin", ""),
            ("SOURCE_ARMATURE_ORIGIN", "Source Armature Origin", ""),
            ("WORLD_ORIGIN", "World Origin", ""),
        ],
        default="CURRENT_ARMATURE_ORIGIN",
    )

    tail_enable_source_rotation: BoolProperty(
        name="Rotate Tail Source Pose",
        description="For same-file turn1->turn2, enable and try Tail Rot Z = 90.",
        default=False,
    )

    tail_rotation_x_degrees: FloatProperty(name="Tail Rot X", default=0.0)
    tail_rotation_y_degrees: FloatProperty(name="Tail Rot Y", default=0.0)
    tail_rotation_z_degrees: FloatProperty(name="Tail Rot Z", default=0.0)

    tail_rotation_pivot: EnumProperty(
        name="Tail Rotation Pivot",
        items=[
            ("CURRENT_ARMATURE_ORIGIN", "Current Armature Origin", ""),
            ("SOURCE_ARMATURE_ORIGIN", "Source Armature Origin", ""),
            ("WORLD_ORIGIN", "World Origin", ""),
        ],
        default="CURRENT_ARMATURE_ORIGIN",
    )

    output_action_name: StringProperty(
        name="Output Action Name",
        default="",
    )

    copy_bone_rotations: BoolProperty(
        name="Copy Bone Rotations",
        default=True,
    )

    copy_bone_locations: BoolProperty(
        name="Copy Non-Root Bone Locations",
        default=True,
    )

    copy_root_location: BoolProperty(
        name="Copy Root Location",
        description="Usually OFF. Swift/RealityKit owns world translation.",
        default=False,
    )

    copy_root_rotation: BoolProperty(
        name="Copy Root Rotation",
        description="Usually ON for turn stitching.",
        default=True,
    )

    copy_bone_scales: BoolProperty(
        name="Copy Bone Scales",
        default=False,
    )

    root_bone_tokens: StringProperty(
        name="Root Bone Tokens",
        default="root,global,master,armature",
    )

    include_jaw: BoolProperty(name="Include Jaw", default=True)
    include_fingers: BoolProperty(name="Include Fingers", default=True)

    jaw_bone_tokens: StringProperty(name="Jaw Tokens", default="jaw")
    finger_bone_tokens: StringProperty(
        name="Finger Tokens",
        default="finger,thumb,index,middle,ring,pinky",
    )

    head_bone_candidates: StringProperty(
        name="Head Bone",
        default="Head,head,mixamorig:Head",
    )

    left_hand_bone_candidates: StringProperty(
        name="Left Hand Bone",
        default="LeftHand,hand_L,Hand_L,mixamorig:LeftHand",
    )

    right_hand_bone_candidates: StringProperty(
        name="Right Hand Bone",
        default="RightHand,hand_R,Hand_R,mixamorig:RightHand",
    )

    left_foot_bone_candidates: StringProperty(
        name="Left Foot Bone",
        default="LeftFoot,foot_L,Foot_L,mixamorig:LeftFoot",
    )

    right_foot_bone_candidates: StringProperty(
        name="Right Foot Bone",
        default="RightFoot,foot_R,Foot_R,mixamorig:RightFoot",
    )

    left_hand_ik_chain_count: IntProperty(
        name="Left Hand IK Chain Count",
        default=2,
        min=1,
        max=16,
    )

    right_hand_ik_chain_count: IntProperty(
        name="Right Hand IK Chain Count",
        default=2,
        min=1,
        max=16,
    )

    left_foot_ik_chain_count: IntProperty(
        name="Left Foot IK Chain Count",
        default=2,
        min=1,
        max=16,
    )

    right_foot_ik_chain_count: IntProperty(
        name="Right Foot IK Chain Count",
        default=2,
        min=1,
        max=16,
    )

    interpolation: EnumProperty(
        name="Interpolation",
        items=[
            ("BEZIER", "Bezier", ""),
            ("LINEAR", "Linear", ""),
            ("CONSTANT", "Constant", ""),
        ],
        default="BEZIER",
    )

    update_after_each_bone_matrix_set: BoolProperty(
        name="Update After Each Bone Matrix Set",
        default=False,
    )

    export_after_stitch: BoolProperty(
        name="Export After Stitch",
        default=False,
    )

    export_path: StringProperty(
        name="Export Path",
        subtype="FILE_PATH",
        default="",
    )

    export_selected_only: BoolProperty(
        name="Export Current Armature + Children Only",
        default=True,
    )

    write_log_text: BoolProperty(
        name="Write Log Text Block",
        default=True,
    )

    manual_template_mode_when_rotated: BoolProperty(
        name="Manual Template Mode When Rotated",
        default=True,
    )

    template_display: EnumProperty(
        name="Template Display",
        items=[
            ("SOLID", "Solid", "Display the template as solid viewport geometry."),
            ("WIRE", "Wire", "Display the template as wire geometry."),
            ("TEXTURED_TRANSPARENT", "Textured Transparent", "Display the template with transparent material."),
        ],
        default="TEXTURED_TRANSPARENT",
    )

    template_opacity: FloatProperty(
        name="Template Opacity",
        default=0.35,
        min=0.0,
        max=1.0,
    )

    manual_template_target_frame: IntProperty(
        name="Manual Template Target Frame",
        default=1,
        min=-100000,
        max=100000,
    )

    computed_output_start_frame: IntProperty(
        name="Computed Output Start",
        default=1,
        min=-100000,
        max=100000,
    )

    computed_output_end_frame: IntProperty(
        name="Computed Output End",
        default=1,
        min=-100000,
        max=100000,
    )


# ============================================================
# Operators
# ============================================================

class GRAVITAS_OT_explicit_stitcher_capture_body_range_v17(Operator):
    bl_idname = "gravitas.explicit_stitcher_capture_body_range_v17"
    bl_label = "Capture Body Range From Detected Action"
    bl_description = "Sets Current Body Start/End from the detected action range on the nested selected armature."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_explicit_stitcher_v17
        armature = _find_armature_from_selection_or_parent(context)

        if armature is None:
            self.report({"ERROR"}, "No Armature found under the current selection.")
            return {"CANCELLED"}

        action = _ensure_action(armature)

        if action is None:
            self.report({"ERROR"}, f"Detected armature '{armature.name}' has no active action.")
            return {"CANCELLED"}

        bounds = _detected_action_bounds(action)

        if bounds is None:
            self.report({"ERROR"}, f"Action '{action.name}' has no detectable keyframes.")
            return {"CANCELLED"}

        settings.current_body_start = bounds[0]
        settings.current_body_end = bounds[1]

        self.report(
            {"INFO"},
            f"Captured body range from {armature.name}: {bounds[0]} -> {bounds[1]}",
        )

        return {"FINISHED"}


class GRAVITAS_OT_build_padding_and_template_v17(Operator):
    bl_idname = "gravitas.build_padding_and_template_v17"
    bl_label = "Build Padding + Template"
    bl_description = "Builds padded placeholder keys and a rotated static source template for manual posing."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_explicit_stitcher_v17

        log = []
        success = False

        active_name, selected_names = _stash_selection(context)

        try:
            _force_object_mode()

            log.append("============================================================")
            log.append("Gravitas Manual Template Setup v1.7")
            log.append("============================================================")

            current_armature = _find_armature_from_selection_or_parent(context)

            if current_armature is None:
                raise RuntimeError(
                    "No Armature found under the current selection. "
                    "Select the top imported parent/group/empty that contains the character."
                )

            source_action = _ensure_action(current_armature)

            if source_action is None:
                raise RuntimeError(
                    f"Detected armature '{current_armature.name}' has no active animation action."
                )

            log.append(f"Detected current armature: {current_armature.name}")
            log.append(f"Detected current action: {source_action.name}")

            _build_padding_and_template(
                context=context,
                current_armature=current_armature,
                source_action=source_action,
                settings=settings,
                log=log,
            )

            _safe_report(
                self,
                {"INFO"},
                f"Manual template ready at frame {settings.manual_template_target_frame}.",
            )

            success = True

        except Exception as error:
            log.append("")
            log.append("ERROR")
            log.append(str(error))
            log.append("")
            log.append(traceback.format_exc())

            _safe_report(self, {"ERROR"}, str(error))

        finally:
            _restore_selection(context, active_name, selected_names)

            if settings.write_log_text:
                _write_log(log)

        return {"FINISHED"} if success else {"CANCELLED"}


class GRAVITAS_OT_finalize_manual_key_and_export_v17(Operator):
    bl_idname = "gravitas.finalize_manual_key_and_export_v17"
    bl_label = "Finalize Manual Key + Export"
    bl_description = "Keys the current manual pose, hides the template, forces the output range, and exports the current hierarchy."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_explicit_stitcher_v17

        log = []
        success = False

        active_name, selected_names = _stash_selection(context)

        try:
            _force_object_mode()

            log.append("============================================================")
            log.append("Gravitas Finalize Manual Key + Export v1.7")
            log.append("============================================================")

            current_armature = _find_armature_from_selection_or_parent(context)

            if current_armature is None:
                raise RuntimeError(
                    "No Armature found under the current selection. "
                    "Select the top imported parent/group/empty that contains the character."
                )

            action = _ensure_action(current_armature)

            if action is None:
                raise RuntimeError(
                    f"Detected armature '{current_armature.name}' has no active animation action."
                )

            manual_frame = int(settings.manual_template_target_frame)

            context.scene.frame_set(manual_frame)
            context.view_layer.update()

            keyed = 0

            for pose_bone in current_armature.pose.bones:
                bone_name = pose_bone.name

                if not _include_bone(bone_name, settings):
                    continue

                _key_enabled_channels(pose_bone, bone_name, settings, manual_frame)
                keyed += 1

            log.append(f"Finalized manual FK key at frame {manual_frame}. keyed_bones={keyed}")

            output_start = int(settings.computed_output_start_frame)
            output_end = int(settings.computed_output_end_frame)

            if output_end < output_start:
                raise RuntimeError(
                    f"Computed output range is invalid: {output_start} -> {output_end}."
                )

            _hard_clamp_action_to_output_range(
                action=action,
                output_start=output_start,
                output_end=output_end,
                log=log,
            )

            _force_exact_export_range(
                context=context,
                action=action,
                start_frame=output_start,
                end_frame=output_end,
                log=log,
            )

            _hide_template_collection_for_export(log)

            _export_usd(
                context=context,
                filepath=settings.export_path,
                current_armature=current_armature,
                selected_only=True,
                log=log,
            )

            _safe_report(
                self,
                {"INFO"},
                f"Finalized frame {manual_frame} and exported {output_start}->{output_end}.",
            )

            success = True

        except Exception as error:
            log.append("")
            log.append("ERROR")
            log.append(str(error))
            log.append("")
            log.append(traceback.format_exc())

            _safe_report(self, {"ERROR"}, str(error))

        finally:
            _restore_selection(context, active_name, selected_names)

            if settings.write_log_text:
                _write_log(log)

        return {"FINISHED"} if success else {"CANCELLED"}


class GRAVITAS_OT_explicit_stitcher_build_v17(Operator):
    bl_idname = "gravitas.explicit_stitcher_build_v17"
    bl_label = "Build Explicit Head / Body / Tail Clip"
    bl_description = "Creates a clean baked output action with explicit head and tail transitions."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_explicit_stitcher_v17

        log = []
        success = False

        active_name, selected_names = _stash_selection(context)

        temp_collection = None
        imported_objects = []
        existing_action_names = set(bpy.data.actions.keys())

        try:
            _force_object_mode()

            log.append("============================================================")
            log.append("Gravitas Explicit Head / Body / Tail Stitcher v1.7")
            log.append("============================================================")

            current_armature = _find_armature_from_selection_or_parent(context)

            if current_armature is None:
                raise RuntimeError(
                    "No Armature found under the current selection. "
                    "Select the top imported parent/group/empty that contains the character."
                )

            source_action = _ensure_action(current_armature)

            if source_action is None:
                raise RuntimeError(
                    f"Detected armature '{current_armature.name}' has no active animation action."
                )

            detected = _detected_action_bounds(source_action)
            source_fcurve_count = _action_fcurve_count(source_action)

            log.append(f"Detected current armature: {current_armature.name}")
            log.append(f"Detected current action: {source_action.name}")
            log.append(f"Detected current action fcurves: {source_fcurve_count}")

            if detected is not None:
                log.append(f"Detected current action key range: {detected[0]} -> {detected[1]}")
            else:
                log.append("Detected current action key range: none")

            manual_prefix = _manual_template_boundary_prefix(settings)

            if manual_prefix is not None:
                log.append(
                    f"{manual_prefix} source rotation is enabled; building manual template instead of auto-solving."
                )
                _build_padding_and_template(
                    context=context,
                    current_armature=current_armature,
                    source_action=source_action,
                    settings=settings,
                    log=log,
                )

                _safe_report(
                    self,
                    {"INFO"},
                    f"Manual template ready at frame {settings.manual_template_target_frame}.",
                )

                success = True
                return {"FINISHED"}

            ranges = _compute_enabled_transition_range(settings, log)

            body_start_in = ranges["body_start_in"]
            body_end_in = ranges["body_end_in"]
            output_start = ranges["output_start"]
            head_enabled = ranges["head_enabled"]
            head_frames = ranges["head_frames"]
            tail_enabled = ranges["tail_enabled"]
            tail_frames = ranges["tail_frames"]
            tail_hold = ranges["tail_hold"]
            body_start_out = ranges["body_start_out"]
            body_end_out = ranges["body_end_out"]
            tail_target_out = ranges["tail_target_out"]
            output_end = ranges["output_end"]

            # ------------------------------------------------
            # 1. Sample current boundary poses.
            # ------------------------------------------------
            current_armature.animation_data.action = source_action

            current_first_sample = _sample_local_pose(
                armature=current_armature,
                frame=body_start_in,
                settings=settings,
                label="CURRENT BODY FIRST",
                log=log,
            )
            current_last_sample = _sample_local_pose(
                armature=current_armature,
                frame=body_end_in,
                settings=settings,
                label="CURRENT BODY LAST",
                log=log,
            )

            # ------------------------------------------------
            # 2. Copy, trim, and shift the current body action.
            # ------------------------------------------------

            output_action_name = settings.output_action_name.strip()

            if not output_action_name:
                output_action_name = f"{source_action.name}_explicit_head_tail"

            output_action = source_action.copy()
            output_action.name = output_action_name
            output_action.use_fake_user = True

            current_armature.animation_data_create()
            current_armature.animation_data.action = output_action

            log.append("")
            log.append(f"Copied current action for stitched output: {output_action.name}")

            _delete_action_keys_outside_range(
                action=output_action,
                start_frame=body_start_in,
                end_frame=body_end_in,
                log=log,
            )

            _shift_action_keys(
                action=output_action,
                delta=body_start_out - body_start_in,
                log=log,
            )

            # ------------------------------------------------
            # 3. Import/sample enabled head and tail sources.
            # ------------------------------------------------

            temp_collection = _create_or_replace_temp_collection(context)

            head_sample = None
            head_targets = None
            head_solve_mode = None
            tail_sample = None
            tail_targets = None
            tail_solve_mode = None

            if head_enabled:
                head_imported, head_armature, head_range, head_existing_actions = _import_source(
                    context=context,
                    filepath=settings.head_source_path,
                    collection=temp_collection,
                    label="HEAD/PREVIOUS",
                    log=log,
                )

                imported_objects.extend(head_imported)
                existing_action_names.update(head_existing_actions)

                head_frame = _resolve_source_frame(
                    mode=settings.head_source_frame_mode,
                    custom_frame=settings.head_custom_frame,
                    detected_range=head_range,
                    label="HEAD/PREVIOUS",
                    log=log,
                )

                head_solve_mode = _resolved_boundary_solve_mode("HEAD", settings)
                log.append(f"HEAD solve mode: {head_solve_mode}")

                if head_solve_mode == "FULL_POSE_MATRIX":
                    log.append("HEAD using existing v1.2 full pose matrix path")
                    head_sample = _sample_source_pose(
                        prefix="HEAD",
                        current_armature=current_armature,
                        source_armature=head_armature,
                        source_frame=head_frame,
                        settings=settings,
                        label="HEAD/PREVIOUS",
                        log=log,
                    )
                elif head_solve_mode == "IK_LANDMARKS":
                    head_targets = _sample_source_landmark_targets(
                        prefix="HEAD",
                        current_armature=current_armature,
                        source_armature=head_armature,
                        source_frame=head_frame,
                        settings=settings,
                        label="HEAD/PREVIOUS",
                        log=log,
                    )
                else:
                    raise RuntimeError(f"Unknown HEAD solve mode: {head_solve_mode}")
            else:
                log.append("Head transition disabled.")

            if tail_enabled:
                tail_imported, tail_armature, tail_range, tail_existing_actions = _import_source(
                    context=context,
                    filepath=settings.tail_source_path,
                    collection=temp_collection,
                    label="TAIL/NEXT",
                    log=log,
                )

                imported_objects.extend(tail_imported)
                existing_action_names.update(tail_existing_actions)

                tail_frame = _resolve_source_frame(
                    mode=settings.tail_source_frame_mode,
                    custom_frame=settings.tail_custom_frame,
                    detected_range=tail_range,
                    label="TAIL/NEXT",
                    log=log,
                )

                tail_solve_mode = _resolved_boundary_solve_mode("TAIL", settings)
                log.append(f"TAIL solve mode: {tail_solve_mode}")

                if tail_solve_mode == "FULL_POSE_MATRIX":
                    log.append("TAIL using existing v1.2 full pose matrix path")
                    tail_sample = _sample_source_pose(
                        prefix="TAIL",
                        current_armature=current_armature,
                        source_armature=tail_armature,
                        source_frame=tail_frame,
                        settings=settings,
                        label="TAIL/NEXT",
                        log=log,
                    )
                elif tail_solve_mode == "IK_LANDMARKS":
                    tail_targets = _sample_source_landmark_targets(
                        prefix="TAIL",
                        current_armature=current_armature,
                        source_armature=tail_armature,
                        source_frame=tail_frame,
                        settings=settings,
                        label="TAIL/NEXT",
                        log=log,
                    )
                else:
                    raise RuntimeError(f"Unknown TAIL solve mode: {tail_solve_mode}")
            else:
                log.append("Tail transition disabled.")

            _delete_temp_objects(
                imported_objects,
                temp_collection,
                existing_action_names,
                log,
            )

            imported_objects = []
            temp_collection = None

            # ------------------------------------------------
            # 4. Key head/body/tail.
            # ------------------------------------------------

            if head_enabled and head_frames > 0:
                if head_solve_mode == "FULL_POSE_MATRIX":
                    _apply_pose_and_key(
                        current_armature=current_armature,
                        pose_sample=head_sample,
                        output_frame=output_start,
                        settings=settings,
                        label="HEAD source pose",
                        log=log,
                    )
                elif head_solve_mode == "IK_LANDMARKS":
                    _apply_ik_landmark_pose_and_key(
                        current_armature=current_armature,
                        targets=head_targets,
                        output_frame=output_start,
                        settings=settings,
                        label="HEAD IK landmark pose",
                        log=log,
                        prefix="HEAD",
                        base_pose_sample=current_first_sample,
                    )
                else:
                    raise RuntimeError(f"Unknown HEAD solve mode: {head_solve_mode}")

                _apply_pose_and_key(
                    current_armature=current_armature,
                    pose_sample=current_first_sample,
                    output_frame=body_start_out,
                    settings=settings,
                    label="CURRENT first body pose",
                    log=log,
                )
            else:
                log.append(
                    "Head disabled; copied body action starts at "
                    f"frame {body_start_out}."
                )

            log.append(
                f"Copied body keys constrained to output frames {body_start_out} -> {body_end_out}."
            )

            if tail_enabled:
                _apply_pose_and_key(
                    current_armature=current_armature,
                    pose_sample=current_last_sample,
                    output_frame=body_end_out,
                    settings=settings,
                    label="CURRENT last body pose",
                    log=log,
                )

            if tail_enabled and tail_frames > 0:
                if tail_solve_mode == "FULL_POSE_MATRIX":
                    _apply_pose_and_key(
                        current_armature=current_armature,
                        pose_sample=tail_sample,
                        output_frame=tail_target_out,
                        settings=settings,
                        label="TAIL source pose",
                        log=log,
                    )
                elif tail_solve_mode == "IK_LANDMARKS":
                    _apply_ik_landmark_pose_and_key(
                        current_armature=current_armature,
                        targets=tail_targets,
                        output_frame=tail_target_out,
                        settings=settings,
                        label="TAIL IK landmark pose",
                        log=log,
                        prefix="TAIL",
                        base_pose_sample=current_last_sample,
                    )
                else:
                    raise RuntimeError(f"Unknown TAIL solve mode: {tail_solve_mode}")

            if tail_enabled and tail_hold > 0:
                if tail_solve_mode == "FULL_POSE_MATRIX":
                    _apply_pose_and_key(
                        current_armature=current_armature,
                        pose_sample=tail_sample,
                        output_frame=output_end,
                        settings=settings,
                        label="TAIL hold pose",
                        log=log,
                    )
                elif tail_solve_mode == "IK_LANDMARKS":
                    _apply_ik_landmark_pose_and_key(
                        current_armature=current_armature,
                        targets=tail_targets,
                        output_frame=output_end,
                        settings=settings,
                        label="TAIL IK landmark hold pose",
                        log=log,
                        prefix="TAIL",
                        base_pose_sample=current_last_sample,
                    )
                else:
                    raise RuntimeError(f"Unknown TAIL solve mode: {tail_solve_mode}")

            # ------------------------------------------------
            # 5. Interpolation, verification, frame range, export.
            # ------------------------------------------------

            changed = _set_interpolation_for_all_keys(output_action, settings.interpolation)
            log.append(f"Set interpolation {settings.interpolation} on {changed} keyframes.")

            _hard_clamp_action_to_output_range(
                action=output_action,
                output_start=output_start,
                output_end=output_end,
                log=log,
            )

            _force_exact_export_range(
                context=context,
                action=output_action,
                start_frame=output_start,
                end_frame=output_end,
                log=log,
            )

            head_key_count = _count_keys_at_frame(output_action, output_start)
            body_key_count = _count_keys_at_frame(output_action, body_start_out)
            tail_key_count = (
                _count_keys_at_frame(output_action, tail_target_out)
                if tail_enabled
                else None
            )
            end_key_count = _count_keys_at_frame(output_action, output_end)

            log.append("")
            log.append("KEY VERIFICATION")
            log.append(f"  keys at output_start {output_start}: {head_key_count}")
            log.append(f"  keys at body_start   {body_start_out}: {body_key_count}")
            if tail_enabled:
                log.append(f"  keys at tail_target  {tail_target_out}: {tail_key_count}")

            log.append(f"  keys at output_end   {output_end}: {end_key_count}")

            if head_enabled and head_frames > 0 and head_key_count == 0:
                raise RuntimeError("Verification failed: no head keys were written.")

            if body_key_count == 0:
                raise RuntimeError("Verification failed: no body-start keys were written.")

            if tail_enabled and tail_frames > 0 and tail_key_count == 0:
                raise RuntimeError("Verification failed: no tail keys were written.")

            if settings.export_after_stitch:
                _export_usd(
                    context=context,
                    filepath=settings.export_path,
                    current_armature=current_armature,
                    selected_only=settings.export_selected_only,
                    log=log,
                )

            context.scene.frame_set(output_start)
            bpy.context.view_layer.update()

            log.append("")
            log.append("SUCCESS")
            log.append(f"Output action: {output_action.name}")
            log.append(f"Final frame range: {output_start} -> {output_end}")
            log.append("============================================================")

            _safe_report(
                self,
                {"INFO"},
                f"Built explicit stitched clip {output_start}->{output_end}; head/body/tail keys verified.",
            )

            success = True

        except Exception as error:
            log.append("")
            log.append("ERROR")
            log.append(str(error))
            log.append("")
            log.append(traceback.format_exc())

            _safe_report(self, {"ERROR"}, str(error))

        finally:
            if imported_objects:
                try:
                    _delete_temp_objects(
                        imported_objects,
                        temp_collection,
                        existing_action_names,
                        log,
                    )
                except Exception:
                    log.append("WARNING: temp cleanup failed.")
                    log.append(traceback.format_exc())

            _restore_selection(context, active_name, selected_names)

            if settings.write_log_text:
                _write_log(log)

        return {"FINISHED"} if success else {"CANCELLED"}


# ============================================================
# UI
# ============================================================

class GRAVITAS_PT_explicit_stitcher_panel_v17(Panel):
    bl_label = "Explicit Stitcher v1.7"
    bl_idname = "GRAVITAS_PT_explicit_stitcher_panel_v17"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Gravitas"

    def draw(self, context):
        layout = self.layout
        settings = context.scene.gravitas_explicit_stitcher_v17

        status = layout.box()
        status.label(text="Selection / Armature Detection", icon="ARMATURE_DATA")

        try:
            armature = _find_armature_from_selection_or_parent(context)
            action = _ensure_action(armature) if armature else None

            selected_names = [obj.name for obj in context.selected_objects]

            if selected_names:
                status.label(text=f"Selected: {', '.join(selected_names[:2])}")
                if len(selected_names) > 2:
                    status.label(text=f"...and {len(selected_names) - 2} more")
            else:
                status.label(text="Selected: none", icon="ERROR")

            if armature:
                status.label(text=f"Detected Armature: {armature.name}")
            else:
                status.label(text="Detected Armature: none", icon="ERROR")

            if action:
                bounds = _detected_action_bounds(action)
                fcurve_count = _action_fcurve_count(action)
                status.label(text=f"Action: {action.name}")
                status.label(text=f"Detected fcurves: {fcurve_count}")

                if bounds:
                    status.label(text=f"Detected keys: {bounds[0]} -> {bounds[1]}")
                else:
                    status.label(text="Detected keys: none")
            else:
                status.label(text="Action: none", icon="ERROR")

        except Exception as error:
            status.label(text=f"Detection error: {error}", icon="ERROR")

        layout.separator()

        current = layout.box()
        current.label(text="Current Body Range - Set Explicitly", icon="TIME")
        current.operator(
            GRAVITAS_OT_explicit_stitcher_capture_body_range_v17.bl_idname,
            text="Capture Body Range From Detected Action",
            icon="EYEDROPPER",
        )
        current.prop(settings, "current_body_start")
        current.prop(settings, "current_body_end")
        current.prop(settings, "output_start_frame")

        head = layout.box()
        head.label(text="Head / Previous Source", icon="PREV_KEYFRAME")
        head.prop(settings, "enable_head_transition")
        head.prop(settings, "head_source_path")
        head.prop(settings, "head_source_frame_mode")
        head.prop(settings, "head_custom_frame")
        head.prop(settings, "head_transition_frames")

        head_rot = head.box()
        head_rot.label(text="Optional Head Source Rotation")
        head_rot.prop(settings, "head_enable_source_rotation")
        head_rot.prop(settings, "head_rotation_x_degrees")
        head_rot.prop(settings, "head_rotation_y_degrees")
        head_rot.prop(settings, "head_rotation_z_degrees")
        head_rot.prop(settings, "head_rotation_pivot")

        tail = layout.box()
        tail.label(text="Tail / Next Source", icon="NEXT_KEYFRAME")
        tail.prop(settings, "enable_tail_transition")
        tail.prop(settings, "tail_source_path")
        tail.prop(settings, "tail_source_frame_mode")
        tail.prop(settings, "tail_custom_frame")
        tail.prop(settings, "tail_transition_frames")
        tail.prop(settings, "tail_hold_frames")

        tail_rot = tail.box()
        tail_rot.label(text="Optional Tail Source Rotation")
        tail_rot.prop(settings, "tail_enable_source_rotation")
        tail_rot.prop(settings, "tail_rotation_x_degrees")
        tail_rot.prop(settings, "tail_rotation_y_degrees")
        tail_rot.prop(settings, "tail_rotation_z_degrees")
        tail_rot.prop(settings, "tail_rotation_pivot")

        channels = layout.box()
        channels.label(text="Channels", icon="BONE_DATA")
        channels.prop(settings, "copy_bone_rotations")
        channels.prop(settings, "copy_bone_locations")
        channels.prop(settings, "copy_root_location")
        channels.prop(settings, "copy_root_rotation")
        channels.prop(settings, "copy_bone_scales")

        filters = layout.box()
        filters.label(text="Bone Filters", icon="FILTER")
        filters.prop(settings, "root_bone_tokens")
        filters.prop(settings, "include_jaw")
        filters.prop(settings, "include_fingers")
        filters.prop(settings, "jaw_bone_tokens")
        filters.prop(settings, "finger_bone_tokens")
        filters.prop(settings, "update_after_each_bone_matrix_set")

        manual = layout.box()
        manual.label(text="Manual Template", icon="OUTLINER_OB_MESH")
        manual.prop(settings, "manual_template_mode_when_rotated")
        manual.prop(settings, "template_display")
        manual.prop(settings, "template_opacity")
        manual.prop(settings, "manual_template_target_frame")
        manual.prop(settings, "computed_output_start_frame")
        manual.prop(settings, "computed_output_end_frame")
        manual.operator(
            GRAVITAS_OT_build_padding_and_template_v17.bl_idname,
            text="Build Padding + Template",
            icon="MOD_BUILD",
        )
        manual.operator(
            GRAVITAS_OT_finalize_manual_key_and_export_v17.bl_idname,
            text="Finalize Manual Key + Export",
            icon="EXPORT",
        )

        output = layout.box()
        output.label(text="Output", icon="ACTION")
        output.prop(settings, "output_action_name")
        output.prop(settings, "interpolation")
        output.prop(settings, "write_log_text")

        export = layout.box()
        export.label(text="Export", icon="EXPORT")
        export.prop(settings, "export_after_stitch")
        export.prop(settings, "export_path")
        export.prop(settings, "export_selected_only")

        layout.separator()

        layout.operator(
            GRAVITAS_OT_explicit_stitcher_build_v17.bl_idname,
            text="Build Explicit Head / Body / Tail Clip",
            icon="KEY_HLT",
        )

        layout.separator()

        help_box = layout.box()
        help_box.label(text="Important:")
        help_box.label(text="Select the top parent/group/empty.")
        help_box.label(text="Do NOT select bones.")
        help_box.label(text="The tool finds the nested Armature.")


# ============================================================
# Register
# ============================================================

classes = (
    GravitasExplicitStitcherSettingsV17,
    GRAVITAS_OT_explicit_stitcher_capture_body_range_v17,
    GRAVITAS_OT_build_padding_and_template_v17,
    GRAVITAS_OT_finalize_manual_key_and_export_v17,
    GRAVITAS_OT_explicit_stitcher_build_v17,
    GRAVITAS_PT_explicit_stitcher_panel_v17,
)


def register():
    _cleanup_old_gravitas_tools()

    for cls in classes:
        try:
            bpy.utils.register_class(cls)
        except ValueError:
            pass

    bpy.types.Scene.gravitas_explicit_stitcher_v17 = PointerProperty(
        type=GravitasExplicitStitcherSettingsV17
    )


def unregister():
    if hasattr(bpy.types.Scene, "gravitas_explicit_stitcher_v17"):
        try:
            del bpy.types.Scene.gravitas_explicit_stitcher_v17
        except Exception:
            pass

    for cls in reversed(classes):
        try:
            bpy.utils.unregister_class(cls)
        except Exception:
            pass


if __name__ == "__main__":
    try:
        unregister()
    except Exception:
        pass

    register()

    print("Gravitas Explicit Stitcher v1.7 registered.")
    print("[Gravitas] Nested-armature + Action Slots compatibility installed.")

    detected_armature = _find_armature_from_selection_or_parent(bpy.context)

    if detected_armature is not None:
        action = _ensure_action(detected_armature)
        bounds = _detected_action_bounds(action)
        fcurve_count = _action_fcurve_count(action)

        print("[Gravitas] Detected armature:", detected_armature.name)
        print("[Gravitas] Detected action:", action.name if action else "NONE")
        print("[Gravitas] Detected fcurves:", fcurve_count)
        print("[Gravitas] Detected frame bounds:", bounds)
    else:
        print("[Gravitas] Detected armature: NONE")

    print("Open 3D Viewport > N-panel > Gravitas > Explicit Stitcher v1.7.")

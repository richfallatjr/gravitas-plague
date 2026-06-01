# ============================================================
# Gravitas Plague - Pose Handoff USD Clip Stitcher
# Version: 1.2
#
# Paste into Blender Text Editor and Run Script.
#
# UI:
#   3D Viewport > press N > Gravitas > Pose Handoff
#
# NEW v1.2 feature:
#   Target Pose Rotation.
#
# This solves:
#   "I need turn 1 to transition into turn 2 by using the SAME
#    idle-turn-right.usdz file, but with the incoming target pose
#    virtually rotated 90 degrees."
#
# Turn 1 -> Turn 2 workflow:
#   1. Import/open idle-turn-right.usdz in Blender.
#   2. Select the CURRENT armature.
#   3. Run this script.
#   4. Open N-panel > Gravitas > Pose Handoff.
#   5. Next Clip File = idle-turn-right.usdz
#   6. Enable Target Rotation = ON
#   7. Target Rotation Z Degrees = 90
#   8. Copy Root Rotation = ON, or leave Force Root Rotation ON.
#   9. Export After Stitch = ON
#   10. Export Path = idle-turn-right_to_turn-right.usdz
#
# Blender vertical yaw axis = Z.
# RealityKit vertical yaw axis = Y.
#
# Defaults:
#   - Target rotation is OFF by default for normal transitions.
#   - For turn1 -> turn2, turn it ON and set Z = 90.
#   - Force Root Rotation For Target Rotation is ON by default because
#     the rotated target pose needs a root/global bone rotation key.
#
# ============================================================

bl_info = {
    "name": "Gravitas Pose Handoff USD Clip Stitcher",
    "author": "OpenAI / Gravitas Plague Pipeline",
    "version": (1, 2, 0),
    "blender": (4, 0, 0),
    "location": "3D Viewport > Sidebar > Gravitas > Pose Handoff",
    "description": "Append a pose-matching handoff tail to baked USD/USDZ animation clips, with optional rotated target pose sampling.",
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


# ============================================================
# Constants
# ============================================================

LOG_TEXT_BLOCK_NAME = "Gravitas_Pose_Handoff_Log"
TEMP_COLLECTION_NAME = "__GRAVITAS_TEMP_IMPORTED_NEXT_CLIP__"


# ============================================================
# General utilities
# ============================================================

def _split_tokens(raw):
    return [token.strip().lower() for token in raw.split(",") if token.strip()]


def _matches_any_token(name, tokens):
    lowered = name.lower()
    return any(token in lowered for token in tokens)


def _write_log(lines):
    text = bpy.data.texts.get(LOG_TEXT_BLOCK_NAME)

    if text is None:
        text = bpy.data.texts.new(LOG_TEXT_BLOCK_NAME)

    text.clear()
    text.write("\n".join(lines))


def _safe_report(operator, level, message):
    try:
        operator.report(level, message)
    except Exception:
        print(message)


def _force_object_mode():
    try:
        bpy.ops.object.mode_set(mode="OBJECT")
    except Exception:
        pass


def _call_operator_with_supported_kwargs(operator_proxy, **kwargs):
    """
    Blender operator signatures shift across versions.
    This filters kwargs to only whatever the current Blender build supports.
    """
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


def _get_active_or_selected_armature(context):
    obj = context.object

    if obj is not None:
        if obj.type == "ARMATURE":
            return obj

        if obj.parent is not None and obj.parent.type == "ARMATURE":
            return obj.parent

    for selected in context.selected_objects:
        if selected.type == "ARMATURE":
            return selected

    for selected in context.selected_objects:
        if selected.parent is not None and selected.parent.type == "ARMATURE":
            return selected.parent

    return None


def _ensure_action(armature):
    if armature is None:
        return None

    if armature.animation_data is None:
        return None

    return armature.animation_data.action


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
        if obj.name not in collection.objects:
            try:
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
        if armature.animation_data is not None
        and armature.animation_data.action is not None
    ]

    if animated:
        return animated[0]

    return armatures[0]


def _iter_descendants(obj):
    for child in obj.children:
        yield child
        yield from _iter_descendants(child)


def _select_armature_and_descendants(context, armature):
    _force_object_mode()

    bpy.ops.object.select_all(action="DESELECT")

    armature.select_set(True)

    for child in _iter_descendants(armature):
        child.select_set(True)

    context.view_layer.objects.active = armature


def _pose_bones_parent_first(armature):
    def depth(pose_bone):
        count = 0
        parent = pose_bone.parent

        while parent is not None:
            count += 1
            parent = parent.parent

        return count

    return sorted(list(armature.pose.bones), key=depth)


def _delete_temp_import(imported_objects, temp_collection, existing_action_names, log):
    for obj in list(imported_objects):
        if obj.name in bpy.data.objects:
            try:
                bpy.data.objects.remove(obj, do_unlink=True)
            except Exception:
                pass

    if temp_collection is not None and temp_collection.name in bpy.data.collections:
        try:
            bpy.data.collections.remove(temp_collection)
        except Exception:
            pass

    for action in list(bpy.data.actions):
        if action.name not in existing_action_names and action.users == 0:
            try:
                bpy.data.actions.remove(action)
            except Exception:
                pass

    log.append("Temporary imported next clip deleted.")


# ============================================================
# Rotation/key helpers
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


def _set_object_rotation_from_quaternion(obj, quat):
    quat = quat.copy()
    quat.normalize()

    if obj.rotation_mode == "QUATERNION":
        obj.rotation_quaternion = quat

    elif obj.rotation_mode == "AXIS_ANGLE":
        axis, angle = quat.to_axis_angle()
        obj.rotation_axis_angle[0] = angle
        obj.rotation_axis_angle[1] = axis.x
        obj.rotation_axis_angle[2] = axis.y
        obj.rotation_axis_angle[3] = axis.z

    else:
        obj.rotation_euler = quat.to_euler(obj.rotation_mode)


def _key_pose_bone_rotation(pose_bone, frame):
    if pose_bone.rotation_mode == "QUATERNION":
        pose_bone.keyframe_insert(data_path="rotation_quaternion", frame=frame)

    elif pose_bone.rotation_mode == "AXIS_ANGLE":
        pose_bone.keyframe_insert(data_path="rotation_axis_angle", frame=frame)

    else:
        pose_bone.keyframe_insert(data_path="rotation_euler", frame=frame)


def _key_object_rotation(obj, frame):
    if obj.rotation_mode == "QUATERNION":
        obj.keyframe_insert(data_path="rotation_quaternion", frame=frame)

    elif obj.rotation_mode == "AXIS_ANGLE":
        obj.keyframe_insert(data_path="rotation_axis_angle", frame=frame)

    else:
        obj.keyframe_insert(data_path="rotation_euler", frame=frame)


# ============================================================
# Bone/channel filter rules
# ============================================================

def _is_root_like_bone_name(bone_name, settings):
    tokens = _split_tokens(settings.root_bone_tokens)
    return _matches_any_token(bone_name, tokens)


def _should_include_bone_by_name(bone_name, settings):
    if not settings.include_jaw:
        jaw_tokens = _split_tokens(settings.jaw_bone_tokens)
        if _matches_any_token(bone_name, jaw_tokens):
            return False

    if not settings.include_fingers:
        finger_tokens = _split_tokens(settings.finger_bone_tokens)
        if _matches_any_token(bone_name, finger_tokens):
            return False

    return True


def _target_rotation_is_enabled(settings):
    if not settings.enable_target_pose_rotation:
        return False

    return (
        abs(settings.target_rotation_x_degrees) > 0.0001
        or abs(settings.target_rotation_y_degrees) > 0.0001
        or abs(settings.target_rotation_z_degrees) > 0.0001
    )


def _rotation_enabled_for_bone(bone_name, settings):
    if not settings.copy_bone_rotations:
        return False

    if _is_root_like_bone_name(bone_name, settings):
        if _target_rotation_is_enabled(settings) and settings.force_root_rotation_for_target_rotation:
            return True

        return settings.copy_root_rotation

    return True


def _location_enabled_for_bone(bone_name, settings):
    if _is_root_like_bone_name(bone_name, settings):
        return settings.copy_root_location

    return settings.copy_bone_locations


def _scale_enabled_for_bone(_bone_name, settings):
    return settings.copy_bone_scales


def _bone_has_any_enabled_channel(bone_name, settings):
    return (
        _rotation_enabled_for_bone(bone_name, settings)
        or _location_enabled_for_bone(bone_name, settings)
        or _scale_enabled_for_bone(bone_name, settings)
    )


def _key_pose_bone_enabled_channels(pose_bone, bone_name, settings, frame):
    if _location_enabled_for_bone(bone_name, settings):
        pose_bone.keyframe_insert(data_path="location", frame=frame)

    if _rotation_enabled_for_bone(bone_name, settings):
        _key_pose_bone_rotation(pose_bone, frame)

    if _scale_enabled_for_bone(bone_name, settings):
        pose_bone.keyframe_insert(data_path="scale", frame=frame)


def _key_object_enabled_channels(obj, settings, frame):
    if settings.copy_armature_object_location:
        obj.keyframe_insert(data_path="location", frame=frame)

    if settings.copy_armature_object_rotation:
        _key_object_rotation(obj, frame)

    if settings.copy_armature_object_scale:
        obj.keyframe_insert(data_path="scale", frame=frame)


# ============================================================
# Target pose rotation math
# ============================================================

def _rotation_matrix_from_xyz_degrees(x_degrees, y_degrees, z_degrees):
    """
    Blender axes:
      X = side axis
      Y = depth axis
      Z = vertical yaw axis

    For turn1 -> turn2:
      Use Z = 90.
    """
    rx = Matrix.Rotation(math.radians(x_degrees), 4, "X")
    ry = Matrix.Rotation(math.radians(y_degrees), 4, "Y")
    rz = Matrix.Rotation(math.radians(z_degrees), 4, "Z")

    # Apply yaw/vertical last in the usual intuitive order.
    return rz @ ry @ rx


def _pivot_point_for_target_rotation(current_armature, next_armature, settings):
    if settings.target_rotation_pivot == "CURRENT_ARMATURE_ORIGIN":
        return current_armature.matrix_world.translation.copy()

    if settings.target_rotation_pivot == "NEXT_ARMATURE_ORIGIN":
        return next_armature.matrix_world.translation.copy()

    if settings.target_rotation_pivot == "WORLD_ORIGIN":
        return Vector((0, 0, 0))

    return current_armature.matrix_world.translation.copy()


def _target_pose_rotation_matrix(current_armature, next_armature, settings):
    if not _target_rotation_is_enabled(settings):
        return Matrix.Identity(4)

    pivot = _pivot_point_for_target_rotation(
        current_armature=current_armature,
        next_armature=next_armature,
        settings=settings,
    )

    rotation = _rotation_matrix_from_xyz_degrees(
        settings.target_rotation_x_degrees,
        settings.target_rotation_y_degrees,
        settings.target_rotation_z_degrees,
    )

    return Matrix.Translation(pivot) @ rotation @ Matrix.Translation(-pivot)


# ============================================================
# USD import/export
# ============================================================

def _import_next_clip(context, filepath, log):
    if not os.path.isfile(filepath):
        raise FileNotFoundError(f"Next clip file does not exist: {filepath}")

    existing_object_names = set(bpy.data.objects.keys())
    existing_action_names = set(bpy.data.actions.keys())

    log.append(f"Importing next clip: {filepath}")

    _call_operator_with_supported_kwargs(
        bpy.ops.wm.usd_import,
        filepath=filepath,
        import_cameras=False,
        import_lights=False,
        import_materials=True,
        import_meshes=True,
        import_skeletons=True,
        import_blendshapes=True,
        read_meshes=True,
        read_animation=True,
        set_frame_range=True,
    )

    imported_objects = [
        obj
        for obj in bpy.data.objects
        if obj.name not in existing_object_names
    ]

    if not imported_objects:
        raise RuntimeError("USD import completed, but no new objects were detected.")

    temp_collection = _create_or_replace_temp_collection(context)
    _link_objects_to_collection(imported_objects, temp_collection)

    log.append(f"Imported {len(imported_objects)} temporary objects.")

    return imported_objects, temp_collection, existing_action_names



def _export_stitched_clip(context, filepath, selected_only, current_armature, log):
    if not filepath:
        raise RuntimeError("Export After Stitch is enabled, but Export Path is empty.")

    export_dir = os.path.dirname(filepath)

    if export_dir and not os.path.isdir(export_dir):
        os.makedirs(export_dir, exist_ok=True)

    active_name, selected_names = _stash_selection(context)

    try:
        if selected_only:
            _select_armature_and_descendants(context, current_armature)

        log.append(f"Exporting stitched clip: {filepath}")

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
            evaluation_mode="RENDER",
            frame_start=context.scene.frame_start,
            frame_end=context.scene.frame_end,
            start_frame=context.scene.frame_start,
            end_frame=context.scene.frame_end,
        )

    finally:
        _restore_selection(context, active_name, selected_names)


# ============================================================
# Sampling/applying pose data
# ============================================================

def _sample_next_object_transform(next_armature, current_armature, settings, target_rotation_matrix, log):
    original_world = next_armature.matrix_world.copy()
    rotated_world = target_rotation_matrix @ original_world

    location, rotation, scale = rotated_world.decompose()

    if _target_rotation_is_enabled(settings):
        log.append(
            "Sampled imported armature object transform WITH target pose rotation "
            f"X={settings.target_rotation_x_degrees}, "
            f"Y={settings.target_rotation_y_degrees}, "
            f"Z={settings.target_rotation_z_degrees}."
        )
    else:
        log.append("Sampled imported armature object transform without target rotation.")

    return {
        "location": location.copy(),
        "rotation": rotation.copy(),
        "scale": scale.copy(),
        "matrix_world": rotated_world.copy(),
    }


def _apply_object_sample(current_armature, object_sample, settings):
    if settings.copy_armature_object_location:
        current_armature.location = object_sample["location"]

    if settings.copy_armature_object_rotation:
        _set_object_rotation_from_quaternion(
            current_armature,
            object_sample["rotation"],
        )

    if settings.copy_armature_object_scale:
        current_armature.scale = object_sample["scale"]


def _sample_next_pose(current_armature, next_armature, source_frame, settings, target_rotation_matrix, log):
    """
    The important bit:
      target_world_matrix = target_rotation_matrix @ next_armature.matrix_world @ next_pose_bone.matrix

    That means the incoming/next pose can be virtually rotated before we copy it.
    For turn1 -> turn2:
      next clip file = same idle-turn-right.usdz
      target_rotation_z_degrees = 90
    """
    scene = bpy.context.scene
    scene.frame_set(source_frame)
    bpy.context.view_layer.update()

    sample_by_bone = {}

    use_world_target = (
        settings.sample_space == "WORLD_VISUAL"
        or _target_rotation_is_enabled(settings)
    )

    for next_pose_bone in next_armature.pose.bones:
        bone_name = next_pose_bone.name

        if not _should_include_bone_by_name(bone_name, settings):
            continue

        if use_world_target:
            target_world_matrix = (
                target_rotation_matrix
                @ next_armature.matrix_world
                @ next_pose_bone.matrix
            )

            location, rotation, scale = target_world_matrix.decompose()

            sample_by_bone[bone_name] = {
                "location": location.copy(),
                "rotation": rotation.copy(),
                "scale": scale.copy(),
                "matrix_basis": None,
                "target_world_matrix": target_world_matrix.copy(),
            }

        else:
            matrix_basis = next_pose_bone.matrix_basis.copy()
            location, rotation, scale = matrix_basis.decompose()

            sample_by_bone[bone_name] = {
                "location": location.copy(),
                "rotation": rotation.copy(),
                "scale": scale.copy(),
                "matrix_basis": matrix_basis.copy(),
                "target_world_matrix": None,
            }

    mode_text = "WORLD_VISUAL_ROTATED" if use_world_target else "LOCAL_BASIS"

    log.append(
        f"Sampled {len(sample_by_bone)} pose bones from next clip at frame {source_frame} "
        f"using {mode_text}."
    )

    return sample_by_bone


def _restore_disabled_channels(
    pose_bone,
    bone_name,
    settings,
    old_location,
    old_rotation_mode,
    old_rotation_euler,
    old_rotation_quaternion,
    old_rotation_axis_angle,
    old_scale,
):
    if not _location_enabled_for_bone(bone_name, settings):
        pose_bone.location = old_location

    if not _rotation_enabled_for_bone(bone_name, settings):
        pose_bone.rotation_mode = old_rotation_mode

        if pose_bone.rotation_mode == "QUATERNION":
            pose_bone.rotation_quaternion = old_rotation_quaternion

        elif pose_bone.rotation_mode == "AXIS_ANGLE":
            for index in range(4):
                pose_bone.rotation_axis_angle[index] = old_rotation_axis_angle[index]

        else:
            pose_bone.rotation_euler = old_rotation_euler

    if not _scale_enabled_for_bone(bone_name, settings):
        pose_bone.scale = old_scale


def _apply_pose_sample_to_bone(current_armature, pose_bone, bone_name, sample_data, settings):
    old_location = pose_bone.location.copy()
    old_rotation_mode = pose_bone.rotation_mode
    old_rotation_euler = pose_bone.rotation_euler.copy()
    old_rotation_quaternion = pose_bone.rotation_quaternion.copy()
    old_rotation_axis_angle = pose_bone.rotation_axis_angle[:]
    old_scale = pose_bone.scale.copy()

    use_world_target = sample_data["target_world_matrix"] is not None

    if use_world_target:
        target_world_matrix = sample_data["target_world_matrix"]
        target_armature_space = current_armature.matrix_world.inverted() @ target_world_matrix

        try:
            pose_bone.matrix = target_armature_space
        except Exception:
            _, rotation, scale = target_armature_space.decompose()

            if _rotation_enabled_for_bone(bone_name, settings):
                _set_pose_bone_rotation_from_quaternion(pose_bone, rotation)

            if _scale_enabled_for_bone(bone_name, settings):
                pose_bone.scale = scale

    else:
        if _location_enabled_for_bone(bone_name, settings):
            pose_bone.location = sample_data["location"]

        if _rotation_enabled_for_bone(bone_name, settings):
            _set_pose_bone_rotation_from_quaternion(
                pose_bone,
                sample_data["rotation"],
            )

        if _scale_enabled_for_bone(bone_name, settings):
            pose_bone.scale = sample_data["scale"]

    _restore_disabled_channels(
        pose_bone=pose_bone,
        bone_name=bone_name,
        settings=settings,
        old_location=old_location,
        old_rotation_mode=old_rotation_mode,
        old_rotation_euler=old_rotation_euler,
        old_rotation_quaternion=old_rotation_quaternion,
        old_rotation_axis_angle=old_rotation_axis_angle,
        old_scale=old_scale,
    )


def _insert_boundary_pose_keys(current_armature, matched_bones, settings, frame, log):
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()

    _key_object_enabled_channels(current_armature, settings, frame)

    for bone_name in matched_bones:
        pose_bone = current_armature.pose.bones[bone_name]

        _key_pose_bone_enabled_channels(
            pose_bone=pose_bone,
            bone_name=bone_name,
            settings=settings,
            frame=frame,
        )

    log.append(f"Inserted current boundary pose keys at frame {frame}.")


def _apply_target_pose_and_key(
    current_armature,
    matched_bones,
    sample_by_bone,
    object_sample,
    settings,
    frame,
    log,
    label,
):
    bpy.context.scene.frame_set(frame)

    _apply_object_sample(current_armature, object_sample, settings)
    bpy.context.view_layer.update()

    # Parent-first matters when setting pose_bone.matrix.
    for pose_bone in _pose_bones_parent_first(current_armature):
        bone_name = pose_bone.name

        if bone_name not in matched_bones:
            continue

        sample_data = sample_by_bone[bone_name]

        _apply_pose_sample_to_bone(
            current_armature=current_armature,
            pose_bone=pose_bone,
            bone_name=bone_name,
            sample_data=sample_data,
            settings=settings,
        )

        if settings.update_after_each_bone_matrix_set:
            bpy.context.view_layer.update()

    bpy.context.view_layer.update()

    _key_object_enabled_channels(current_armature, settings, frame)

    for bone_name in matched_bones:
        pose_bone = current_armature.pose.bones[bone_name]

        _key_pose_bone_enabled_channels(
            pose_bone=pose_bone,
            bone_name=bone_name,
            settings=settings,
            frame=frame,
        )

    log.append(f"Applied and keyed {label} at frame {frame}.")


def _set_transition_interpolation(action, start_frame, end_frame, interpolation, log):
    if action is None:
        return

    changed = 0

    for fcurve in action.fcurves:
        for keyframe in fcurve.keyframe_points:
            frame = keyframe.co.x

            if start_frame <= frame <= end_frame:
                keyframe.interpolation = interpolation
                changed += 1

    log.append(
        f"Set interpolation '{interpolation}' on {changed} keyframes "
        f"between frames {start_frame} and {end_frame}."
    )

def _force_scene_and_action_frame_range(context, action, start_frame, end_frame, log):
    scene = context.scene

    scene.frame_start = int(start_frame)
    scene.frame_end = int(end_frame)
    scene.frame_set(int(start_frame))

    if action is not None:
        if hasattr(action, "use_frame_range"):
            action.use_frame_range = True

        if hasattr(action, "frame_start"):
            action.frame_start = float(start_frame)

        if hasattr(action, "frame_end"):
            action.frame_end = float(end_frame)

    bpy.context.view_layer.update()

    log.append(
        f"Forced export frame range: start={scene.frame_start}, end={scene.frame_end}"
    )


# ============================================================
# Settings
# ============================================================

class GravitasPoseHandoffSettings(PropertyGroup):
    next_clip_path: StringProperty(
        name="Next Clip File",
        description="Incoming USD/USDZ/USDC file. For turn1 -> turn2, use the same idle-turn-right.usdz file.",
        subtype="FILE_PATH",
        default="",
    )

    next_source_frame: IntProperty(
        name="Next Source Frame",
        description="Frame from the next clip to sample. Usually 1.",
        default=1,
        min=-100000,
        max=100000,
    )

    transition_frames: IntProperty(
        name="Transition Frames",
        description="Number of frames appended after the current clip end.",
        default=5,
        min=1,
        max=240,
    )

    hold_frames: IntProperty(
        name="Hold Frames",
        description="Extra matching-pose frames after the handoff target frame.",
        default=1,
        min=0,
        max=120,
    )

    current_end_frame_override: IntProperty(
        name="Current End Override",
        description="0 uses the active action's end frame. Non-zero forces this frame as the current clip end.",
        default=0,
        min=0,
        max=100000,
    )

    sample_space: EnumProperty(
        name="Sample Space",
        description="How the incoming pose is sampled. Target rotation automatically forces world-visual sampling.",
        items=[
            (
                "LOCAL_BASIS",
                "Local Bone Pose",
                "Copy local bone pose. Best for normal unrotated transitions from the same rig.",
            ),
            (
                "WORLD_VISUAL",
                "World Visual Pose",
                "Copy world-space visual bone pose. Required for rotated target-pose stitching.",
            ),
        ],
        default="LOCAL_BASIS",
    )

    enable_target_pose_rotation: BoolProperty(
        name="Enable Target Rotation",
        description="Virtually rotate the incoming/next pose before stitching into it.",
        default=False,
    )

    target_rotation_x_degrees: FloatProperty(
        name="Target Rotation X Degrees",
        description="Virtual rotation applied to the incoming target pose around Blender X.",
        default=0.0,
        min=-3600.0,
        max=3600.0,
    )

    target_rotation_y_degrees: FloatProperty(
        name="Target Rotation Y Degrees",
        description="Virtual rotation applied to the incoming target pose around Blender Y.",
        default=0.0,
        min=-3600.0,
        max=3600.0,
    )

    target_rotation_z_degrees: FloatProperty(
        name="Target Rotation Z Degrees",
        description="Virtual yaw rotation around Blender Z. For turn1 -> turn2, use 90.",
        default=90.0,
        min=-3600.0,
        max=3600.0,
    )

    target_rotation_pivot: EnumProperty(
        name="Rotation Pivot",
        description="Pivot used for the virtual incoming pose rotation.",
        items=[
            (
                "CURRENT_ARMATURE_ORIGIN",
                "Current Armature Origin",
                "Usually best. Rotates target around the current character origin.",
            ),
            (
                "NEXT_ARMATURE_ORIGIN",
                "Next Armature Origin",
                "Rotates target around the imported next armature origin.",
            ),
            (
                "WORLD_ORIGIN",
                "World Origin",
                "Rotates target around world zero.",
            ),
        ],
        default="CURRENT_ARMATURE_ORIGIN",
    )

    force_root_rotation_for_target_rotation: BoolProperty(
        name="Force Root Rotation For Target Rotation",
        description="When target rotation is enabled, force root/global bones to receive rotation keys even if Copy Root Rotation is off.",
        default=True,
    )

    update_after_each_bone_matrix_set: BoolProperty(
        name="Update After Each Bone Matrix Set",
        description="Slower but can be more stable for hierarchical world-space pose assignment.",
        default=False,
    )

    make_action_copy: BoolProperty(
        name="Duplicate Current Action First",
        description="Non-destructive mode. Creates a duplicate action and stitches the duplicate.",
        default=True,
    )

    output_action_name: StringProperty(
        name="Output Action Name",
        description="Optional name for the duplicated/stiched action.",
        default="",
    )

    make_fake_user: BoolProperty(
        name="Fake User On Output Action",
        description="Preserve the stitched action in the .blend even if it is not assigned later.",
        default=True,
    )

    copy_bone_rotations: BoolProperty(
        name="Copy Bone Rotations",
        description="Copy matched bone rotations from the next clip.",
        default=True,
    )

    copy_bone_locations: BoolProperty(
        name="Copy Local Bone Locations",
        description="Copy non-root local bone translations. Leave OFF first for Phase 1.",
        default=False,
    )

    copy_root_location: BoolProperty(
        name="Copy Root Location",
        description="Usually OFF. Swift/RealityKit owns world translation.",
        default=False,
    )

    copy_root_rotation: BoolProperty(
        name="Copy Root Rotation",
        description="Usually OFF for normal transitions. For rotated target transitions, Force Root Rotation handles this automatically.",
        default=False,
    )

    copy_bone_scales: BoolProperty(
        name="Copy Bone Scales",
        description="Usually OFF.",
        default=False,
    )

    copy_armature_object_location: BoolProperty(
        name="Copy Armature Object Location",
        description="Usually OFF.",
        default=False,
    )

    copy_armature_object_rotation: BoolProperty(
        name="Copy Armature Object Rotation",
        description="Usually OFF. Prefer Force Root Rotation for target-pose rotation.",
        default=False,
    )

    copy_armature_object_scale: BoolProperty(
        name="Copy Armature Object Scale",
        description="Usually OFF.",
        default=False,
    )

    include_jaw: BoolProperty(
        name="Include Jaw",
        description="Include jaw bones if present.",
        default=True,
    )

    include_fingers: BoolProperty(
        name="Include Fingers",
        description="Include finger/thumb bones if present.",
        default=True,
    )

    root_bone_tokens: StringProperty(
        name="Root Bone Tokens",
        description="Comma-separated tokens used to identify root/global bones.",
        default="root,global,master,armature,hips,pelvis",
    )

    jaw_bone_tokens: StringProperty(
        name="Jaw Bone Tokens",
        description="Comma-separated tokens used to identify jaw bones.",
        default="jaw",
    )

    finger_bone_tokens: StringProperty(
        name="Finger Bone Tokens",
        description="Comma-separated tokens used to identify finger/thumb bones.",
        default="finger,thumb,index,middle,ring,pinky",
    )

    interpolation: EnumProperty(
        name="Interpolation",
        description="Interpolation applied to transition keyframes.",
        items=[
            ("BEZIER", "Bezier", "Smooth handoff."),
            ("LINEAR", "Linear", "Constant-speed handoff."),
            ("CONSTANT", "Constant", "Debug only; creates a pose jump."),
        ],
        default="BEZIER",
    )

    cleanup_imported: BoolProperty(
        name="Delete Temporary Import",
        description="Delete the imported next clip after sampling.",
        default=True,
    )

    set_scene_range: BoolProperty(
        name="Set Scene Range",
        description="Extend scene frame_end to include the stitched transition.",
        default=True,
    )

    write_log_text: BoolProperty(
        name="Write Log Text Block",
        description=f"Write operation details to a Blender text block named {LOG_TEXT_BLOCK_NAME}.",
        default=True,
    )

    export_after_stitch: BoolProperty(
        name="Export After Stitch",
        description="Export immediately after stitching.",
        default=False,
    )

    export_path: StringProperty(
        name="Export Path",
        description="Output USD/USDZ/USDC path.",
        subtype="FILE_PATH",
        default="",
    )

    export_selected_only: BoolProperty(
        name="Export Current Armature + Children Only",
        description="Recommended ON. Exports only the selected current armature hierarchy.",
        default=True,
    )


# ============================================================
# Main operator
# ============================================================

class GRAVITAS_OT_pose_handoff_stitch(Operator):
    bl_idname = "gravitas.pose_handoff_stitch"
    bl_label = "Stitch Handoff Tail"
    bl_description = "Append a pose-matching handoff tail to the selected current armature/action."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_pose_handoff

        log = []
        success = False

        imported_objects = []
        temp_collection = None
        existing_action_names = set(bpy.data.actions.keys())

        active_name, selected_names = _stash_selection(context)

        try:
            _force_object_mode()

            log.append("============================================================")
            log.append("Gravitas Pose Handoff / USD Clip Stitcher v1.2")
            log.append("============================================================")

            current_armature = _get_active_or_selected_armature(context)

            if current_armature is None:
                raise RuntimeError(
                    "Select the CURRENT clip armature first. "
                    "The active object must be an Armature or a mesh parented to an Armature."
                )

            current_action = _ensure_action(current_armature)

            if current_action is None:
                raise RuntimeError(
                    f"Current armature '{current_armature.name}' has no active animation action."
                )

            next_clip_path = bpy.path.abspath(settings.next_clip_path)

            if not next_clip_path:
                raise RuntimeError("Choose a Next Clip File before running the tool.")

            log.append(f"Current armature: {current_armature.name}")
            log.append(f"Current action: {current_action.name}")
            log.append(f"Next clip path: {next_clip_path}")

            if settings.make_action_copy:
                current_armature.animation_data_create()

                action_copy = current_action.copy()

                if settings.output_action_name.strip():
                    action_copy.name = settings.output_action_name.strip()
                else:
                    action_copy.name = f"{current_action.name}_handoff"

                current_armature.animation_data.action = action_copy
                current_action = action_copy

                log.append(f"Duplicated current action. Output action: {current_action.name}")
            else:
                log.append("Destructive mode: editing current action directly.")

            if settings.make_fake_user:
                current_action.use_fake_user = True
                log.append("Enabled fake user on output action.")

            if settings.current_end_frame_override > 0:
                current_end_frame = settings.current_end_frame_override
                log.append(f"Using current end override frame: {current_end_frame}")
            else:
                current_end_frame = int(math.ceil(current_action.frame_range[1]))
                log.append(f"Detected current action end frame: {current_end_frame}")

            target_frame = current_end_frame + settings.transition_frames
            final_hold_frame = target_frame + settings.hold_frames

            imported_objects, temp_collection, existing_action_names = _import_next_clip(
                context=context,
                filepath=next_clip_path,
                log=log,
            )

            next_armature = _find_first_imported_armature(imported_objects)

            if next_armature is None:
                raise RuntimeError(
                    "No editable Armature was found in the imported next clip. "
                    "If the USD imports as only a mesh cache or non-editable USD skeleton, "
                    "use an FBX/editable-rig source for this cleanup pass, then export USDZ again."
                )

            log.append(f"Imported next armature: {next_armature.name}")

            if _target_rotation_is_enabled(settings):
                log.append("")
                log.append("TARGET POSE ROTATION ENABLED")
                log.append(
                    "The next clip's sampled pose will be virtually rotated before stitching."
                )
                log.append(
                    f"Target rotation degrees: "
                    f"X={settings.target_rotation_x_degrees}, "
                    f"Y={settings.target_rotation_y_degrees}, "
                    f"Z={settings.target_rotation_z_degrees}"
                )
                log.append(f"Rotation pivot: {settings.target_rotation_pivot}")

                if settings.force_root_rotation_for_target_rotation:
                    log.append(
                        "Root/global bone rotation will be forced ON for this target rotation."
                    )

            target_rotation_matrix = _target_pose_rotation_matrix(
                current_armature=current_armature,
                next_armature=next_armature,
                settings=settings,
            )

            sample_by_bone = _sample_next_pose(
                current_armature=current_armature,
                next_armature=next_armature,
                source_frame=settings.next_source_frame,
                settings=settings,
                target_rotation_matrix=target_rotation_matrix,
                log=log,
            )

            object_sample = _sample_next_object_transform(
                next_armature=next_armature,
                current_armature=current_armature,
                settings=settings,
                target_rotation_matrix=target_rotation_matrix,
                log=log,
            )

            current_bone_names = set(pb.name for pb in current_armature.pose.bones)
            next_sample_names = set(sample_by_bone.keys())

            matched_bones = []

            for pose_bone in _pose_bones_parent_first(current_armature):
                bone_name = pose_bone.name

                if bone_name not in next_sample_names:
                    continue

                if not _should_include_bone_by_name(bone_name, settings):
                    continue

                if not _bone_has_any_enabled_channel(bone_name, settings):
                    continue

                matched_bones.append(bone_name)

            if not matched_bones:
                raise RuntimeError(
                    "No matching keyed bones found. "
                    "The current and next rigs must have exact matching bone names, "
                    "and at least one enabled channel must be active."
                )

            missing_from_current = sorted(next_sample_names - current_bone_names)
            missing_from_next = sorted(current_bone_names - next_sample_names)

            log.append(f"Matched keyed bones: {len(matched_bones)}")

            if missing_from_current:
                log.append("")
                log.append("Bones present in NEXT clip but missing from CURRENT rig:")
                for name in missing_from_current[:250]:
                    log.append(f"  - {name}")
                if len(missing_from_current) > 250:
                    log.append(f"  ...and {len(missing_from_current) - 250} more")

            if missing_from_next:
                log.append("")
                log.append("Bones present in CURRENT rig but missing from NEXT clip sample:")
                for name in missing_from_next[:250]:
                    log.append(f"  - {name}")
                if len(missing_from_next) > 250:
                    log.append(f"  ...and {len(missing_from_next) - 250} more")

            if settings.copy_root_location:
                log.append("")
                log.append("WARNING: Copy Root Location is ON. This can fight Swift/RealityKit root movement.")

            _insert_boundary_pose_keys(
                current_armature=current_armature,
                matched_bones=matched_bones,
                settings=settings,
                frame=current_end_frame,
                log=log,
            )

            _apply_target_pose_and_key(
                current_armature=current_armature,
                matched_bones=matched_bones,
                sample_by_bone=sample_by_bone,
                object_sample=object_sample,
                settings=settings,
                frame=target_frame,
                log=log,
                label="next-clip target pose",
            )

            if settings.hold_frames > 0:
                _apply_target_pose_and_key(
                    current_armature=current_armature,
                    matched_bones=matched_bones,
                    sample_by_bone=sample_by_bone,
                    object_sample=object_sample,
                    settings=settings,
                    frame=final_hold_frame,
                    log=log,
                    label="matching hold pose",
                )
            else:
                final_hold_frame = target_frame
                log.append("No hold frame requested.")

            _set_transition_interpolation(
                action=current_action,
                start_frame=current_end_frame,
                end_frame=final_hold_frame,
                interpolation=settings.interpolation,
                log=log,
            )

            if settings.set_scene_range:
                context.scene.frame_end = max(context.scene.frame_end, final_hold_frame)
                log.append(f"Scene frame_end set to {context.scene.frame_end}.")

            if settings.cleanup_imported:
                _delete_temp_import(
                    imported_objects=imported_objects,
                    temp_collection=temp_collection,
                    existing_action_names=existing_action_names,
                    log=log,
                )
                imported_objects = []
                temp_collection = None

            if settings.export_after_stitch:
                export_path = bpy.path.abspath(settings.export_path)

                _force_scene_and_action_frame_range(
                    context=context,
                    action=current_action,
                    start_frame=1,
                    end_frame=final_hold_frame,
                    log=log,
                )

                _export_stitched_clip(
                    context=context,
                    filepath=export_path,
                    selected_only=settings.export_selected_only,
                    current_armature=current_armature,
                    log=log,
                )

            context.scene.frame_set(current_end_frame)
            bpy.context.view_layer.update()

            log.append("")
            log.append("SUCCESS")
            log.append(f"Output action: {current_action.name}")
            log.append(f"Handoff start frame: {current_end_frame}")
            log.append(f"Next pose target frame: {target_frame}")
            log.append(f"Final hold frame: {final_hold_frame}")
            log.append(f"Matched keyed bones: {len(matched_bones)}")
            log.append("============================================================")

            success = True

            _safe_report(
                self,
                {"INFO"},
                f"Stitched handoff: {len(matched_bones)} bones, "
                f"frames {current_end_frame}->{final_hold_frame}.",
            )

        except Exception as error:
            log.append("")
            log.append("ERROR")
            log.append(str(error))
            log.append("")
            log.append(traceback.format_exc())

            _safe_report(self, {"ERROR"}, str(error))

        finally:
            if imported_objects and settings.cleanup_imported:
                try:
                    _delete_temp_import(
                        imported_objects=imported_objects,
                        temp_collection=temp_collection,
                        existing_action_names=existing_action_names,
                        log=log,
                    )
                except Exception:
                    log.append("")
                    log.append("WARNING: Temporary import cleanup failed.")
                    log.append(traceback.format_exc())

            _restore_selection(context, active_name, selected_names)

            if settings.write_log_text:
                _write_log(log)

        return {"FINISHED"} if success else {"CANCELLED"}


# ============================================================
# UI panel
# ============================================================

class GRAVITAS_PT_pose_handoff_panel(Panel):
    bl_label = "Pose Handoff"
    bl_idname = "GRAVITAS_PT_pose_handoff_panel"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Gravitas"

    def draw(self, context):
        layout = self.layout
        settings = context.scene.gravitas_pose_handoff

        current_armature = _get_active_or_selected_armature(context)
        current_action = _ensure_action(current_armature) if current_armature else None

        status_box = layout.box()
        status_box.label(text="Current Clip", icon="ARMATURE_DATA")

        if current_armature is not None:
            status_box.label(text=f"Armature: {current_armature.name}")
        else:
            status_box.label(text="Armature: none selected", icon="ERROR")

        if current_action is not None:
            status_box.label(text=f"Action: {current_action.name}")
            status_box.label(
                text=(
                    f"Range: {current_action.frame_range[0]:.0f}"
                    f" - {current_action.frame_range[1]:.0f}"
                )
            )
        else:
            status_box.label(text="Action: none", icon="ERROR")

        layout.separator()

        source_box = layout.box()
        source_box.label(text="Incoming / Next Clip", icon="FILE_FOLDER")
        source_box.prop(settings, "next_clip_path")
        source_box.prop(settings, "next_source_frame")
        source_box.prop(settings, "sample_space")

        target_box = layout.box()
        target_box.label(text="Target Pose Rotation", icon="ORIENTATION_GIMBAL")
        target_box.prop(settings, "enable_target_pose_rotation")
        target_box.prop(settings, "target_rotation_x_degrees")
        target_box.prop(settings, "target_rotation_y_degrees")
        target_box.prop(settings, "target_rotation_z_degrees")
        target_box.prop(settings, "target_rotation_pivot")
        target_box.prop(settings, "force_root_rotation_for_target_rotation")
        target_box.prop(settings, "update_after_each_bone_matrix_set")

        timing_box = layout.box()
        timing_box.label(text="Handoff Timing", icon="TIME")
        timing_box.prop(settings, "transition_frames")
        timing_box.prop(settings, "hold_frames")
        timing_box.prop(settings, "current_end_frame_override")
        timing_box.prop(settings, "interpolation")

        action_box = layout.box()
        action_box.label(text="Action Safety", icon="ACTION")
        action_box.prop(settings, "make_action_copy")
        action_box.prop(settings, "output_action_name")
        action_box.prop(settings, "make_fake_user")
        action_box.prop(settings, "set_scene_range")

        channels_box = layout.box()
        channels_box.label(text="Bone Channels", icon="BONE_DATA")
        channels_box.prop(settings, "copy_bone_rotations")
        channels_box.prop(settings, "copy_bone_locations")
        channels_box.prop(settings, "copy_root_location")
        channels_box.prop(settings, "copy_root_rotation")
        channels_box.prop(settings, "copy_bone_scales")

        object_box = layout.box()
        object_box.label(text="Armature Object Transform", icon="OBJECT_ORIGIN")
        object_box.prop(settings, "copy_armature_object_location")
        object_box.prop(settings, "copy_armature_object_rotation")
        object_box.prop(settings, "copy_armature_object_scale")

        filters_box = layout.box()
        filters_box.label(text="Bone Filters", icon="FILTER")
        filters_box.prop(settings, "include_jaw")
        filters_box.prop(settings, "include_fingers")
        filters_box.prop(settings, "root_bone_tokens")
        filters_box.prop(settings, "jaw_bone_tokens")
        filters_box.prop(settings, "finger_bone_tokens")

        cleanup_box = layout.box()
        cleanup_box.label(text="Cleanup / Logging", icon="TRASH")
        cleanup_box.prop(settings, "cleanup_imported")
        cleanup_box.prop(settings, "write_log_text")

        export_box = layout.box()
        export_box.label(text="Optional Export", icon="EXPORT")
        export_box.prop(settings, "export_after_stitch")
        export_box.prop(settings, "export_path")
        export_box.prop(settings, "export_selected_only")

        layout.separator()

        layout.operator(
            GRAVITAS_OT_pose_handoff_stitch.bl_idname,
            text="Stitch Handoff Tail",
            icon="KEY_HLT",
        )

        layout.separator()

        help_box = layout.box()
        help_box.label(text="Turn1 -> Turn2 settings:")
        help_box.label(text="Next Clip = same turn USDZ")
        help_box.label(text="Enable Target Rotation = ON")
        help_box.label(text="Target Rotation Z = 90")


# ============================================================
# Registration
# ============================================================

classes = (
    GravitasPoseHandoffSettings,
    GRAVITAS_OT_pose_handoff_stitch,
    GRAVITAS_PT_pose_handoff_panel,
)


def register():
    for cls in classes:
        try:
            bpy.utils.register_class(cls)
        except ValueError:
            pass

    bpy.types.Scene.gravitas_pose_handoff = PointerProperty(
        type=GravitasPoseHandoffSettings
    )


def unregister():
    if hasattr(bpy.types.Scene, "gravitas_pose_handoff"):
        try:
            del bpy.types.Scene.gravitas_pose_handoff
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

    print("Gravitas Pose Handoff Tool v1.2 registered.")
    print("Open 3D Viewport > N-panel/sidebar > Gravitas > Pose Handoff.")

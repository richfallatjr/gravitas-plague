# ============================================================
# Gravitas Plague - Animation Library Tool
# Version: 2.0
#
# Purpose:
#   Extract animation donor poses from USDZ/USD/USDC/FBX and export
#   JockAnim sidecar clips into AnimationLibrary/Clips.
#
# Output:
#   .jockanim.json
#   AnimationLibrary/Manifests/animation_library_manifest.json
#
# This tool does NOT stitch clips.
# This tool does NOT export character USDZs.
# This tool does NOT solve IK.
# This tool only samples local joint transforms and writes sidecar data.
# ============================================================

bl_info = {
    "name": "Gravitas Animation Library Tool",
    "author": "OpenAI / Gravitas Plague Pipeline",
    "version": (2, 0, 0),
    "blender": (4, 0, 0),
    "location": "3D Viewport > Sidebar > Gravitas > Animation Library",
    "description": "Extracts donor animation clips into Gravitas JockAnim sidecar JSON files.",
    "category": "Animation",
}

import bpy
import hashlib
import json
import math
import mathutils
import os
import re
import traceback
from datetime import datetime, timezone

from bpy.props import (
    BoolProperty,
    CollectionProperty,
    EnumProperty,
    FloatProperty,
    IntProperty,
    PointerProperty,
    StringProperty,
)
from bpy.types import Operator, Panel, PropertyGroup


TEMP_COLLECTION_NAME = "__GRAVITAS_ANIMATION_DONOR_TEMP__"
TARGET_COLLECTION_NAME = "__GRAVITAS_TARGET_CHARACTER_TEMP__"
LOG_TEXT_BLOCK_NAME = "Gravitas_Animation_Library_Log"

DEFAULT_PROJECT_ROOT = os.path.expanduser(
    "/Users/richardfallat/Projects/dev/gravitas-plague"
)
DEFAULT_ANIMATION_LIBRARY_ROOT = os.path.join(
    DEFAULT_PROJECT_ROOT,
    "Gravitas Plague",
    "Gravitas Plague",
    "AnimationLibrary",
)
DEFAULT_RIG_JSON_PATH = os.path.join(
    DEFAULT_ANIMATION_LIBRARY_ROOT,
    "Rigs",
    "GravitasMeshyBiped24_v001.rig.json",
)
DEFAULT_SKELETON_MAP_PATH = os.path.join(
    DEFAULT_ANIMATION_LIBRARY_ROOT,
    "SkeletonMaps",
    "MeshyBiped24_identity.map.json",
)
SOURCE_RIGS_FOLDER_NAME = "SourceRigs"
SOURCE_RIG_REGISTRY_FILENAME = "source_rig_registry.json"
DEFAULT_DAD_SOURCE_CHARACTER_ID = "dad_biped"
DEFAULT_SOURCE_RIG_SCHEMA = "com.gravitas.source_rig.v0"
DEFAULT_SOURCE_RIG_REGISTRY_SCHEMA = "com.gravitas.source_rig_registry.v0"

MANIFEST_CLIP_ENUM_CACHE = []
MANIFEST_CLIP_SUMMARY_BY_ID = {}

MESHY_BIPED24_MIRROR_PAIRS = {
    "LeftUpLeg": "RightUpLeg",
    "LeftLeg": "RightLeg",
    "LeftFoot": "RightFoot",
    "LeftToeBase": "RightToeBase",
    "LeftShoulder": "RightShoulder",
    "LeftArm": "RightArm",
    "LeftForeArm": "RightForeArm",
    "LeftHand": "RightHand",
}

# ============================================================
# Sub Animation Override Support
# ============================================================

GRAVITAS_MESHY_BIPED24_CANONICAL_JOINTS = [
    "Hips",
    "LeftUpLeg",
    "LeftLeg",
    "LeftFoot",
    "LeftToeBase",
    "RightUpLeg",
    "RightLeg",
    "RightFoot",
    "RightToeBase",
    "Spine02",
    "Spine01",
    "Spine",
    "LeftShoulder",
    "LeftArm",
    "LeftForeArm",
    "LeftHand",
    "RightShoulder",
    "RightArm",
    "RightForeArm",
    "RightHand",
    "neck",
    "Head",
    "head_end",
    "headfront",
]

CLIP_TYPE_FULL_BODY = "full_body_animation"
CLIP_TYPE_SUB_ANIMATION_OVERRIDE = "sub_animation_override"


# ============================================================
# Logging
# ============================================================

def _write_log(lines):
    text = bpy.data.texts.get(LOG_TEXT_BLOCK_NAME)
    if text is None:
        text = bpy.data.texts.new(LOG_TEXT_BLOCK_NAME)
    text.clear()
    text.write("\n".join(lines))


def _log_append(log, message):
    log.append(str(message))
    print(message)


# ============================================================
# General helpers
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


def _ensure_directory(path):
    os.makedirs(path, exist_ok=True)


def _json_load(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _json_write(path, payload):
    _ensure_directory(os.path.dirname(path))
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def _split_csv(value):
    return [item.strip() for item in value.split(",") if item.strip()]


def _leaf_name(path_or_name):
    return path_or_name.split("/")[-1]


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _current_scene_fps():
    scene = bpy.context.scene
    return float(scene.render.fps / max(scene.render.fps_base, 0.0001))


def _source_rigs_root(library_root):
    return os.path.join(
        bpy.path.abspath(library_root),
        "Rigs",
        SOURCE_RIGS_FOLDER_NAME,
    )


def _source_rig_registry_path(library_root):
    return os.path.join(
        _source_rigs_root(library_root),
        SOURCE_RIG_REGISTRY_FILENAME,
    )


def _source_rig_relative_path(source_rig_id):
    return f"Rigs/{SOURCE_RIGS_FOLDER_NAME}/{source_rig_id}.source_rig.json"


def _source_rig_absolute_path(library_root, source_rig_id):
    return os.path.join(
        _source_rigs_root(library_root),
        f"{source_rig_id}.source_rig.json",
    )


def _round_float(value, places=7):
    return round(float(value), places)


def _round_list(values, places=7):
    return [_round_float(value, places=places) for value in values]


def _stable_json_hash(payload):
    encoded = json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")

    return hashlib.sha256(encoded).hexdigest()


def _sanitize_id_component(value):
    value = os.path.splitext(os.path.basename(str(value)))[0]
    value = re.sub(r"[^A-Za-z0-9_]+", "_", value)
    value = re.sub(r"_+", "_", value).strip("_")
    return value or "source_rig"


# ============================================================
# Manifest browser helpers
# ============================================================

def _manifest_file_path_from_library_root(library_root):
    return os.path.join(
        bpy.path.abspath(library_root),
        "Manifests",
        "animation_library_manifest.json",
    )


def _clip_display_label(summary):
    clip_id = summary.get("clip_id", "")
    display_name = summary.get("display_name", clip_id)
    category = ",".join(summary.get("category", []))
    return f"{display_name}  [{clip_id}]  {category}"


def _refresh_manifest_clip_cache(settings, log):
    global MANIFEST_CLIP_ENUM_CACHE
    global MANIFEST_CLIP_SUMMARY_BY_ID

    MANIFEST_CLIP_ENUM_CACHE = []
    MANIFEST_CLIP_SUMMARY_BY_ID = {}

    library_root = bpy.path.abspath(settings.animation_library_root)
    if not library_root:
        raise RuntimeError("Animation Library Root is empty.")

    manifest_path = _manifest_file_path_from_library_root(library_root)
    if not os.path.isfile(manifest_path):
        raise FileNotFoundError(f"Manifest not found: {manifest_path}")

    manifest = _json_load(manifest_path)

    for index, summary in enumerate(manifest.get("clips", [])):
        clip_id = summary.get("clip_id", "")
        if not clip_id:
            continue

        MANIFEST_CLIP_SUMMARY_BY_ID[clip_id] = summary
        MANIFEST_CLIP_ENUM_CACHE.append((
            clip_id,
            _clip_display_label(summary),
            summary.get("relative_path", ""),
            index,
        ))

    if not MANIFEST_CLIP_ENUM_CACHE:
        MANIFEST_CLIP_ENUM_CACHE.append((
            "__NONE__",
            "No clips found",
            "",
            0,
        ))

    log.append(f"Loaded manifest clips: {len(MANIFEST_CLIP_SUMMARY_BY_ID)}")
    return manifest


def _manifest_clip_enum_items(self, context):
    if MANIFEST_CLIP_ENUM_CACHE:
        return MANIFEST_CLIP_ENUM_CACHE

    return [
        ("__NONE__", "Load Manifest first", "", 0),
    ]


def _clip_json_path_from_summary(library_root, summary):
    relative_path = summary.get("relative_path", "")
    if not relative_path:
        raise RuntimeError("Selected manifest clip has no relative_path.")

    return os.path.join(
        bpy.path.abspath(library_root),
        relative_path.replace("/", os.sep),
    )


def _category_folder_from_clip_payload(clip_payload, fallback="Idle"):
    tags = clip_payload.get("tags", {})
    categories = tags.get("category", [])

    category_to_folder = {
        "dummy": "Dummy",
        "idle": "Idle",
        "turn": "Turn",
        "walk": "Walk",
        "hit_react": "HitReact",
        "storygesture": "StoryGesture",
        "story_gesture": "StoryGesture",
        "gesture": "StoryGesture",
    }

    for category in categories:
        key = str(category).strip().lower()
        if key in category_to_folder:
            return category_to_folder[key]

    return fallback


def _csv_from_list(values):
    if not values:
        return ""
    return ",".join(str(value) for value in values)


def _populate_settings_from_clip_payload(settings, clip_payload, summary=None):
    settings.clip_id = clip_payload.get("clip_id", settings.clip_id)
    settings.display_name = clip_payload.get("display_name", settings.display_name)
    settings.description = clip_payload.get("notes", settings.description)

    clip_type = clip_payload.get("clip_type", CLIP_TYPE_FULL_BODY)
    if clip_type == CLIP_TYPE_SUB_ANIMATION_OVERRIDE:
        settings.export_type = "SUB_ANIMATION_OVERRIDE"
    else:
        settings.export_type = "FULL_BODY"

    if "blend_in_frames" in clip_payload:
        settings.blend_in_frames = int(clip_payload.get("blend_in_frames", 2))

    if "blend_out_frames" in clip_payload:
        settings.blend_out_frames = int(clip_payload.get("blend_out_frames", 2))

    _set_selected_sub_animation_joints(
        settings,
        clip_payload.get("affected_joints", []),
    )

    settings.output_category_folder = _category_folder_from_clip_payload(
        clip_payload,
        fallback=settings.output_category_folder,
    )

    timing = clip_payload.get("timing", {})
    fps = timing.get("fps")
    duration_seconds = timing.get("duration_seconds")
    looping = timing.get("looping")

    if fps is not None:
        settings.source_fps = float(fps)

    if looping is not None:
        settings.looping = bool(looping)

    source = clip_payload.get("source", {})
    start_frame = source.get("start_frame")
    end_frame = source.get("end_frame")
    sample_every_n = source.get("sample_every_n_frames")

    if start_frame is not None:
        settings.source_start_frame = int(start_frame)

    if end_frame is not None:
        settings.source_end_frame = int(end_frame)
    elif duration_seconds is not None and fps is not None:
        settings.source_end_frame = (
            int(round(float(duration_seconds) * float(fps)))
            + int(settings.source_start_frame)
        )

    if sample_every_n is not None:
        settings.sample_every_n_frames = int(sample_every_n)

    source_path = source.get("source_path")
    if source_path:
        settings.donor_file_path = source_path

    source_rig = clip_payload.get("source_rig", {})
    source_character_id = source_rig.get("character_id")
    if source_character_id:
        settings.source_character_id = source_character_id

    locomotion = clip_payload.get("locomotion", {})
    settings.locomotion_enabled = bool(locomotion.get("enabled", False))
    settings.locomotion_type = locomotion.get(
        "locomotion_type",
        settings.locomotion_type,
    )
    settings.world_space_motion = locomotion.get(
        "world_space_motion",
        settings.world_space_motion,
    )
    settings.recommended_speed_mps = float(
        locomotion.get("recommended_speed_mps", settings.recommended_speed_mps)
    )
    settings.turn_degrees = float(
        locomotion.get("root_rotation_degrees", settings.turn_degrees)
    )
    settings.root_translation_policy = locomotion.get(
        "root_translation_policy",
        settings.root_translation_policy,
    )
    settings.locomotion_start_mode = locomotion.get(
        "locomotion_start_mode",
        settings.locomotion_start_mode,
    )

    transition = clip_payload.get("transition", {})
    if "default_transition_frames" in transition:
        settings.default_transition_frames = int(
            transition["default_transition_frames"]
        )

    tags = clip_payload.get("tags", {})
    settings.category_tags = _csv_from_list(tags.get("category", []))
    settings.emotion_tags = _csv_from_list(tags.get("emotion", []))
    settings.threat_tags = _csv_from_list(tags.get("threat", []))
    settings.story_tags = _csv_from_list(tags.get("story", []))
    settings.allowed_states = _csv_from_list(tags.get("allowed_states", []))

    quality = clip_payload.get("quality", {})
    settings.approved_for_runtime = bool(
        quality.get("approved_for_runtime", settings.approved_for_runtime)
    )
    settings.approved_for_episode = bool(
        quality.get("approved_for_episode", settings.approved_for_episode)
    )
    settings.debug_only = bool(
        quality.get("debug_only", settings.debug_only)
    )

    if summary is not None:
        settings.loaded_manifest_clip_relative_path = summary.get(
            "relative_path",
            "",
        )


# ============================================================
# Sub Animation Override helpers
# ============================================================

def _ensure_sub_animation_joint_list(settings, rig_json=None):
    if (
        settings.sub_animation_joint_list_initialized
        and len(settings.sub_animation_joints) > 0
    ):
        return

    settings.sub_animation_joints.clear()

    if rig_json is not None and "joint_paths" in rig_json:
        joints = [_leaf_name(path) for path in rig_json["joint_paths"]]
    else:
        joints = GRAVITAS_MESHY_BIPED24_CANONICAL_JOINTS

    for joint_name in joints:
        item = settings.sub_animation_joints.add()
        item.joint_name = joint_name
        item.selected = False

    settings.sub_animation_joint_list_initialized = True


def _selected_sub_animation_joints(settings):
    _ensure_sub_animation_joint_list(settings)
    return [
        item.joint_name
        for item in settings.sub_animation_joints
        if item.selected and item.joint_name
    ]


def _set_selected_sub_animation_joints(settings, selected_joint_names):
    selected = set(selected_joint_names)

    _ensure_sub_animation_joint_list(settings)

    for item in settings.sub_animation_joints:
        item.selected = item.joint_name in selected


def _all_sub_animation_joint_names(settings):
    _ensure_sub_animation_joint_list(settings)
    return [item.joint_name for item in settings.sub_animation_joints]


# ============================================================
# Mirror export helpers
# ============================================================

def _mirrored_joint_name(joint_name):
    if joint_name in MESHY_BIPED24_MIRROR_PAIRS:
        return MESHY_BIPED24_MIRROR_PAIRS[joint_name]

    for left, right in MESHY_BIPED24_MIRROR_PAIRS.items():
        if joint_name == right:
            return left

    return joint_name


def _mirror_translation_value(value):
    result = list(value)
    if len(result) >= 3:
        result[0] *= -1
    return result


def _mirror_quat_wxyz_value(value):
    result = list(value)
    if len(result) < 4:
        return result

    w, x, y, z = result[0], result[1], result[2], result[3]
    return [w, x, -y, -z]


def _mirror_track(track):
    mirrored = dict(track)
    channel = track.get("channel", "")
    mirrored["joint"] = _mirrored_joint_name(track.get("joint", ""))

    new_keys = []
    for key in track.get("keys", []):
        new_key = dict(key)
        value = list(key.get("value", []))

        if channel.startswith("translation_xyz"):
            new_key["value"] = _mirror_translation_value(value)
        elif channel.startswith("rotation_quat_wxyz"):
            new_key["value"] = _mirror_quat_wxyz_value(value)
        elif channel.startswith("scale_xyz"):
            new_key["value"] = value
        else:
            new_key["value"] = value

        new_keys.append(new_key)

    mirrored["keys"] = new_keys
    return mirrored


def _mirror_locomotion_tracks(locomotion):
    mirrored = json.loads(json.dumps(locomotion))
    tracks = mirrored.get("tracks", {})

    for key in tracks.get("side_meters", []):
        key["value"] = -float(key.get("value", 0.0))

    for key in tracks.get("yaw_degrees", []):
        key["value"] = -float(key.get("value", 0.0))

    return mirrored


def _replace_direction_word(value):
    replacements = [
        ("right", "left"),
        ("Right", "Left"),
        ("RIGHT", "LEFT"),
        ("left", "right"),
        ("Left", "Right"),
        ("LEFT", "RIGHT"),
        ("r", "l"),
        ("R", "L"),
        ("l", "r"),
        ("L", "R"),
    ]

    for old, new in replacements:
        pattern = rf"(^|[_\-\s]){re.escape(old)}($|[_\-\s])"
        replaced, count = re.subn(
            pattern,
            lambda match: f"{match.group(1)}{new}{match.group(2)}",
            value,
            count=1,
        )

        if count:
            return replaced

    return None


def _mirrored_clip_id_from(source_clip_id):
    replaced = _replace_direction_word(source_clip_id)
    if replaced:
        return replaced

    return f"{source_clip_id}_mirrored"


def _mirrored_display_name_from(display_name):
    replaced = _replace_direction_word(display_name)
    if replaced:
        return replaced

    return f"{display_name} Mirrored"


def _mirror_clip_payload(clip_payload):
    mirrored = json.loads(json.dumps(clip_payload))

    source_clip_id = clip_payload.get("clip_id", "clip")
    source_display_name = clip_payload.get("display_name", source_clip_id)

    mirrored["clip_id"] = _mirrored_clip_id_from(source_clip_id)
    mirrored["display_name"] = _mirrored_display_name_from(source_display_name)
    mirrored["tracks"] = [
        _mirror_track(track)
        for track in clip_payload.get("tracks", [])
    ]
    mirrored["affected_joints"] = [
        _mirrored_joint_name(joint_name)
        for joint_name in clip_payload.get("affected_joints", [])
    ]
    mirrored["locomotion"] = _mirror_locomotion_tracks(
        clip_payload.get("locomotion", {})
    )

    source = mirrored.get("source", {})
    source["mirrored_from_clip_id"] = source_clip_id
    source["mirrored_from_source_rig_id"] = (
        clip_payload.get("source_rig", {}).get("source_rig_id", "")
    )
    source["mirror_plane"] = "X"
    mirrored["source"] = source

    if "source_rig" in clip_payload:
        # Mirroring changes clip motion, not the source skeleton identity.
        mirrored["source_rig"] = json.loads(
            json.dumps(clip_payload["source_rig"])
        )

    notes = mirrored.get("notes", "")
    mirrored["notes"] = (
        f"{notes}\nMirrored export generated from {source_clip_id}."
    ).strip()

    return mirrored


# ============================================================
# Locomotion Authoring
# ============================================================

LOCOMOTION_ROOT_NAME = "JOCK_LOCOMOTION_ROOT"
LOCOMOTION_PATH_NAME = "JOCK_LOCOMOTION_PREVIEW_PATH"

LOCOMOTION_PROPS = [
    "forward_meters",
    "side_meters",
    "vertical_meters",
    "yaw_degrees",
]


def _get_locomotion_root():
    obj = bpy.data.objects.get(LOCOMOTION_ROOT_NAME)
    if obj is not None:
        return obj

    root = bpy.data.objects.new(LOCOMOTION_ROOT_NAME, None)
    root.empty_display_type = "ARROWS"
    root.empty_display_size = 0.35
    bpy.context.scene.collection.objects.link(root)

    for prop in LOCOMOTION_PROPS:
        root[prop] = 0.0

    root["gravitas_type"] = "jock_locomotion_root"
    return root


def _ensure_locomotion_root_defaults(root):
    for prop in LOCOMOTION_PROPS:
        if prop not in root:
            root[prop] = 0.0

    root["gravitas_type"] = "jock_locomotion_root"


def _apply_locomotion_root_preview_transform(root):
    """
    Blender authoring preview:
      forward_meters -> +Y
      side_meters    -> +X
      vertical       -> +Z
      yaw_degrees    -> rotation around +Z

    Runtime convention is encoded in JSON:
      forward -> local -Z
      up      -> +Y
    """
    forward = float(root.get("forward_meters", 0.0))
    side = float(root.get("side_meters", 0.0))
    vertical = float(root.get("vertical_meters", 0.0))
    yaw = math.radians(float(root.get("yaw_degrees", 0.0)))

    root.location = (side, forward, vertical)
    root.rotation_euler = (0.0, 0.0, yaw)


def _key_locomotion_root(root, frame, log):
    _ensure_locomotion_root_defaults(root)
    _apply_locomotion_root_preview_transform(root)

    for prop in LOCOMOTION_PROPS:
        root.keyframe_insert(data_path=f'["{prop}"]', frame=int(frame))

    root.keyframe_insert(data_path="location", frame=int(frame))
    root.keyframe_insert(data_path="rotation_euler", frame=int(frame))

    log.append(
        f"Keyed locomotion root at frame {frame}: "
        f"forward={root['forward_meters']}, "
        f"side={root['side_meters']}, "
        f"vertical={root['vertical_meters']}, "
        f"yaw={root['yaw_degrees']}"
    )


def _clear_locomotion_keys(root, log):
    if root.animation_data is not None:
        root.animation_data_clear()

    log.append("Cleared locomotion root animation keys.")


def _read_locomotion_prop(root, prop):
    try:
        return float(root.get(prop, 0.0))
    except Exception:
        return 0.0


def _empty_locomotion_tracks():
    return {
        "forward_meters": [],
        "side_meters": [],
        "vertical_meters": [],
        "yaw_degrees": [],
    }


def _sample_locomotion_tracks(
    start_frame,
    end_frame,
    source_fps,
    sample_every_n,
    enabled,
    log,
):
    """
    Locomotion tracks are authored as absolute values from clip start.
    Runtime applies deltas between samples.
    """
    root = bpy.data.objects.get(LOCOMOTION_ROOT_NAME)

    if not enabled or root is None:
        log.append(
            "Locomotion export disabled or no locomotion root found. "
            "Exporting disabled locomotion."
        )
        return {
            "enabled": False,
            "space": "characterLocal",
            "translation_units": "meters",
            "rotation_units": "degrees",
            "runtime_forward_axis": "-z",
            "runtime_up_axis": "y",
            "authoring_up_axis": "z",
            "locomotion_start_mode": "after_transition",
            "tracks": _empty_locomotion_tracks(),
        }

    sample_every_n = max(int(sample_every_n), 1)
    frames = list(range(int(start_frame), int(end_frame) + 1, sample_every_n))

    if not frames:
        frames = [int(start_frame)]

    if frames[-1] != int(end_frame):
        frames.append(int(end_frame))

    tracks = _empty_locomotion_tracks()

    for frame in frames:
        bpy.context.scene.frame_set(int(frame))
        bpy.context.view_layer.update()

        t = float(frame - start_frame) / float(source_fps)

        for prop in LOCOMOTION_PROPS:
            tracks[prop].append({
                "frame": int(frame),
                "t": t,
                "value": _read_locomotion_prop(root, prop),
            })

    log.append(
        f"Sampled locomotion tracks from frame {start_frame} to {end_frame}; "
        f"{len(frames)} samples."
    )

    return {
        "enabled": True,
        "space": "characterLocal",
        "translation_units": "meters",
        "rotation_units": "degrees",
        "runtime_forward_axis": "-z",
        "runtime_up_axis": "y",
        "authoring_up_axis": "z",
        "locomotion_start_mode": "after_transition",
        "tracks": tracks,
    }


def _delete_existing_locomotion_preview_path():
    obj = bpy.data.objects.get(LOCOMOTION_PATH_NAME)
    if obj is not None:
        bpy.data.objects.remove(obj, do_unlink=True)


def _refresh_locomotion_preview_path(start_frame, end_frame, sample_every_n, log):
    root = bpy.data.objects.get(LOCOMOTION_ROOT_NAME)
    if root is None:
        raise RuntimeError("No JOCK_LOCOMOTION_ROOT exists. Create it first.")

    _delete_existing_locomotion_preview_path()

    sample_every_n = max(int(sample_every_n), 1)
    frames = list(range(int(start_frame), int(end_frame) + 1, sample_every_n))

    if not frames:
        frames = [int(start_frame)]

    if frames[-1] != int(end_frame):
        frames.append(int(end_frame))

    points = []

    for frame in frames:
        bpy.context.scene.frame_set(int(frame))
        bpy.context.view_layer.update()

        forward = _read_locomotion_prop(root, "forward_meters")
        side = _read_locomotion_prop(root, "side_meters")
        vertical = _read_locomotion_prop(root, "vertical_meters")

        points.append((side, forward, vertical, 1.0))

    curve_data = bpy.data.curves.new(LOCOMOTION_PATH_NAME, type="CURVE")
    curve_data.dimensions = "3D"
    curve_data.resolution_u = 1
    curve_data.bevel_depth = 0.01

    polyline = curve_data.splines.new("POLY")
    polyline.points.add(len(points) - 1)

    for point, value in zip(polyline.points, points):
        point.co = value

    curve_obj = bpy.data.objects.new(LOCOMOTION_PATH_NAME, curve_data)
    bpy.context.scene.collection.objects.link(curve_obj)

    log.append(f"Refreshed locomotion preview path with {len(points)} points.")
    return curve_obj


# ============================================================
# Action / frame-range helpers
# ============================================================

def _iter_action_fcurves(action):
    if action is None:
        return

    seen = set()

    legacy = getattr(action, "fcurves", None)
    if legacy is not None:
        try:
            for fcurve in legacy:
                ptr = fcurve.as_pointer()
                if ptr not in seen:
                    seen.add(ptr)
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
                        for channelbag in channelbags:
                            fcurves = getattr(channelbag, "fcurves", None)
                            if fcurves is None:
                                continue
                            for fcurve in fcurves:
                                ptr = fcurve.as_pointer()
                                if ptr not in seen:
                                    seen.add(ptr)
                                    yield fcurve

                    channelbag_fn = getattr(strip, "channelbag", None)
                    slots = getattr(action, "slots", None)
                    if callable(channelbag_fn) and slots is not None:
                        for slot in slots:
                            channelbag = channelbag_fn(slot)
                            if channelbag is None:
                                continue
                            fcurves = getattr(channelbag, "fcurves", None)
                            if fcurves is None:
                                continue
                            for fcurve in fcurves:
                                ptr = fcurve.as_pointer()
                                if ptr not in seen:
                                    seen.add(ptr)
                                    yield fcurve
        except Exception:
            pass


def _action_has_keys(action):
    for fcurve in _iter_action_fcurves(action):
        if len(fcurve.keyframe_points) > 0:
            return True
    return False


def _action_bounds(action):
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


# ============================================================
# Import / detection
# ============================================================

def _delete_temp_collection():
    old = bpy.data.collections.get(TEMP_COLLECTION_NAME)
    if old is not None:
        for obj in list(old.objects):
            bpy.data.objects.remove(obj, do_unlink=True)
        try:
            bpy.data.collections.remove(old)
        except Exception:
            pass


def _create_temp_collection():
    _delete_temp_collection()
    collection = bpy.data.collections.new(TEMP_COLLECTION_NAME)
    bpy.context.scene.collection.children.link(collection)
    return collection


def _link_to_collection(objects, collection):
    linked_names = set(collection.objects.keys())
    for obj in objects:
        try:
            if obj.name not in linked_names:
                collection.objects.link(obj)
                linked_names.add(obj.name)
        except Exception:
            pass


def _import_donor_file(filepath, log):
    filepath = bpy.path.abspath(filepath)

    if not filepath or not os.path.isfile(filepath):
        raise FileNotFoundError(f"Donor file does not exist: {filepath}")

    _force_object_mode()

    saved_start = bpy.context.scene.frame_start
    saved_end = bpy.context.scene.frame_end
    saved_current = bpy.context.scene.frame_current

    existing = set(bpy.data.objects.keys())
    collection = _create_temp_collection()
    ext = os.path.splitext(filepath)[1].lower()

    _log_append(log, f"Importing donor: {filepath}")

    if ext in [".usd", ".usda", ".usdc", ".usdz"]:
        _call_operator_with_supported_kwargs(
            bpy.ops.wm.usd_import,
            filepath=filepath,
            set_frame_range=False,
            import_cameras=False,
            import_lights=False,
            import_materials=False,
            import_meshes=True,
            import_skeletons=True,
            import_blendshapes=True,
            read_meshes=True,
            read_animation=True,
        )
    elif ext == ".fbx":
        _call_operator_with_supported_kwargs(
            bpy.ops.import_scene.fbx,
            filepath=filepath,
            use_anim=True,
        )
    else:
        raise RuntimeError(f"Unsupported donor extension: {ext}")

    bpy.context.scene.frame_start = saved_start
    bpy.context.scene.frame_end = saved_end
    bpy.context.scene.frame_set(saved_current)
    bpy.context.view_layer.update()

    imported = [
        obj for obj in bpy.data.objects
        if obj.name not in existing
    ]

    _link_to_collection(imported, collection)
    _log_append(log, f"Imported object count: {len(imported)}")

    return imported, collection


def _find_animated_armature(objects):
    armatures = [obj for obj in objects if obj.type == "ARMATURE"]
    if not armatures:
        return None

    animated = []
    for armature in armatures:
        action = armature.animation_data.action if armature.animation_data else None
        if action is not None and _action_has_keys(action):
            animated.append(armature)

    if animated:
        animated.sort(
            key=lambda obj: (
                10 if ".001" in obj.name or ".002" in obj.name else 0,
                len(obj.pose.bones) if obj.pose else 0,
            ),
            reverse=True,
        )
        return animated[0]

    armatures.sort(
        key=lambda obj: len(obj.pose.bones) if obj.pose else 0,
        reverse=True,
    )
    return armatures[0]


# ============================================================
# Rig/map loading
# ============================================================

def _rig_leaf_names(rig_json):
    return [_leaf_name(path) for path in rig_json["joint_paths"]]


def _load_skeleton_map_or_identity(map_path, rig_json):
    if map_path and os.path.isfile(map_path):
        payload = _json_load(map_path)
        return payload.get("canonical_to_source", {})

    return {leaf: leaf for leaf in _rig_leaf_names(rig_json)}


def _resolve_source_bone_name(canonical_leaf, skeleton_map):
    return skeleton_map.get(canonical_leaf, canonical_leaf)


def _validate_armature_against_rig(armature, rig_json, skeleton_map):
    source_bones = {bone.name for bone in armature.pose.bones}
    missing = []

    for canonical_leaf in _rig_leaf_names(rig_json):
        source_name = _resolve_source_bone_name(canonical_leaf, skeleton_map)
        if source_name not in source_bones:
            missing.append({
                "canonical": canonical_leaf,
                "source": source_name,
            })

    return missing


# ============================================================
# Target character clip application
# ============================================================

CRITICAL_TARGET_RETARGET_JOINTS = {
    "Hips",
    "Spine02",
    "Spine01",
    "Spine",
    "neck",
    "Head",
    "LeftUpLeg",
    "RightUpLeg",
    "LeftLeg",
    "RightLeg",
    "LeftFoot",
    "RightFoot",
}


def _delete_target_collection():
    old = bpy.data.collections.get(TARGET_COLLECTION_NAME)
    if old is None:
        return

    for obj in list(old.objects):
        bpy.data.objects.remove(obj, do_unlink=True)

    try:
        bpy.data.collections.remove(old)
    except Exception:
        pass


def _create_target_collection():
    _delete_target_collection()
    collection = bpy.data.collections.new(TARGET_COLLECTION_NAME)
    bpy.context.scene.collection.children.link(collection)
    return collection


def _import_target_character(filepath, log):
    filepath = bpy.path.abspath(filepath)

    if not filepath or not os.path.isfile(filepath):
        raise FileNotFoundError(f"Target character file does not exist: {filepath}")

    _force_object_mode()

    saved_start = bpy.context.scene.frame_start
    saved_end = bpy.context.scene.frame_end
    saved_current = bpy.context.scene.frame_current

    existing = set(bpy.data.objects.keys())
    collection = _create_target_collection()
    ext = os.path.splitext(filepath)[1].lower()

    _log_append(log, f"Importing target character: {filepath}")

    if ext in [".usd", ".usda", ".usdc", ".usdz"]:
        _call_operator_with_supported_kwargs(
            bpy.ops.wm.usd_import,
            filepath=filepath,
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
    elif ext == ".fbx":
        _call_operator_with_supported_kwargs(
            bpy.ops.import_scene.fbx,
            filepath=filepath,
            use_anim=True,
        )
    else:
        raise RuntimeError(f"Unsupported target extension: {ext}")

    bpy.context.scene.frame_start = saved_start
    bpy.context.scene.frame_end = saved_end
    bpy.context.scene.frame_set(saved_current)
    bpy.context.view_layer.update()

    imported = [
        obj for obj in bpy.data.objects
        if obj.name not in existing
    ]

    _link_to_collection(imported, collection)

    armature = _find_animated_armature(imported)
    if armature is None:
        armatures = [obj for obj in imported if obj.type == "ARMATURE"]
        if not armatures:
            raise RuntimeError("No armature found in target character.")
        armatures.sort(
            key=lambda obj: len(obj.pose.bones) if obj.pose else 0,
            reverse=True,
        )
        armature = armatures[0]

    _log_append(log, f"Imported target object count: {len(imported)}")
    _log_append(log, f"Detected target armature: {armature.name}")

    return imported, collection, armature


def _load_selected_manifest_clip_payload(settings, log):
    if not MANIFEST_CLIP_SUMMARY_BY_ID:
        _refresh_manifest_clip_cache(settings, log)

    clip_id = settings.selected_manifest_clip_id

    if clip_id == "__NONE__" or not clip_id:
        raise RuntimeError("No manifest clip selected.")

    summary = MANIFEST_CLIP_SUMMARY_BY_ID.get(clip_id)
    if summary is None:
        raise RuntimeError(f"Selected clip not found in manifest cache: {clip_id}")

    clip_path = _clip_json_path_from_summary(
        settings.animation_library_root,
        summary,
    )

    if not os.path.isfile(clip_path):
        raise FileNotFoundError(f"Selected clip file not found: {clip_path}")

    payload = _json_load(clip_path)

    _log_append(log, f"Loaded manifest clip: {clip_id}")
    _log_append(log, f"Clip path: {clip_path}")

    return payload, summary, clip_path


def _tracks_by_joint_and_channel(clip_payload):
    result = {}

    for track in clip_payload.get("tracks", []):
        joint = track.get("joint", "")
        channel = track.get("channel", "")

        if not joint or not channel:
            continue

        result.setdefault(joint, {})[channel] = sorted(
            track.get("keys", []),
            key=lambda key: float(key.get("t", 0.0)),
        )

    return result


def _sample_vector_keyframe(keys, t, default=None):
    if not keys:
        return default

    if t <= float(keys[0].get("t", 0.0)):
        return keys[0].get("value", default)

    if t >= float(keys[-1].get("t", 0.0)):
        return keys[-1].get("value", default)

    for index in range(len(keys) - 1):
        a = keys[index]
        b = keys[index + 1]

        ta = float(a.get("t", 0.0))
        tb = float(b.get("t", 0.0))

        if ta <= t <= tb:
            denom = max(tb - ta, 0.000001)
            f = (t - ta) / denom

            av = a.get("value", default)
            bv = b.get("value", default)

            if av is None or bv is None:
                return default

            return [
                float(av[i]) + (float(bv[i]) - float(av[i])) * f
                for i in range(min(len(av), len(bv)))
            ]

    return default


def _quat_from_wxyz(value):
    if value is None or len(value) < 4:
        return None

    quat = mathutils.Quaternion((
        float(value[0]),
        float(value[1]),
        float(value[2]),
        float(value[3]),
    ))
    quat.normalize()
    return quat


def _vec3_from_value(value, default=(0.0, 0.0, 0.0)):
    if value is None or len(value) < 3:
        return mathutils.Vector(default)

    return mathutils.Vector((
        float(value[0]),
        float(value[1]),
        float(value[2]),
    ))


def _sample_quat_keyframe(keys, t, default=None):
    if not keys:
        return default

    if t <= float(keys[0].get("t", 0.0)):
        return _quat_from_wxyz(keys[0].get("value", None)) or default

    if t >= float(keys[-1].get("t", 0.0)):
        return _quat_from_wxyz(keys[-1].get("value", None)) or default

    for index in range(len(keys) - 1):
        a = keys[index]
        b = keys[index + 1]

        ta = float(a.get("t", 0.0))
        tb = float(b.get("t", 0.0))

        if ta <= t <= tb:
            qa = _quat_from_wxyz(a.get("value", None))
            qb = _quat_from_wxyz(b.get("value", None))

            if qa is None or qb is None:
                return default

            denom = max(tb - ta, 0.000001)
            f = (t - ta) / denom
            quat = qa.slerp(qb, f)
            if quat is None:
                quat = qa.copy()
                quat.slerp(qb, f)
            quat.normalize()
            return quat

    return default


def _target_rest_local_transform_by_bone(armature):
    result = {}

    for pose_bone in armature.pose.bones:
        bone = pose_bone.bone

        if bone.parent is None:
            local_matrix = bone.matrix_local.copy()
        else:
            local_matrix = bone.parent.matrix_local.inverted() @ bone.matrix_local

        loc, rot, scale = local_matrix.decompose()

        result[pose_bone.name] = {
            "translation": loc.copy(),
            "rotation": rot.copy(),
            "scale": scale.copy(),
            "matrix": local_matrix.copy(),
        }

    return result


def _first_track_value(track_keys):
    if not track_keys:
        return None

    sorted_keys = sorted(track_keys, key=lambda key: float(key.get("t", 0.0)))
    return sorted_keys[0].get("value", None)


def _source_reference_by_joint(tracks_by_joint):
    result = {}

    for joint, channels in tracks_by_joint.items():
        translation = _first_track_value(
            channels.get("translation_xyz_absolute", [])
        )
        rotation = _first_track_value(
            channels.get("rotation_quat_wxyz_absolute", [])
        )
        scale = _first_track_value(
            channels.get("scale_xyz_absolute", [])
        )

        result[joint] = {
            "translation": (
                _vec3_from_value(translation)
                if translation is not None
                else None
            ),
            "rotation": _quat_from_wxyz(rotation) if rotation is not None else None,
            "scale": (
                _vec3_from_value(scale, default=(1.0, 1.0, 1.0))
                if scale is not None
                else None
            ),
        }

    return result


def _build_target_bone_mapping(armature, rig_json, skeleton_map, log):
    pose_bone_names = {bone.name for bone in armature.pose.bones}
    runtime_indices_by_leaf = {}

    for index, bone_name in enumerate(sorted(pose_bone_names)):
        runtime_indices_by_leaf.setdefault(_leaf_name(bone_name), []).append(
            (index, bone_name)
        )

    result = {}
    missing = []
    ambiguous = []
    critical_mismatches = []

    for canonical_leaf in _rig_leaf_names(rig_json):
        target_name = _resolve_source_bone_name(canonical_leaf, skeleton_map)
        match_kind = "missing"
        mapped_name = None

        if target_name in pose_bone_names:
            mapped_name = target_name
            match_kind = "exactTargetName"
        elif canonical_leaf in pose_bone_names:
            mapped_name = canonical_leaf
            match_kind = "exactCanonicalLeaf"
        else:
            matches = runtime_indices_by_leaf.get(canonical_leaf, [])

            if len(matches) == 1:
                mapped_name = matches[0][1]
                match_kind = "uniqueLeafName"
            elif len(matches) > 1:
                ambiguous.append({
                    "canonical": canonical_leaf,
                    "target": target_name,
                    "matches": [match[1] for match in matches],
                })
                match_kind = "ambiguousLeafName"
            else:
                missing.append({
                    "canonical": canonical_leaf,
                    "target": target_name,
                    "matches": [],
                })

        if mapped_name is not None:
            result[canonical_leaf] = mapped_name

            if (
                canonical_leaf in CRITICAL_TARGET_RETARGET_JOINTS
                and _leaf_name(mapped_name) != canonical_leaf
            ):
                critical_mismatches.append(
                    f"{canonical_leaf} -> {mapped_name}"
                )

        _log_append(
            log,
            (
                "[TargetRetarget] joint map\n"
                f"  canonicalPath: {canonical_leaf}\n"
                f"  canonicalLeaf: {canonical_leaf}\n"
                f"  sourcePath: {target_name}\n"
                f"  targetPath: {mapped_name or 'nil'}\n"
                f"  matchKind: {match_kind}"
            ),
        )

    _log_append(
        log,
        (
            f"Target bone mappings: {len(result)} / "
            f"{len(_rig_leaf_names(rig_json))}"
        ),
    )

    if missing:
        _log_append(log, "[TargetRetarget] ERROR missing target bone mappings:")
        for item in missing:
            _log_append(
                log,
                (
                    f"  canonical={item['canonical']} "
                    f"target={item['target']} matches={item['matches']}"
                ),
            )

    if ambiguous:
        _log_append(log, "[TargetRetarget] ERROR ambiguous target bone mappings:")
        for item in ambiguous:
            _log_append(
                log,
                (
                    f"  canonical={item['canonical']} "
                    f"target={item['target']} matches={item['matches']}"
                ),
            )

    if critical_mismatches:
        _log_append(log, "[TargetRetarget] ERROR critical identity mismatches:")
        for mismatch in critical_mismatches:
            _log_append(log, f"  {mismatch}")

    return result, missing, ambiguous, critical_mismatches


def _is_root_joint(canonical_joint):
    lower = canonical_joint.lower()
    return lower in {"hips", "root", "pelvis", "armature"}


def _compose_matrix(translation, rotation, scale):
    loc_matrix = mathutils.Matrix.Translation(translation)
    rot_matrix = rotation.to_matrix().to_4x4()
    scale_matrix = mathutils.Matrix.Diagonal((
        float(scale.x),
        float(scale.y),
        float(scale.z),
        1.0,
    ))
    return loc_matrix @ rot_matrix @ scale_matrix


def _sample_manifest_local_transform_for_joint(
    canonical_joint,
    target_bone_name,
    channels,
    source_reference,
    target_rest,
    settings,
    t,
):
    rest = target_rest[target_bone_name]

    rest_t = rest["translation"].copy()
    rest_r = rest["rotation"].copy()
    rest_s = rest["scale"].copy()

    abs_t = _sample_vector_keyframe(
        channels.get("translation_xyz_absolute", []),
        t,
        default=None,
    )
    abs_r = _sample_quat_keyframe(
        channels.get("rotation_quat_wxyz_absolute", []),
        t,
        default=None,
    )
    abs_s = _sample_vector_keyframe(
        channels.get("scale_xyz_absolute", []),
        t,
        default=None,
    )

    policy = settings.target_pose_policy

    if policy == "AUTHOR_ABSOLUTE_LOCAL":
        final_t = (
            _vec3_from_value(abs_t, default=tuple(rest_t))
            if abs_t is not None
            else rest_t
        )
        final_r = abs_r.copy() if abs_r is not None else rest_r
        final_s = (
            _vec3_from_value(abs_s, default=tuple(rest_s))
            if abs_s is not None
            else rest_s
        )

        return _compose_matrix(final_t, final_r, final_s)

    # Industry retargeting does not copy source joint translations onto a
    # different body. This test path preserves the target rest skeleton, layers
    # source rotation deltas, and applies only optional root translation delta.
    final_t = rest_t.copy()
    final_r = rest_r.copy()
    final_s = rest_s.copy()

    source_ref = source_reference.get(canonical_joint, {})

    if abs_r is not None:
        ref_r = source_ref.get("rotation") or abs_r

        if settings.target_rotation_delta_order == "PARENT_SPACE":
            delta = abs_r @ ref_r.inverted()
            final_r = delta @ rest_r
        else:
            delta = ref_r.inverted() @ abs_r
            final_r = rest_r @ delta

        final_r.normalize()

    if settings.target_apply_root_translation and _is_root_joint(canonical_joint):
        if abs_t is not None:
            ref_t = source_ref.get("translation") or _vec3_from_value(abs_t)
            delta_t = _vec3_from_value(abs_t) - ref_t
            if settings.target_ignore_root_vertical:
                delta_t.z = 0.0
            final_t = rest_t + delta_t
    elif (
        abs_t is not None
        and not settings.target_ignore_non_root_translations
    ):
        ref_t = source_ref.get("translation") or _vec3_from_value(abs_t)
        final_t = rest_t + (_vec3_from_value(abs_t) - ref_t)

    if not settings.target_ignore_scales and abs_s is not None:
        final_s = _vec3_from_value(abs_s, default=tuple(rest_s))

    return _compose_matrix(final_t, final_r, final_s)


def _topological_pose_bone_order(armature):
    result = []
    visited = set()

    def visit(name):
        if name in visited:
            return

        bone = armature.pose.bones.get(name)
        if bone is None:
            return

        if bone.parent is not None:
            visit(bone.parent.name)

        visited.add(name)
        result.append(name)

    for bone in armature.pose.bones:
        visit(bone.name)

    return result


def _apply_local_pose_matrices(armature, local_matrix_by_bone):
    order = _topological_pose_bone_order(armature)
    object_pose_by_bone = {}

    for bone_name in order:
        pose_bone = armature.pose.bones.get(bone_name)
        if pose_bone is None:
            continue

        local = local_matrix_by_bone.get(bone_name)
        if local is None:
            continue

        if pose_bone.parent is not None:
            parent_object = object_pose_by_bone.get(pose_bone.parent.name)
            if parent_object is None:
                parent_object = pose_bone.parent.matrix.copy()
            object_pose = parent_object @ local
        else:
            object_pose = local

        pose_bone.matrix = object_pose
        object_pose_by_bone[bone_name] = object_pose

    bpy.context.view_layer.update()


def _key_target_armature_pose(armature, frame, bone_names):
    for bone_name in bone_names:
        pose_bone = armature.pose.bones.get(bone_name)
        if pose_bone is None:
            continue

        pose_bone.rotation_mode = "QUATERNION"
        pose_bone.keyframe_insert(data_path="location", frame=frame)
        pose_bone.keyframe_insert(data_path="rotation_quaternion", frame=frame)
        pose_bone.keyframe_insert(data_path="scale", frame=frame)


def _apply_jockanim_clip_to_target_armature(
    settings,
    armature,
    clip_payload,
    rig_json,
    skeleton_map,
    log,
):
    tracks_by_joint = _tracks_by_joint_and_channel(clip_payload)
    source_reference = _source_reference_by_joint(tracks_by_joint)
    target_rest = _target_rest_local_transform_by_bone(armature)

    bone_mapping, missing, ambiguous, critical_mismatches = _build_target_bone_mapping(
        armature=armature,
        rig_json=rig_json,
        skeleton_map=skeleton_map,
        log=log,
    )

    if missing or ambiguous or critical_mismatches:
        raise RuntimeError(
            (
                "Target mapping failed: "
                f"missing={len(missing)} "
                f"ambiguous={len(ambiguous)} "
                f"criticalMismatches={len(critical_mismatches)}"
            )
        )

    timing = clip_payload.get("timing", {})
    fps = float(timing.get("fps", settings.source_fps))
    duration = float(timing.get("duration_seconds", 0.0))

    if duration <= 0.0:
        max_t = 0.0
        for joint_channels in tracks_by_joint.values():
            for keys in joint_channels.values():
                for key in keys:
                    max_t = max(max_t, float(key.get("t", 0.0)))
        duration = max_t

    start_frame = int(settings.source_start_frame)
    end_frame = start_frame + int(round(duration * fps))

    if end_frame <= start_frame:
        end_frame = start_frame + 1

    sample_every = max(int(settings.sample_every_n_frames), 1)

    if settings.target_clear_existing_animation and armature.animation_data is not None:
        armature.animation_data_clear()

    armature.rotation_mode = "QUATERNION"

    scene = bpy.context.scene
    scene.frame_start = start_frame
    scene.frame_end = end_frame
    scene.render.fps = int(round(fps))
    scene.render.fps_base = 1.0

    frames = list(range(start_frame, end_frame + 1, sample_every))
    if not frames:
        frames = [start_frame]
    if frames[-1] != end_frame:
        frames.append(end_frame)

    applied_rotations = 0
    applied_root_translations = 0
    ignored_non_root_translations = 0
    ignored_scales = 0

    for frame in frames:
        t = float(frame - start_frame) / max(fps, 0.0001)
        scene.frame_set(frame)
        bpy.context.view_layer.update()

        local_matrix_by_bone = {}

        for canonical_joint, target_bone_name in bone_mapping.items():
            channels = tracks_by_joint.get(canonical_joint, {})

            if not channels:
                continue

            if channels.get("rotation_quat_wxyz_absolute"):
                applied_rotations += 1

            if channels.get("translation_xyz_absolute"):
                if _is_root_joint(canonical_joint):
                    applied_root_translations += 1
                elif settings.target_ignore_non_root_translations:
                    ignored_non_root_translations += 1

            if channels.get("scale_xyz_absolute") and settings.target_ignore_scales:
                ignored_scales += 1

            local_matrix_by_bone[target_bone_name] = (
                _sample_manifest_local_transform_for_joint(
                    canonical_joint=canonical_joint,
                    target_bone_name=target_bone_name,
                    channels=channels,
                    source_reference=source_reference,
                    target_rest=target_rest,
                    settings=settings,
                    t=t,
                )
            )

        _apply_local_pose_matrices(
            armature=armature,
            local_matrix_by_bone=local_matrix_by_bone,
        )

        _key_target_armature_pose(
            armature=armature,
            frame=frame,
            bone_names=list(local_matrix_by_bone.keys()),
        )

    _log_append(log, "Applied JockAnim clip to target armature.")
    _log_append(log, f"Clip ID: {clip_payload.get('clip_id', 'unknown')}")
    _log_append(log, f"Pose policy: {settings.target_pose_policy}")
    _log_append(log, f"Rotation delta order: {settings.target_rotation_delta_order}")
    _log_append(log, f"Ignore root vertical delta: {settings.target_ignore_root_vertical}")
    _log_append(
        log,
        f"Frames keyed: {frames[0]} -> {frames[-1]} ({len(frames)} samples)",
    )
    _log_append(log, f"Matched joints: {len(bone_mapping)}")
    _log_append(log, f"Applied rotation tracks count events: {applied_rotations}")
    _log_append(
        log,
        f"Applied root translation count events: {applied_root_translations}",
    )
    _log_append(
        log,
        (
            "Ignored non-root translation count events: "
            f"{ignored_non_root_translations}"
        ),
    )
    _log_append(log, f"Ignored scale count events: {ignored_scales}")

    return {
        "start_frame": start_frame,
        "end_frame": end_frame,
        "frames": frames,
        "matched_joints": len(bone_mapping),
    }


def _export_animated_target(settings, armature, log):
    export_format = settings.target_export_format

    if export_format == "NONE" or not settings.target_export_after_apply:
        _log_append(
            log,
            "Target export skipped. Animated target left in Blender scene.",
        )
        return None

    output_path = bpy.path.abspath(settings.target_output_file_path)

    if not output_path:
        raise RuntimeError("Output Animated Target path is empty.")

    _ensure_directory(os.path.dirname(output_path))

    _force_object_mode()
    bpy.ops.object.select_all(action="DESELECT")

    collection = bpy.data.collections.get(TARGET_COLLECTION_NAME)
    if collection is not None:
        for obj in collection.objects:
            obj.select_set(True)

    armature.select_set(True)
    bpy.context.view_layer.objects.active = armature

    if export_format == "FBX":
        _call_operator_with_supported_kwargs(
            bpy.ops.export_scene.fbx,
            filepath=output_path,
            use_selection=True,
            bake_anim=True,
            add_leaf_bones=False,
        )
    elif export_format == "USD":
        _call_operator_with_supported_kwargs(
            bpy.ops.wm.usd_export,
            filepath=output_path,
            selected_objects_only=True,
            export_animation=True,
            export_armatures=True,
            export_meshes=True,
            export_materials=True,
        )
    else:
        raise RuntimeError(f"Unsupported target export format: {export_format}")

    _log_append(log, f"Exported animated target: {output_path}")
    return output_path


# ============================================================
# Pose sampling
# ============================================================

def _sample_pose_bone_local(pose_bone):
    if pose_bone.parent is None:
        local_matrix = pose_bone.matrix.copy()
    else:
        local_matrix = pose_bone.parent.matrix.inverted() @ pose_bone.matrix

    location, rotation, scale = local_matrix.decompose()

    return {
        "translation": [
            float(location.x),
            float(location.y),
            float(location.z),
        ],
        "rotation_wxyz": [
            float(rotation.w),
            float(rotation.x),
            float(rotation.y),
            float(rotation.z),
        ],
        "scale": [
            float(scale.x),
            float(scale.y),
            float(scale.z),
        ],
    }


def _sample_rest_bone_local(pose_bone):
    bone = pose_bone.bone

    if bone.parent is None:
        local_matrix = bone.matrix_local.copy()
    else:
        local_matrix = bone.parent.matrix_local.inverted() @ bone.matrix_local

    location, rotation, scale = local_matrix.decompose()

    return {
        "translation_xyz": _round_list([
            location.x,
            location.y,
            location.z,
        ]),
        "rotation_quat_wxyz": _round_list([
            rotation.w,
            rotation.x,
            rotation.y,
            rotation.z,
        ]),
        "scale_xyz": _round_list([
            scale.x,
            scale.y,
            scale.z,
        ]),
    }


def _source_rest_parent_map(armature, rig_json, skeleton_map):
    source_to_canonical = {}

    for canonical_leaf in _rig_leaf_names(rig_json):
        source_name = _resolve_source_bone_name(canonical_leaf, skeleton_map)
        source_to_canonical[source_name] = canonical_leaf

    parent_by_joint = {}

    for canonical_leaf in _rig_leaf_names(rig_json):
        source_name = _resolve_source_bone_name(canonical_leaf, skeleton_map)
        pose_bone = armature.pose.bones.get(source_name)

        if pose_bone is None:
            parent_by_joint[canonical_leaf] = None
            continue

        if pose_bone.parent is None:
            parent_by_joint[canonical_leaf] = None
        else:
            parent_by_joint[canonical_leaf] = source_to_canonical.get(
                pose_bone.parent.name
            )

    return parent_by_joint


def _extract_source_rig_payload(
    armature,
    rig_json,
    skeleton_map,
    donor_file_path,
    character_id=None,
):
    donor_path = bpy.path.abspath(donor_file_path)
    donor_basename = os.path.basename(donor_path)
    character_id = character_id or _sanitize_id_component(donor_basename)

    rest_transforms = {}
    missing = []

    for canonical_leaf in _rig_leaf_names(rig_json):
        source_name = _resolve_source_bone_name(canonical_leaf, skeleton_map)
        pose_bone = armature.pose.bones.get(source_name)

        if pose_bone is None:
            missing.append({
                "canonical": canonical_leaf,
                "source": source_name,
            })
            continue

        rest_transforms[canonical_leaf] = _sample_rest_bone_local(pose_bone)

    if missing:
        raise RuntimeError(
            f"Cannot extract source rig rest pose: {len(missing)} missing mapped joints."
        )

    parent_by_joint = _source_rest_parent_map(
        armature=armature,
        rig_json=rig_json,
        skeleton_map=skeleton_map,
    )

    skeleton_hash_payload = {
        "rig_id": rig_json["rig_id"],
        "rig_version": rig_json["version"],
        "joint_paths": _rig_leaf_names(rig_json),
        "parent_by_joint": parent_by_joint,
        "rest_local_transforms": rest_transforms,
    }

    skeleton_hash = _stable_json_hash(skeleton_hash_payload)
    source_rig_id = f"{character_id}_{skeleton_hash[:12]}"

    return {
        "schema": DEFAULT_SOURCE_RIG_SCHEMA,
        "source_rig_id": source_rig_id,
        "character_id": character_id,
        "display_name": character_id.replace("_", " ").title(),
        "source_asset": {
            "file_name": donor_basename,
            "source_path": donor_path,
        },
        "canonical_rig": {
            "rig_id": rig_json["rig_id"],
            "rig_version": rig_json["version"],
        },
        "skeleton_hash": skeleton_hash,
        "joint_paths": _rig_leaf_names(rig_json),
        "parent_by_joint": parent_by_joint,
        "rest_local_transforms": rest_transforms,
        "created_at": _now_iso(),
        "updated_at": _now_iso(),
    }


def _load_or_create_source_rig_registry(library_root):
    path = _source_rig_registry_path(library_root)

    if os.path.isfile(path):
        return _json_load(path)

    return {
        "schema": DEFAULT_SOURCE_RIG_REGISTRY_SCHEMA,
        "generated_at": _now_iso(),
        "source_rigs": [],
    }


def _register_source_rig_payload(library_root, source_rig_payload, log):
    registry = _load_or_create_source_rig_registry(library_root)
    source_rigs = registry.get("source_rigs", [])

    skeleton_hash = source_rig_payload["skeleton_hash"]
    existing = None

    for item in source_rigs:
        if item.get("skeleton_hash") == skeleton_hash:
            existing = item
            break

    if existing:
        source_rig_id = existing["source_rig_id"]
        relative_path = existing["relative_path"]
        absolute_path = os.path.join(
            bpy.path.abspath(library_root),
            relative_path.replace("/", os.sep),
        )

        _log_append(
            log,
            f"Source rig deduped: {source_rig_id} hash={skeleton_hash[:12]}",
        )

        return {
            "source_rig_id": source_rig_id,
            "skeleton_hash": skeleton_hash,
            "relative_path": relative_path,
            "dedupe_status": "existing",
            "absolute_path": absolute_path,
        }

    source_rig_id = source_rig_payload["source_rig_id"]
    relative_path = _source_rig_relative_path(source_rig_id)
    absolute_path = _source_rig_absolute_path(library_root, source_rig_id)

    _json_write(absolute_path, source_rig_payload)

    source_rigs.append({
        "source_rig_id": source_rig_id,
        "character_id": source_rig_payload["character_id"],
        "display_name": source_rig_payload["display_name"],
        "skeleton_hash": skeleton_hash,
        "relative_path": relative_path,
        "source_asset_file": source_rig_payload["source_asset"]["file_name"],
        "canonical_rig_id": source_rig_payload["canonical_rig"]["rig_id"],
        "canonical_rig_version": (
            source_rig_payload["canonical_rig"]["rig_version"]
        ),
        "created_at": source_rig_payload["created_at"],
        "updated_at": source_rig_payload["updated_at"],
    })

    source_rigs.sort(key=lambda item: item.get("source_rig_id", ""))

    registry["source_rigs"] = source_rigs
    registry["generated_at"] = _now_iso()

    _json_write(_source_rig_registry_path(library_root), registry)

    _log_append(
        log,
        f"Source rig registered: {source_rig_id} hash={skeleton_hash[:12]}",
    )

    return {
        "source_rig_id": source_rig_id,
        "skeleton_hash": skeleton_hash,
        "relative_path": relative_path,
        "dedupe_status": "created",
        "absolute_path": absolute_path,
    }


def _sample_clip_tracks(
    armature,
    rig_json,
    skeleton_map,
    start_frame,
    end_frame,
    source_fps,
    sample_every_n,
    include_translations,
    include_rotations,
    include_scales,
    log,
    export_joint_names=None,
):
    if end_frame < start_frame:
        raise RuntimeError(f"Bad frame range: {start_frame} -> {end_frame}")

    sample_every_n = max(int(sample_every_n), 1)

    rig_leafs = set(_rig_leaf_names(rig_json))

    if export_joint_names is None:
        canonical_leafs = _rig_leaf_names(rig_json)
    else:
        canonical_leafs = list(export_joint_names)

    for joint_name in canonical_leafs:
        if joint_name not in rig_leafs:
            raise RuntimeError(
                f"Export joint '{joint_name}' is not part of active rig definition."
            )

    pose_bones = armature.pose.bones

    translation_keys_by_joint = {joint: [] for joint in canonical_leafs}
    rotation_keys_by_joint = {joint: [] for joint in canonical_leafs}
    scale_keys_by_joint = {joint: [] for joint in canonical_leafs}

    sampled_frames = list(range(start_frame, end_frame + 1, sample_every_n))
    if not sampled_frames or sampled_frames[-1] != end_frame:
        sampled_frames.append(end_frame)

    for frame in sampled_frames:
        bpy.context.scene.frame_set(int(frame))
        bpy.context.view_layer.update()

        t = float(frame - start_frame) / float(source_fps)

        for canonical_leaf in canonical_leafs:
            source_name = _resolve_source_bone_name(canonical_leaf, skeleton_map)
            pose_bone = pose_bones.get(source_name)
            if pose_bone is None:
                continue

            sample = _sample_pose_bone_local(pose_bone)

            if include_translations:
                translation_keys_by_joint[canonical_leaf].append({
                    "t": t,
                    "value": sample["translation"],
                })

            if include_rotations:
                rotation_keys_by_joint[canonical_leaf].append({
                    "t": t,
                    "value": sample["rotation_wxyz"],
                })

            if include_scales:
                scale_keys_by_joint[canonical_leaf].append({
                    "t": t,
                    "value": sample["scale"],
                })

    tracks = []

    for canonical_leaf in canonical_leafs:
        if include_translations:
            tracks.append({
                "joint": canonical_leaf,
                "channel": "translation_xyz_absolute",
                "keys": translation_keys_by_joint[canonical_leaf],
            })

        if include_rotations:
            tracks.append({
                "joint": canonical_leaf,
                "channel": "rotation_quat_wxyz_absolute",
                "keys": rotation_keys_by_joint[canonical_leaf],
            })

        if include_scales:
            tracks.append({
                "joint": canonical_leaf,
                "channel": "scale_xyz_absolute",
                "keys": scale_keys_by_joint[canonical_leaf],
            })

    _log_append(
        log,
        f"Sampled {len(sampled_frames)} frames, {len(tracks)} tracks."
    )

    return tracks, sampled_frames


# ============================================================
# Manifest update
# ============================================================

def _manifest_path(library_root):
    return os.path.join(
        library_root,
        "Manifests",
        "animation_library_manifest.json",
    )


def _relative_to_library_root(path, library_root):
    try:
        return os.path.relpath(path, library_root).replace("\\", "/")
    except Exception:
        return path.replace("\\", "/")


def _load_or_create_manifest(library_root):
    path = _manifest_path(library_root)

    if os.path.isfile(path):
        return _json_load(path)

    return {
        "schema": "com.gravitas.animation_library_manifest.v0",
        "library_id": "GravitasPlagueAnimationLibrary",
        "generated_at": _now_iso(),
        "clips": [],
    }


def _update_manifest(library_root, clip_payload, output_path):
    manifest = _load_or_create_manifest(library_root)
    clips = manifest.get("clips", [])

    clip_id = clip_payload["clip_id"]
    relative_path = _relative_to_library_root(output_path, library_root)
    source_rig = clip_payload.get("source_rig", {})

    summary = {
        "clip_id": clip_id,
        "display_name": clip_payload["display_name"],
        "relative_path": relative_path,
        "rig_id": clip_payload["rig_id"],
        "rig_version": clip_payload["rig_version"],
        "pose_mode": clip_payload["pose_mode"],
        "clip_type": clip_payload.get("clip_type", CLIP_TYPE_FULL_BODY),
        "affected_joints": clip_payload.get("affected_joints", []),
        "blend_in_frames": clip_payload.get("blend_in_frames", 0),
        "blend_out_frames": clip_payload.get("blend_out_frames", 0),
        "base_animation_continues": clip_payload.get(
            "base_animation_continues",
            False,
        ),
        "category": clip_payload["tags"]["category"],
        "emotion": clip_payload["tags"]["emotion"],
        "threat": clip_payload["tags"]["threat"],
        "story": clip_payload["tags"]["story"],
        "looping": clip_payload["timing"]["looping"],
        "duration_seconds": clip_payload["timing"]["duration_seconds"],
        "locomotion_type": clip_payload["locomotion"]["locomotion_type"],
        "world_space_motion": clip_payload["locomotion"]["world_space_motion"],
        "locomotion_enabled": clip_payload["locomotion"].get("enabled", False),
        "locomotion_start_mode": clip_payload["locomotion"].get(
            "locomotion_start_mode",
            "after_transition",
        ),
        "approved_for_runtime": clip_payload["quality"]["approved_for_runtime"],
        "debug_only": clip_payload["quality"]["debug_only"],
        "source_rig_id": source_rig.get("source_rig_id", ""),
        "source_character_id": source_rig.get("character_id", ""),
        "source_skeleton_hash": source_rig.get("skeleton_hash", ""),
        "source_rig_relative_path": source_rig.get("relative_path", ""),
        "updated_at": _now_iso(),
    }

    clips = [clip for clip in clips if clip.get("clip_id") != clip_id]
    clips.append(summary)
    clips.sort(key=lambda clip: clip.get("clip_id", ""))

    manifest["clips"] = clips
    manifest["generated_at"] = _now_iso()

    path = _manifest_path(library_root)
    _json_write(path, manifest)

    return path


def _write_clip_and_update_manifest(
    settings,
    library_root,
    clip_payload,
    explicit_existing_relative_path=None,
):
    clip_id = clip_payload["clip_id"]

    if (
        settings.overwrite_existing_clip
        and explicit_existing_relative_path
    ):
        output_path = os.path.join(
            library_root,
            explicit_existing_relative_path.replace("/", os.sep),
        )
    else:
        folder = _category_folder_from_clip_payload(
            clip_payload,
            fallback=settings.output_category_folder,
        )

        output_dir = os.path.join(
            library_root,
            "Clips",
            folder,
        )
        output_path = os.path.join(output_dir, f"{clip_id}.jockanim.json")

    _json_write(output_path, clip_payload)

    manifest_path = _update_manifest(
        library_root=library_root,
        clip_payload=clip_payload,
        output_path=output_path,
    )

    return output_path, manifest_path


# ============================================================
# Settings
# ============================================================

class GravitasSubAnimationJointItem(PropertyGroup):
    joint_name: StringProperty(
        name="Joint",
        default="",
    )

    selected: BoolProperty(
        name="Selected",
        default=False,
    )


class GravitasAnimationLibrarySettings(PropertyGroup):
    animation_library_root: StringProperty(
        name="Animation Library Root",
        subtype="DIR_PATH",
        default=DEFAULT_ANIMATION_LIBRARY_ROOT,
    )

    rig_json_path: StringProperty(
        name="Rig Definition JSON",
        subtype="FILE_PATH",
        default=DEFAULT_RIG_JSON_PATH,
    )

    skeleton_map_path: StringProperty(
        name="Skeleton Map JSON",
        subtype="FILE_PATH",
        default=DEFAULT_SKELETON_MAP_PATH,
    )

    selected_manifest_clip_id: EnumProperty(
        name="Existing Clip",
        description="Clip loaded from animation_library_manifest.json.",
        items=_manifest_clip_enum_items,
    )

    loaded_manifest_clip_relative_path: StringProperty(
        name="Loaded Clip Relative Path",
        default="",
    )

    overwrite_existing_clip: BoolProperty(
        name="Overwrite Existing Clip",
        description="Export back to the selected clip's existing manifest path.",
        default=True,
    )

    export_type: EnumProperty(
        name="Export Type",
        description=(
            "Choose whether this clip exports as a full-body animation "
            "or a masked sub-animation override."
        ),
        items=[
            (
                "FULL_BODY",
                "Full Body Animation",
                "Export all mapped rig joints as a normal full-body clip.",
            ),
            (
                "SUB_ANIMATION_OVERRIDE",
                "Sub Animation Override",
                "Export only selected joints as a temporary override layer.",
            ),
        ],
        default="FULL_BODY",
    )

    sub_animation_joints: CollectionProperty(
        type=GravitasSubAnimationJointItem,
    )

    sub_animation_joint_list_initialized: BoolProperty(
        name="Sub Animation Joint List Initialized",
        default=False,
    )

    blend_in_frames: IntProperty(
        name="Blend In Frames",
        description="Frames used by runtime to blend into this sub-animation override.",
        default=2,
        min=0,
        max=120,
    )

    blend_out_frames: IntProperty(
        name="Blend Out Frames",
        description="Frames used by runtime to blend back to the live base animation.",
        default=2,
        min=0,
        max=120,
    )

    donor_file_path: StringProperty(
        name="Donor Animation File",
        subtype="FILE_PATH",
        default="",
    )

    source_character_id: StringProperty(
        name="Source Character ID",
        description=(
            "Character/rig that authored this animation. Used for source rig "
            "rest-pose dedupe."
        ),
        default=DEFAULT_DAD_SOURCE_CHARACTER_ID,
    )

    detected_armature_name: StringProperty(
        name="Detected Armature",
        default="",
    )

    clip_id: StringProperty(
        name="Clip ID",
        default="infected_idle_01_meshy_v001",
    )

    display_name: StringProperty(
        name="Display Name",
        default="Infected Idle 01 Meshy",
    )

    description: StringProperty(
        name="AI Description",
        default="A Meshy donor animation extracted into a Jock sidecar clip.",
    )

    author: StringProperty(
        name="Author",
        default="Gravitas Pipeline",
    )

    output_category_folder: EnumProperty(
        name="Output Category Folder",
        items=[
            ("Dummy", "Dummy", ""),
            ("Idle", "Idle", ""),
            ("Turn", "Turn", ""),
            ("Walk", "Walk", ""),
            ("HitReact", "HitReact", ""),
            ("StoryGesture", "StoryGesture", ""),
        ],
        default="Idle",
    )

    source_start_frame: IntProperty(
        name="Start Frame",
        default=1,
        min=-100000,
        max=100000,
    )

    source_end_frame: IntProperty(
        name="End Frame",
        default=48,
        min=-100000,
        max=100000,
    )

    source_fps: FloatProperty(
        name="Source FPS",
        default=24.0,
        min=1.0,
        max=240.0,
    )

    sample_every_n_frames: IntProperty(
        name="Sample Every N Frames",
        default=1,
        min=1,
        max=120,
    )

    looping: BoolProperty(
        name="Looping",
        default=True,
    )

    include_translations: BoolProperty(
        name="Export Translations",
        default=True,
    )

    include_rotations: BoolProperty(
        name="Export Rotations",
        default=True,
    )

    include_scales: BoolProperty(
        name="Export Scales",
        default=False,
    )

    category_tags: StringProperty(
        name="Category Tags",
        default="idle",
    )

    emotion_tags: StringProperty(
        name="Emotion Tags",
        default="vacant,sick,unstable",
    )

    threat_tags: StringProperty(
        name="Threat Tags",
        default="passive",
    )

    story_tags: StringProperty(
        name="Story Tags",
        default="test,meshy",
    )

    allowed_states: StringProperty(
        name="Allowed States",
        default="debug,idle",
    )

    locomotion_type: EnumProperty(
        name="Locomotion Type",
        items=[
            ("stationary", "stationary", ""),
            ("in_place_walk", "in_place_walk", ""),
            ("root_motion_walk", "root_motion_walk", ""),
            ("turn", "turn", ""),
            ("lunge", "lunge", ""),
            ("hit_react", "hit_react", ""),
            ("collapse", "collapse", ""),
        ],
        default="stationary",
    )

    world_space_motion: EnumProperty(
        name="World Space Motion",
        items=[
            ("none", "none", ""),
            ("game_driven", "game_driven", ""),
            ("animation_root_driven", "animation_root_driven", ""),
        ],
        default="none",
    )

    recommended_speed_mps: FloatProperty(
        name="Recommended Speed MPS",
        default=0.0,
        min=0.0,
        max=5.0,
    )

    turn_degrees: FloatProperty(
        name="Turn Degrees",
        default=0.0,
        min=-360.0,
        max=360.0,
    )

    root_translation_policy: EnumProperty(
        name="Root Translation Policy",
        items=[
            ("ignore", "ignore", ""),
            ("preserve", "preserve", ""),
            ("extract_as_metadata", "extract_as_metadata", ""),
            ("manual_curve", "manual_curve", ""),
            ("virtual_root_extracted", "virtual_root_extracted", ""),
        ],
        default="ignore",
    )

    locomotion_enabled: BoolProperty(
        name="Enable Locomotion Track",
        default=False,
    )

    locomotion_forward_meters: FloatProperty(
        name="Forward Meters",
        default=0.0,
        min=-100.0,
        max=100.0,
    )

    locomotion_side_meters: FloatProperty(
        name="Side Meters",
        default=0.0,
        min=-100.0,
        max=100.0,
    )

    locomotion_vertical_meters: FloatProperty(
        name="Vertical Meters",
        default=0.0,
        min=-10.0,
        max=10.0,
    )

    locomotion_yaw_degrees: FloatProperty(
        name="Yaw Degrees",
        default=0.0,
        min=-1080.0,
        max=1080.0,
    )

    locomotion_preview_sample_every_n: IntProperty(
        name="Preview Sample Every N Frames",
        default=4,
        min=1,
        max=120,
    )

    locomotion_start_mode: EnumProperty(
        name="Locomotion Start Mode",
        items=[
            ("after_transition", "after_transition", "Start root motion after pose transition."),
            ("during_transition", "during_transition", "Start root motion during pose transition."),
            ("immediate", "immediate", "Start root motion immediately."),
        ],
        default="after_transition",
    )

    default_transition_frames: IntProperty(
        name="Default Transition Frames",
        default=5,
        min=0,
        max=120,
    )

    approved_for_runtime: BoolProperty(
        name="Approved For Runtime",
        default=True,
    )

    approved_for_episode: BoolProperty(
        name="Approved For Episode",
        default=False,
    )

    debug_only: BoolProperty(
        name="Debug Only",
        default=False,
    )

    log_text: BoolProperty(
        name="Write Log Text Block",
        default=True,
    )

    mirror_animation: BoolProperty(
        name="Mirror Animation",
        description=(
            "Export a whole-rig mirrored sidecar. Left/right tracks swap, "
            "X translation mirrors, and locomotion side/yaw invert."
        ),
        default=False,
    )

    target_character_file_path: StringProperty(
        name="Target Character USDZ",
        subtype="FILE_PATH",
        default="",
    )

    target_detected_armature_name: StringProperty(
        name="Target Armature",
        default="",
    )

    target_output_file_path: StringProperty(
        name="Output Animated Target",
        subtype="FILE_PATH",
        default="",
    )

    target_export_format: EnumProperty(
        name="Export Format",
        items=[
            (
                "NONE",
                "Leave In Blender",
                "Apply animation and leave target in the Blender scene.",
            ),
            (
                "USD",
                "USD / USDC",
                "Export animated USD/USDC if Blender supports it.",
            ),
            (
                "FBX",
                "FBX",
                "Export animated FBX for Blender/runtime inspection.",
            ),
        ],
        default="NONE",
    )

    target_pose_policy: EnumProperty(
        name="Pose Policy",
        items=[
            (
                "AUTHOR_ABSOLUTE_LOCAL",
                "Author Absolute Local",
                (
                    "Apply manifest absolute local transforms directly. "
                    "Use for Dad/source-compatible rigs."
                ),
            ),
            (
                "PRESERVE_TARGET_SKELETON",
                "Preserve Target Skeleton",
                (
                    "Use target rest translations/proportions. Apply manifest "
                    "rotations as deltas. Use for Neighbor/future characters."
                ),
            ),
        ],
        default="PRESERVE_TARGET_SKELETON",
    )

    target_rotation_delta_order: EnumProperty(
        name="Rotation Delta Order",
        items=[
            (
                "PARENT_SPACE",
                "Parent Space",
                (
                    "delta = sampled * inverse(reference), "
                    "final = delta * targetRest. Recommended for Neighbor."
                ),
            ),
            (
                "LOCAL_SPACE",
                "Local Space",
                (
                    "delta = inverse(reference) * sampled, "
                    "final = targetRest * delta. Kept for comparison."
                ),
            ),
        ],
        default="PARENT_SPACE",
    )

    target_apply_root_translation: BoolProperty(
        name="Apply Root Translation Delta",
        default=True,
    )

    target_ignore_non_root_translations: BoolProperty(
        name="Ignore Non-Root Translations",
        default=True,
    )

    target_ignore_root_vertical: BoolProperty(
        name="Ignore Root Vertical Delta",
        default=True,
    )

    target_ignore_scales: BoolProperty(
        name="Ignore Scale Tracks",
        default=True,
    )

    target_clear_existing_animation: BoolProperty(
        name="Clear Target Existing Animation",
        default=True,
    )

    target_export_after_apply: BoolProperty(
        name="Export After Apply",
        default=False,
    )


# ============================================================
# Operators
# ============================================================

class GRAVITAS_OT_refresh_sub_animation_joint_list(Operator):
    bl_idname = "gravitas.refresh_sub_animation_joint_list"
    bl_label = "Refresh Joint List"
    bl_description = "Refreshes the sub-animation joint list from the active rig definition."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        log = []

        try:
            rig_json = None
            rig_path = bpy.path.abspath(settings.rig_json_path)

            if rig_path and os.path.isfile(rig_path):
                rig_json = _json_load(rig_path)

            settings.sub_animation_joint_list_initialized = False
            _ensure_sub_animation_joint_list(settings, rig_json=rig_json)

            _log_append(
                log,
                (
                    "Refreshed sub-animation joint list: "
                    f"{len(settings.sub_animation_joints)} joints."
                ),
            )
            _safe_report(self, {"INFO"}, "Refreshed sub-animation joint list.")

        except Exception as error:
            _log_append(log, "ERROR")
            _log_append(log, str(error))
            _log_append(log, traceback.format_exc())
            _safe_report(self, {"ERROR"}, str(error))
            return {"CANCELLED"}

        finally:
            if settings.log_text:
                _write_log(log)

        return {"FINISHED"}


class GRAVITAS_OT_clear_sub_animation_joint_selection(Operator):
    bl_idname = "gravitas.clear_sub_animation_joint_selection"
    bl_label = "Clear Joint Selection"
    bl_description = "Clears selected joints for sub-animation export."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        _ensure_sub_animation_joint_list(settings)

        for item in settings.sub_animation_joints:
            item.selected = False

        self.report({"INFO"}, "Cleared sub-animation joint selection.")
        return {"FINISHED"}


class GRAVITAS_OT_load_animation_manifest(Operator):
    bl_idname = "gravitas.load_animation_manifest"
    bl_label = "Load Manifest"
    bl_description = "Loads animation_library_manifest.json and populates Existing Clip dropdown."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        log = []

        try:
            _refresh_manifest_clip_cache(settings, log)

            first_valid = None
            for item in MANIFEST_CLIP_ENUM_CACHE:
                if item[0] != "__NONE__":
                    first_valid = item[0]
                    break

            if first_valid is not None:
                settings.selected_manifest_clip_id = first_valid

            settings.loaded_manifest_clip_relative_path = ""

            _safe_report(self, {"INFO"}, "Loaded animation manifest.")

        except Exception as error:
            _log_append(log, "ERROR")
            _log_append(log, str(error))
            _log_append(log, traceback.format_exc())
            _safe_report(self, {"ERROR"}, str(error))
            return {"CANCELLED"}

        finally:
            if settings.log_text:
                _write_log(log)

        return {"FINISHED"}


class GRAVITAS_OT_load_selected_clip_metadata(Operator):
    bl_idname = "gravitas.load_selected_clip_metadata"
    bl_label = "Load Selected Clip Metadata"
    bl_description = "Loads selected .jockanim.json and populates metadata fields."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        log = []

        try:
            if not MANIFEST_CLIP_SUMMARY_BY_ID:
                _refresh_manifest_clip_cache(settings, log)

            clip_id = settings.selected_manifest_clip_id
            if clip_id == "__NONE__" or not clip_id:
                raise RuntimeError("No manifest clip selected.")

            summary = MANIFEST_CLIP_SUMMARY_BY_ID.get(clip_id)
            if summary is None:
                raise RuntimeError(
                    f"Selected clip not found in manifest cache: {clip_id}"
                )

            clip_path = _clip_json_path_from_summary(
                settings.animation_library_root,
                summary,
            )

            if not os.path.isfile(clip_path):
                raise FileNotFoundError(f"Clip file not found: {clip_path}")

            clip_payload = _json_load(clip_path)

            _populate_settings_from_clip_payload(
                settings=settings,
                clip_payload=clip_payload,
                summary=summary,
            )

            log.append(f"Loaded metadata from: {clip_path}")
            _safe_report(self, {"INFO"}, f"Loaded metadata for {clip_id}")

        except Exception as error:
            _log_append(log, "ERROR")
            _log_append(log, str(error))
            _log_append(log, traceback.format_exc())
            _safe_report(self, {"ERROR"}, str(error))
            return {"CANCELLED"}

        finally:
            if settings.log_text:
                _write_log(log)

        return {"FINISHED"}


class GRAVITAS_OT_delete_selected_clip_from_manifest(Operator):
    bl_idname = "gravitas.delete_selected_clip_from_manifest"
    bl_label = "Delete From Manifest"
    bl_description = "Removes the selected clip entry from animation_library_manifest.json without deleting the clip file."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        log = []

        try:
            if not MANIFEST_CLIP_SUMMARY_BY_ID:
                _refresh_manifest_clip_cache(settings, log)

            clip_id = settings.selected_manifest_clip_id
            if clip_id == "__NONE__" or not clip_id:
                raise RuntimeError("No manifest clip selected.")

            library_root = bpy.path.abspath(settings.animation_library_root)
            manifest_path = _manifest_file_path_from_library_root(library_root)

            if not os.path.isfile(manifest_path):
                raise FileNotFoundError(f"Manifest not found: {manifest_path}")

            manifest = _json_load(manifest_path)
            clips = manifest.get("clips", [])
            filtered_clips = [
                clip for clip in clips
                if clip.get("clip_id") != clip_id
            ]

            if len(filtered_clips) == len(clips):
                raise RuntimeError(f"Clip not found in manifest: {clip_id}")

            manifest["clips"] = filtered_clips
            manifest["generated_at"] = _now_iso()
            _json_write(manifest_path, manifest)

            settings.loaded_manifest_clip_relative_path = ""

            _refresh_manifest_clip_cache(settings, log)

            first_valid = None
            for item in MANIFEST_CLIP_ENUM_CACHE:
                if item[0] != "__NONE__":
                    first_valid = item[0]
                    break

            settings.selected_manifest_clip_id = first_valid or "__NONE__"

            log.append(f"Deleted manifest entry for clip_id: {clip_id}")
            log.append("Clip file was not deleted.")
            _safe_report(self, {"INFO"}, f"Deleted {clip_id} from manifest.")

        except Exception as error:
            _log_append(log, "ERROR")
            _log_append(log, str(error))
            _log_append(log, traceback.format_exc())
            _safe_report(self, {"ERROR"}, str(error))
            return {"CANCELLED"}

        finally:
            if settings.log_text:
                _write_log(log)

        return {"FINISHED"}


class GRAVITAS_OT_import_donor_animation(Operator):
    bl_idname = "gravitas.import_donor_animation"
    bl_label = "Import Donor Animation"
    bl_description = "Imports the donor USDZ/USD/USDC/FBX and detects an animated armature."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        log = []

        try:
            imported, _collection = _import_donor_file(
                settings.donor_file_path,
                log,
            )

            armature = _find_animated_armature(imported)
            if armature is None:
                raise RuntimeError("No animated armature found in donor file.")

            settings.detected_armature_name = armature.name

            action = armature.animation_data.action if armature.animation_data else None
            bounds = _action_bounds(action)

            if bounds is not None:
                settings.source_start_frame = bounds[0]
                settings.source_end_frame = bounds[1]

            if settings.source_fps <= 0:
                settings.source_fps = _current_scene_fps()

            _log_append(log, f"Detected armature: {armature.name}")
            _log_append(log, f"Detected action: {action.name if action else 'NONE'}")
            _log_append(log, f"Detected bounds: {bounds}")

            _safe_report(
                self,
                {"INFO"},
                f"Imported donor. Detected armature: {armature.name}",
            )

        except Exception as error:
            _log_append(log, "ERROR")
            _log_append(log, str(error))
            _log_append(log, traceback.format_exc())
            _safe_report(self, {"ERROR"}, str(error))
            return {"CANCELLED"}

        finally:
            if settings.log_text:
                _write_log(log)

        return {"FINISHED"}


class GRAVITAS_OT_validate_donor_rig(Operator):
    bl_idname = "gravitas.validate_donor_rig"
    bl_label = "Validate Donor Rig"
    bl_description = "Validates detected donor armature against the rig definition and skeleton map."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        log = []

        try:
            rig = _json_load(bpy.path.abspath(settings.rig_json_path))
            skeleton_map = _load_skeleton_map_or_identity(
                bpy.path.abspath(settings.skeleton_map_path),
                rig,
            )

            armature = bpy.data.objects.get(settings.detected_armature_name)
            if armature is None or armature.type != "ARMATURE":
                raise RuntimeError("No detected armature. Import donor first.")

            missing = _validate_armature_against_rig(
                armature,
                rig,
                skeleton_map,
            )

            _log_append(log, f"Rig ID: {rig['rig_id']} v{rig['version']}")
            _log_append(log, f"Expected joints: {len(_rig_leaf_names(rig))}")
            _log_append(log, f"Source pose bones: {len(armature.pose.bones)}")

            if missing:
                _log_append(log, "Missing mapped joints:")
                for item in missing:
                    _log_append(
                        log,
                        f"  canonical={item['canonical']} source={item['source']}",
                    )
                raise RuntimeError(f"Rig validation failed: {len(missing)} missing joints.")

            _log_append(log, "Rig validation passed.")
            _safe_report(self, {"INFO"}, "Rig validation passed.")

        except Exception as error:
            _log_append(log, "ERROR")
            _log_append(log, str(error))
            _log_append(log, traceback.format_exc())
            _safe_report(self, {"ERROR"}, str(error))
            return {"CANCELLED"}

        finally:
            if settings.log_text:
                _write_log(log)

        return {"FINISHED"}


def _candidate_dad_biped_paths(settings):
    library_root = bpy.path.abspath(settings.animation_library_root)
    project_root = DEFAULT_PROJECT_ROOT

    candidates = []

    donor = bpy.path.abspath(settings.donor_file_path)
    if donor and os.path.basename(donor).lower() == "dad_biped.usdz":
        candidates.append(donor)

    candidates.extend([
        os.path.join(project_root, "dad_biped.usdz"),
        os.path.join(
            project_root,
            "Gravitas Plague",
            "Gravitas Plague",
            "dad_biped.usdz",
        ),
        os.path.join(
            project_root,
            "Gravitas Plague",
            "Gravitas Plague",
            "Characters",
            "dad_biped.usdz",
        ),
        os.path.join(
            project_root,
            "Gravitas Plague",
            "Gravitas Plague",
            "Resources",
            "dad_biped.usdz",
        ),
        os.path.join(
            project_root,
            "Gravitas Plague",
            "Gravitas Plague",
            "Assets",
            "dad_biped.usdz",
        ),
        os.path.join(
            library_root,
            "Rigs",
            "SourceAssets",
            "dad_biped.usdz",
        ),
    ])

    seen = set()
    out = []
    for path in candidates:
        if path and path not in seen:
            seen.add(path)
            out.append(path)

    return out


def _resolve_dad_biped_usdz(settings):
    for path in _candidate_dad_biped_paths(settings):
        if os.path.isfile(path):
            return path

    raise FileNotFoundError(
        "Could not locate dad_biped.usdz. Set Donor Animation File to "
        "dad_biped.usdz, or place it under the project/resources/"
        "AnimationLibrary/Rigs/SourceAssets path."
    )


class GRAVITAS_OT_export_jock_clip(Operator):
    bl_idname = "gravitas.export_jock_clip"
    bl_label = "Export JockAnim Clip"
    bl_description = "Samples the detected donor armature and exports a .jockanim.json sidecar."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        log = []

        try:
            library_root = bpy.path.abspath(settings.animation_library_root)
            if not library_root:
                raise RuntimeError("Animation Library Root is empty.")

            rig = _json_load(bpy.path.abspath(settings.rig_json_path))
            skeleton_map = _load_skeleton_map_or_identity(
                bpy.path.abspath(settings.skeleton_map_path),
                rig,
            )

            armature = bpy.data.objects.get(settings.detected_armature_name)
            if armature is None or armature.type != "ARMATURE":
                raise RuntimeError("No detected armature. Import donor first.")

            missing = _validate_armature_against_rig(
                armature,
                rig,
                skeleton_map,
            )
            if missing:
                raise RuntimeError(f"Rig validation failed: {len(missing)} missing joints.")

            start_frame = int(settings.source_start_frame)
            end_frame = int(settings.source_end_frame)
            fps = float(settings.source_fps)

            if end_frame < start_frame:
                raise RuntimeError(f"Bad frame range: {start_frame} -> {end_frame}")

            duration_seconds = float(end_frame - start_frame) / max(fps, 0.0001)

            export_type = settings.export_type

            if export_type == "SUB_ANIMATION_OVERRIDE":
                clip_type = CLIP_TYPE_SUB_ANIMATION_OVERRIDE
                affected_joints = _selected_sub_animation_joints(settings)

                if not affected_joints:
                    raise RuntimeError(
                        "Sub Animation Override export requires at least one selected joint."
                    )

                export_joint_names = affected_joints

                if settings.looping:
                    _log_append(
                        log,
                        (
                            "Warning: Sub Animation Override is usually non-looping. "
                            "Export will preserve current Looping setting."
                        ),
                    )
            else:
                clip_type = CLIP_TYPE_FULL_BODY
                affected_joints = []
                export_joint_names = None

            tracks, sampled_frames = _sample_clip_tracks(
                armature=armature,
                rig_json=rig,
                skeleton_map=skeleton_map,
                start_frame=start_frame,
                end_frame=end_frame,
                source_fps=fps,
                sample_every_n=int(settings.sample_every_n_frames),
                include_translations=bool(settings.include_translations),
                include_rotations=bool(settings.include_rotations),
                include_scales=bool(settings.include_scales),
                log=log,
                export_joint_names=export_joint_names,
            )

            locomotion_track_payload = _sample_locomotion_tracks(
                start_frame=start_frame,
                end_frame=end_frame,
                source_fps=fps,
                sample_every_n=int(settings.sample_every_n_frames),
                enabled=bool(settings.locomotion_enabled),
                log=log,
            )

            clip_id = settings.clip_id.strip()
            if not clip_id:
                raise RuntimeError("Clip ID is empty.")

            source_rig_payload = _extract_source_rig_payload(
                armature=armature,
                rig_json=rig,
                skeleton_map=skeleton_map,
                donor_file_path=settings.donor_file_path,
                character_id=settings.source_character_id.strip() or None,
            )

            source_rig_ref = _register_source_rig_payload(
                library_root=library_root,
                source_rig_payload=source_rig_payload,
                log=log,
            )

            clip_payload = {
                "schema": "com.gravitas.jockanim.v0",
                "clip_id": clip_id,
                "display_name": settings.display_name.strip() or clip_id,
                "rig_id": rig["rig_id"],
                "rig_version": rig["version"],
                "pose_mode": "absoluteLocal",
                "clip_type": clip_type,
                "affected_joints": affected_joints,
                "blend_in_frames": (
                    int(settings.blend_in_frames)
                    if clip_type == CLIP_TYPE_SUB_ANIMATION_OVERRIDE
                    else 0
                ),
                "blend_out_frames": (
                    int(settings.blend_out_frames)
                    if clip_type == CLIP_TYPE_SUB_ANIMATION_OVERRIDE
                    else 0
                ),
                "base_animation_continues": (
                    clip_type == CLIP_TYPE_SUB_ANIMATION_OVERRIDE
                ),
                "source": {
                    "type": "blender_donor_extract",
                    "source_file": os.path.basename(bpy.path.abspath(settings.donor_file_path)),
                    "source_path": bpy.path.abspath(settings.donor_file_path),
                    "author": settings.author,
                    "start_frame": start_frame,
                    "end_frame": end_frame,
                    "sample_every_n_frames": int(settings.sample_every_n_frames),
                    "notes": "Extracted by Gravitas Animation Library Tool v2.0.",
                },
                "source_rig": {
                    "schema": "com.gravitas.jockanim.source_rig_ref.v0",
                    "source_rig_id": source_rig_ref["source_rig_id"],
                    "character_id": source_rig_payload["character_id"],
                    "skeleton_hash": source_rig_ref["skeleton_hash"],
                    "relative_path": source_rig_ref["relative_path"],
                    "dedupe_status": source_rig_ref["dedupe_status"],
                    "source_asset_file": (
                        source_rig_payload["source_asset"]["file_name"]
                    ),
                },
                "timing": {
                    "fps": fps,
                    "duration_seconds": duration_seconds,
                    "looping": bool(settings.looping),
                },
                "joints": (
                    affected_joints
                    if clip_type == CLIP_TYPE_SUB_ANIMATION_OVERRIDE
                    else _rig_leaf_names(rig)
                ),
                "tracks": tracks,
                "locomotion": {
                    "enabled": bool(locomotion_track_payload["enabled"]),
                    "locomotion_type": settings.locomotion_type,
                    "world_space_motion": settings.world_space_motion,
                    "space": locomotion_track_payload["space"],
                    "translation_units": locomotion_track_payload["translation_units"],
                    "rotation_units": locomotion_track_payload["rotation_units"],
                    "runtime_forward_axis": locomotion_track_payload["runtime_forward_axis"],
                    "runtime_up_axis": locomotion_track_payload["runtime_up_axis"],
                    "authoring_up_axis": locomotion_track_payload["authoring_up_axis"],
                    "locomotion_start_mode": settings.locomotion_start_mode,
                    "recommended_speed_mps": float(settings.recommended_speed_mps),
                    "root_rotation_degrees": float(settings.turn_degrees),
                    "root_translation_policy": (
                        "manual_curve"
                        if locomotion_track_payload["enabled"]
                        else settings.root_translation_policy
                    ),
                    "tracks": locomotion_track_payload["tracks"],
                },
                "transition": {
                    "default_transition_frames": int(settings.default_transition_frames),
                    "transition_fps": fps,
                },
                "tags": {
                    "category": _split_csv(settings.category_tags),
                    "emotion": _split_csv(settings.emotion_tags),
                    "threat": _split_csv(settings.threat_tags),
                    "story": _split_csv(settings.story_tags),
                    "allowed_states": _split_csv(settings.allowed_states),
                },
                "quality": {
                    "approved_for_runtime": bool(settings.approved_for_runtime),
                    "approved_for_episode": bool(settings.approved_for_episode),
                    "debug_only": bool(settings.debug_only),
                },
                "notes": settings.description,
            }

            _log_append(log, f"Clip type: {clip_type}")
            _log_append(log, f"Source rig ref: {source_rig_ref['source_rig_id']}")
            _log_append(log, f"Source rig dedupe: {source_rig_ref['dedupe_status']}")
            _log_append(log, f"Source rig path: {source_rig_ref['relative_path']}")
            _log_append(
                log,
                f"Source skeleton hash: {source_rig_ref['skeleton_hash']}",
            )

            if clip_type == CLIP_TYPE_SUB_ANIMATION_OVERRIDE:
                _log_append(log, f"Affected joints: {', '.join(affected_joints)}")
                _log_append(
                    log,
                    (
                        "Blend in/out: "
                        f"{settings.blend_in_frames}/{settings.blend_out_frames}"
                    ),
                )

            payload_to_write = clip_payload
            existing_relative_path = settings.loaded_manifest_clip_relative_path

            if settings.mirror_animation:
                payload_to_write = _mirror_clip_payload(clip_payload)
                existing_relative_path = None
                _log_append(
                    log,
                    (
                        "Mirror Animation enabled: "
                        f"{clip_payload['clip_id']} -> {payload_to_write['clip_id']}"
                    ),
                )

            output_path, manifest_path = _write_clip_and_update_manifest(
                settings=settings,
                library_root=library_root,
                clip_payload=payload_to_write,
                explicit_existing_relative_path=existing_relative_path,
            )

            _log_append(log, f"Exported clip: {output_path}")
            _log_append(log, f"Updated manifest: {manifest_path}")
            _log_append(log, f"Sampled frames: {sampled_frames[0]} -> {sampled_frames[-1]}")
            _log_append(log, f"Track count: {len(tracks)}")

            _safe_report(
                self,
                {"INFO"},
                f"Exported JockAnim clip: {payload_to_write['clip_id']}",
            )

        except Exception as error:
            _log_append(log, "ERROR")
            _log_append(log, str(error))
            _log_append(log, traceback.format_exc())
            _safe_report(self, {"ERROR"}, str(error))
            return {"CANCELLED"}

        finally:
            if settings.log_text:
                _write_log(log)

        return {"FINISHED"}


class GRAVITAS_OT_backfill_dad_source_rig_to_existing_clips(Operator):
    bl_idname = "gravitas.backfill_dad_source_rig_to_existing_clips"
    bl_label = "Backfill Dad Source Rig To Existing Clips"
    bl_description = (
        "Registers dad_biped.usdz as a source rig and writes source_rig "
        "references into existing clips that lack one."
    )
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        log = []

        try:
            library_root = bpy.path.abspath(settings.animation_library_root)
            dad_path = _resolve_dad_biped_usdz(settings)

            rig = _json_load(bpy.path.abspath(settings.rig_json_path))
            skeleton_map = _load_skeleton_map_or_identity(
                bpy.path.abspath(settings.skeleton_map_path),
                rig,
            )

            imported, _collection = _import_donor_file(dad_path, log)

            armature = _find_animated_armature(imported)
            if armature is None:
                armatures = [obj for obj in imported if obj.type == "ARMATURE"]
                if not armatures:
                    raise RuntimeError("No armature found in dad_biped.usdz.")

                armatures.sort(
                    key=lambda obj: len(obj.pose.bones) if obj.pose else 0,
                    reverse=True,
                )
                armature = armatures[0]

            missing = _validate_armature_against_rig(
                armature,
                rig,
                skeleton_map,
            )
            if missing:
                raise RuntimeError(
                    f"Dad rig validation failed: {len(missing)} missing joints."
                )

            source_rig_payload = _extract_source_rig_payload(
                armature=armature,
                rig_json=rig,
                skeleton_map=skeleton_map,
                donor_file_path=dad_path,
                character_id=DEFAULT_DAD_SOURCE_CHARACTER_ID,
            )

            source_rig_ref = _register_source_rig_payload(
                library_root=library_root,
                source_rig_payload=source_rig_payload,
                log=log,
            )

            manifest = _load_or_create_manifest(library_root)
            updated = 0
            skipped = 0
            missing_files = 0

            for summary in manifest.get("clips", []):
                relative_path = summary.get("relative_path", "")
                if not relative_path:
                    skipped += 1
                    continue

                clip_path = os.path.join(
                    library_root,
                    relative_path.replace("/", os.sep),
                )

                if not os.path.isfile(clip_path):
                    missing_files += 1
                    _log_append(log, f"Missing clip file: {clip_path}")
                    continue

                clip_payload = _json_load(clip_path)

                if clip_payload.get("clip_id") != summary.get("clip_id"):
                    _log_append(
                        log,
                        (
                            "Warning: manifest clip_id does not match clip file "
                            f"payload: manifest={summary.get('clip_id')} "
                            f"payload={clip_payload.get('clip_id')} "
                            f"path={relative_path}"
                        ),
                    )

                existing_ref = clip_payload.get("source_rig", {})
                if existing_ref.get("source_rig_id"):
                    ref_for_summary = existing_ref
                    skipped += 1
                else:
                    ref_for_summary = {
                        "schema": "com.gravitas.jockanim.source_rig_ref.v0",
                        "source_rig_id": source_rig_ref["source_rig_id"],
                        "character_id": DEFAULT_DAD_SOURCE_CHARACTER_ID,
                        "skeleton_hash": source_rig_ref["skeleton_hash"],
                        "relative_path": source_rig_ref["relative_path"],
                        "dedupe_status": "backfilled",
                        "source_asset_file": os.path.basename(dad_path),
                    }

                    clip_payload["source_rig"] = ref_for_summary
                    _json_write(clip_path, clip_payload)
                    updated += 1

                summary["source_rig_id"] = ref_for_summary.get("source_rig_id", "")
                summary["source_character_id"] = ref_for_summary.get("character_id", "")
                summary["source_skeleton_hash"] = ref_for_summary.get(
                    "skeleton_hash",
                    "",
                )
                summary["source_rig_relative_path"] = ref_for_summary.get(
                    "relative_path",
                    "",
                )
                summary["updated_at"] = _now_iso()

            manifest["generated_at"] = _now_iso()
            _json_write(_manifest_path(library_root), manifest)

            _refresh_manifest_clip_cache(settings, log)

            _log_append(log, "")
            _log_append(log, "Dad source rig backfill complete.")
            _log_append(log, f"Dad path: {dad_path}")
            _log_append(log, f"Source rig ID: {source_rig_ref['source_rig_id']}")
            _log_append(log, f"Updated clips: {updated}")
            _log_append(log, f"Skipped clips: {skipped}")
            _log_append(log, f"Missing clip files: {missing_files}")

            _safe_report(
                self,
                {"INFO"},
                f"Backfilled Dad source rig onto {updated} clips.",
            )

        except Exception as error:
            _log_append(log, "ERROR")
            _log_append(log, str(error))
            _log_append(log, traceback.format_exc())
            _safe_report(self, {"ERROR"}, str(error))
            return {"CANCELLED"}

        finally:
            if settings.log_text:
                _write_log(log)

        return {"FINISHED"}


class GRAVITAS_OT_build_animated_target_from_selected_clip(Operator):
    bl_idname = "gravitas.build_animated_target_from_selected_clip"
    bl_label = "Build Animated Target From Selected Clip"
    bl_description = (
        "Imports a target character USDZ, applies the selected manifest JockAnim "
        "clip to its actual skeleton, and optionally exports the animated target."
    )
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        log = []

        try:
            clip_payload, _summary, _clip_path = _load_selected_manifest_clip_payload(
                settings,
                log,
            )

            rig = _json_load(bpy.path.abspath(settings.rig_json_path))

            skeleton_map = _load_skeleton_map_or_identity(
                bpy.path.abspath(settings.skeleton_map_path),
                rig,
            )

            _imported, _collection, armature = _import_target_character(
                settings.target_character_file_path,
                log,
            )

            settings.target_detected_armature_name = armature.name

            result = _apply_jockanim_clip_to_target_armature(
                settings=settings,
                armature=armature,
                clip_payload=clip_payload,
                rig_json=rig,
                skeleton_map=skeleton_map,
                log=log,
            )

            export_path = _export_animated_target(
                settings=settings,
                armature=armature,
                log=log,
            )

            _log_append(log, "")
            _log_append(log, "Animated target build complete.")
            _log_append(log, f"Target armature: {armature.name}")
            _log_append(
                log,
                f"Selected clip: {clip_payload.get('clip_id', 'unknown')}",
            )
            _log_append(log, f"Pose policy: {settings.target_pose_policy}")
            _log_append(log, f"Matched joints: {result['matched_joints']}")
            _log_append(log, f"Export: {export_path or 'left in Blender scene'}")

            _safe_report(
                self,
                {"INFO"},
                "Built animated target from selected clip.",
            )

        except Exception as error:
            _log_append(log, "ERROR")
            _log_append(log, str(error))
            _log_append(log, traceback.format_exc())
            _safe_report(self, {"ERROR"}, str(error))
            return {"CANCELLED"}

        finally:
            if settings.log_text:
                _write_log(log)

        return {"FINISHED"}


class GRAVITAS_OT_cleanup_donor_import(Operator):
    bl_idname = "gravitas.cleanup_donor_import"
    bl_label = "Cleanup Donor Import"
    bl_description = "Deletes temporary donor import collection."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        _delete_temp_collection()
        context.scene.gravitas_animation_library.detected_armature_name = ""
        self.report({"INFO"}, "Cleaned up donor import.")
        return {"FINISHED"}


class GRAVITAS_OT_create_locomotion_root(Operator):
    bl_idname = "gravitas.create_locomotion_root"
    bl_label = "Create / Update Locomotion Root"
    bl_description = "Creates the Jock locomotion authoring root and applies current UI values."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        log = []

        try:
            root = _get_locomotion_root()
            _ensure_locomotion_root_defaults(root)

            root["forward_meters"] = float(settings.locomotion_forward_meters)
            root["side_meters"] = float(settings.locomotion_side_meters)
            root["vertical_meters"] = float(settings.locomotion_vertical_meters)
            root["yaw_degrees"] = float(settings.locomotion_yaw_degrees)

            _apply_locomotion_root_preview_transform(root)

            bpy.ops.object.select_all(action="DESELECT")
            root.select_set(True)
            context.view_layer.objects.active = root

            _log_append(log, "Created / updated JOCK_LOCOMOTION_ROOT.")
            _safe_report(self, {"INFO"}, "Created / updated JOCK_LOCOMOTION_ROOT.")

        except Exception as error:
            _log_append(log, "ERROR")
            _log_append(log, str(error))
            _log_append(log, traceback.format_exc())
            _safe_report(self, {"ERROR"}, str(error))
            return {"CANCELLED"}

        finally:
            if settings.log_text:
                _write_log(log)

        return {"FINISHED"}


class GRAVITAS_OT_key_locomotion_current_frame(Operator):
    bl_idname = "gravitas.key_locomotion_current_frame"
    bl_label = "Key Locomotion At Current Frame"
    bl_description = "Sets locomotion values on JOCK_LOCOMOTION_ROOT and keys them at the current frame."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        log = []

        try:
            root = _get_locomotion_root()
            _ensure_locomotion_root_defaults(root)

            root["forward_meters"] = float(settings.locomotion_forward_meters)
            root["side_meters"] = float(settings.locomotion_side_meters)
            root["vertical_meters"] = float(settings.locomotion_vertical_meters)
            root["yaw_degrees"] = float(settings.locomotion_yaw_degrees)

            frame = context.scene.frame_current
            _key_locomotion_root(root, frame, log)

            _safe_report(self, {"INFO"}, f"Keyed locomotion at frame {frame}.")

        except Exception as error:
            _log_append(log, "ERROR")
            _log_append(log, str(error))
            _log_append(log, traceback.format_exc())
            _safe_report(self, {"ERROR"}, str(error))
            return {"CANCELLED"}

        finally:
            if settings.log_text:
                _write_log(log)

        return {"FINISHED"}


class GRAVITAS_OT_clear_locomotion_keys(Operator):
    bl_idname = "gravitas.clear_locomotion_keys"
    bl_label = "Clear Locomotion Keys"
    bl_description = "Clears all locomotion root keyframes."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        log = []

        try:
            root = _get_locomotion_root()
            _clear_locomotion_keys(root, log)
            _safe_report(self, {"INFO"}, "Cleared locomotion keys.")

        except Exception as error:
            _log_append(log, "ERROR")
            _log_append(log, str(error))
            _safe_report(self, {"ERROR"}, str(error))
            return {"CANCELLED"}

        finally:
            if settings.log_text:
                _write_log(log)

        return {"FINISHED"}


class GRAVITAS_OT_refresh_locomotion_preview_path(Operator):
    bl_idname = "gravitas.refresh_locomotion_preview_path"
    bl_label = "Refresh Locomotion Preview Path"
    bl_description = "Draws a curve showing the authored locomotion path."
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        settings = context.scene.gravitas_animation_library
        log = []

        try:
            _refresh_locomotion_preview_path(
                start_frame=int(settings.source_start_frame),
                end_frame=int(settings.source_end_frame),
                sample_every_n=int(settings.locomotion_preview_sample_every_n),
                log=log,
            )

            _safe_report(self, {"INFO"}, "Refreshed locomotion preview path.")

        except Exception as error:
            _log_append(log, "ERROR")
            _log_append(log, str(error))
            _log_append(log, traceback.format_exc())
            _safe_report(self, {"ERROR"}, str(error))
            return {"CANCELLED"}

        finally:
            if settings.log_text:
                _write_log(log)

        return {"FINISHED"}


# ============================================================
# UI Panel
# ============================================================

class GRAVITAS_PT_animation_library_panel(Panel):
    bl_label = "Animation Library"
    bl_idname = "GRAVITAS_PT_animation_library_panel"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Gravitas"

    def draw(self, context):
        layout = self.layout
        settings = context.scene.gravitas_animation_library

        root_box = layout.box()
        root_box.label(text="Library / Rig", icon="FILE_FOLDER")
        root_box.prop(settings, "animation_library_root")
        root_box.prop(settings, "rig_json_path")
        root_box.prop(settings, "skeleton_map_path")

        browser_box = layout.box()
        browser_box.label(text="Library Browser", icon="FILE_FOLDER")
        browser_box.operator(
            GRAVITAS_OT_load_animation_manifest.bl_idname,
            text="Load Manifest",
            icon="FILE_FOLDER",
        )
        browser_box.prop(settings, "selected_manifest_clip_id")
        browser_box.operator(
            GRAVITAS_OT_load_selected_clip_metadata.bl_idname,
            text="Load Selected Clip Metadata",
            icon="IMPORT",
        )
        browser_box.operator(
            GRAVITAS_OT_delete_selected_clip_from_manifest.bl_idname,
            text="Delete From Manifest",
            icon="TRASH",
        )
        browser_box.prop(settings, "overwrite_existing_clip")
        browser_box.label(
            text=f"Path: {settings.loaded_manifest_clip_relative_path or 'none'}"
        )

        target_box = layout.box()
        target_box.label(
            text="Apply Clip To Target Character",
            icon="OUTLINER_OB_ARMATURE",
        )
        target_box.prop(settings, "target_character_file_path")
        target_box.label(
            text=f"Target: {settings.target_detected_armature_name or 'none'}"
        )
        target_box.prop(settings, "target_pose_policy")

        if settings.target_pose_policy == "PRESERVE_TARGET_SKELETON":
            target_box.prop(settings, "target_rotation_delta_order")
            target_box.prop(settings, "target_apply_root_translation")
            target_box.prop(settings, "target_ignore_root_vertical")
            target_box.prop(settings, "target_ignore_non_root_translations")
            target_box.prop(settings, "target_ignore_scales")

        target_box.prop(settings, "target_clear_existing_animation")
        target_box.prop(settings, "target_export_after_apply")

        if settings.target_export_after_apply:
            target_box.prop(settings, "target_export_format")
            if settings.target_export_format != "NONE":
                target_box.prop(settings, "target_output_file_path")

        target_box.operator(
            GRAVITAS_OT_build_animated_target_from_selected_clip.bl_idname,
            text="Build Animated Target From Selected Clip",
            icon="ARMATURE_DATA",
        )

        donor_box = layout.box()
        donor_box.label(text="Donor Animation", icon="ARMATURE_DATA")
        donor_box.prop(settings, "donor_file_path")
        donor_box.operator(
            GRAVITAS_OT_import_donor_animation.bl_idname,
            text="Import Donor Animation",
            icon="IMPORT",
        )
        donor_box.label(text=f"Detected: {settings.detected_armature_name or 'none'}")
        donor_box.operator(
            GRAVITAS_OT_validate_donor_rig.bl_idname,
            text="Validate Donor Rig",
            icon="CHECKMARK",
        )
        donor_box.operator(
            GRAVITAS_OT_cleanup_donor_import.bl_idname,
            text="Cleanup Donor Import",
            icon="TRASH",
        )

        clip_box = layout.box()
        clip_box.label(text="Clip Metadata", icon="ACTION")
        clip_box.prop(settings, "clip_id")
        clip_box.prop(settings, "display_name")
        clip_box.prop(settings, "description")
        clip_box.prop(settings, "author")
        clip_box.prop(settings, "source_character_id")
        clip_box.prop(settings, "output_category_folder")

        range_box = layout.box()
        range_box.label(text="Frame Range / Sampling", icon="TIME")
        range_box.prop(settings, "source_start_frame")
        range_box.prop(settings, "source_end_frame")
        range_box.prop(settings, "source_fps")
        range_box.prop(settings, "sample_every_n_frames")
        range_box.prop(settings, "looping")
        range_box.prop(settings, "include_translations")
        range_box.prop(settings, "include_rotations")
        range_box.prop(settings, "include_scales")

        locomotion_box = layout.box()
        locomotion_box.label(text="Locomotion", icon="TRACKING")
        locomotion_box.prop(settings, "locomotion_type")
        locomotion_box.prop(settings, "world_space_motion")
        locomotion_box.prop(settings, "recommended_speed_mps")
        locomotion_box.prop(settings, "turn_degrees")
        locomotion_box.prop(settings, "root_translation_policy")
        locomotion_box.prop(settings, "default_transition_frames")

        locomotion_author_box = layout.box()
        locomotion_author_box.label(text="Locomotion Authoring", icon="EMPTY_ARROWS")
        locomotion_author_box.prop(settings, "locomotion_enabled")
        locomotion_author_box.prop(settings, "locomotion_forward_meters")
        locomotion_author_box.prop(settings, "locomotion_side_meters")
        locomotion_author_box.prop(settings, "locomotion_vertical_meters")
        locomotion_author_box.prop(settings, "locomotion_yaw_degrees")
        locomotion_author_box.prop(settings, "locomotion_start_mode")
        locomotion_author_box.prop(settings, "locomotion_preview_sample_every_n")

        locomotion_author_box.operator(
            GRAVITAS_OT_create_locomotion_root.bl_idname,
            text="Create / Update Locomotion Root",
            icon="EMPTY_ARROWS",
        )

        locomotion_author_box.operator(
            GRAVITAS_OT_key_locomotion_current_frame.bl_idname,
            text="Key Locomotion At Current Frame",
            icon="KEY_HLT",
        )

        locomotion_author_box.operator(
            GRAVITAS_OT_refresh_locomotion_preview_path.bl_idname,
            text="Refresh Locomotion Preview Path",
            icon="CURVE_PATH",
        )

        locomotion_author_box.operator(
            GRAVITAS_OT_clear_locomotion_keys.bl_idname,
            text="Clear Locomotion Keys",
            icon="TRASH",
        )

        tags_box = layout.box()
        tags_box.label(text="Tags", icon="BOOKMARKS")
        tags_box.prop(settings, "category_tags")
        tags_box.prop(settings, "emotion_tags")
        tags_box.prop(settings, "threat_tags")
        tags_box.prop(settings, "story_tags")
        tags_box.prop(settings, "allowed_states")

        quality_box = layout.box()
        quality_box.label(text="Quality", icon="CHECKMARK")
        quality_box.prop(settings, "approved_for_runtime")
        quality_box.prop(settings, "approved_for_episode")
        quality_box.prop(settings, "debug_only")
        quality_box.prop(settings, "log_text")

        maintenance_box = layout.box()
        maintenance_box.label(text="Source Rig Maintenance", icon="ARMATURE_DATA")
        maintenance_box.operator(
            GRAVITAS_OT_backfill_dad_source_rig_to_existing_clips.bl_idname,
            text="Backfill Dad Source Rig To Existing Clips",
            icon="FILE_REFRESH",
        )

        layout.separator()

        export_type_box = layout.box()
        export_type_box.label(text="Export Type", icon="ACTION")
        export_type_box.prop(settings, "export_type")

        if settings.export_type == "SUB_ANIMATION_OVERRIDE":
            export_type_box.label(text="Sub Animation Override", icon="CONSTRAINT_BONE")
            export_type_box.prop(settings, "blend_in_frames")
            export_type_box.prop(settings, "blend_out_frames")

            row = export_type_box.row(align=True)
            row.operator(
                GRAVITAS_OT_refresh_sub_animation_joint_list.bl_idname,
                text="Refresh Joint List",
                icon="FILE_REFRESH",
            )
            row.operator(
                GRAVITAS_OT_clear_sub_animation_joint_selection.bl_idname,
                text="Clear",
                icon="X",
            )

            _ensure_sub_animation_joint_list(settings)

            joint_box = export_type_box.box()
            joint_box.label(text="Affected Joints")

            for item in settings.sub_animation_joints:
                row = joint_box.row(align=True)
                row.prop(item, "selected", text="")
                row.label(text=item.joint_name)

        layout.prop(settings, "mirror_animation")
        layout.operator(
            GRAVITAS_OT_export_jock_clip.bl_idname,
            text="Export JockAnim Clip + Update Manifest",
            icon="EXPORT",
        )


# ============================================================
# Registration
# ============================================================

classes = (
    GravitasSubAnimationJointItem,
    GravitasAnimationLibrarySettings,
    GRAVITAS_OT_refresh_sub_animation_joint_list,
    GRAVITAS_OT_clear_sub_animation_joint_selection,
    GRAVITAS_OT_load_animation_manifest,
    GRAVITAS_OT_load_selected_clip_metadata,
    GRAVITAS_OT_delete_selected_clip_from_manifest,
    GRAVITAS_OT_import_donor_animation,
    GRAVITAS_OT_validate_donor_rig,
    GRAVITAS_OT_export_jock_clip,
    GRAVITAS_OT_backfill_dad_source_rig_to_existing_clips,
    GRAVITAS_OT_build_animated_target_from_selected_clip,
    GRAVITAS_OT_cleanup_donor_import,
    GRAVITAS_OT_create_locomotion_root,
    GRAVITAS_OT_key_locomotion_current_frame,
    GRAVITAS_OT_clear_locomotion_keys,
    GRAVITAS_OT_refresh_locomotion_preview_path,
    GRAVITAS_PT_animation_library_panel,
)


def _apply_default_library_paths_if_empty():
    try:
        settings = bpy.context.scene.gravitas_animation_library
    except Exception:
        return

    if not settings.animation_library_root:
        settings.animation_library_root = DEFAULT_ANIMATION_LIBRARY_ROOT

    if not settings.rig_json_path:
        settings.rig_json_path = DEFAULT_RIG_JSON_PATH

    if not settings.skeleton_map_path:
        settings.skeleton_map_path = DEFAULT_SKELETON_MAP_PATH


def register():
    for cls in classes:
        try:
            bpy.utils.register_class(cls)
        except ValueError:
            pass

    bpy.types.Scene.gravitas_animation_library = PointerProperty(
        type=GravitasAnimationLibrarySettings
    )
    _apply_default_library_paths_if_empty()


def unregister():
    if hasattr(bpy.types.Scene, "gravitas_animation_library"):
        try:
            del bpy.types.Scene.gravitas_animation_library
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

    print("Gravitas Animation Library Tool v2.0 registered.")
    print("Open 3D Viewport > N-panel > Gravitas > Animation Library.")

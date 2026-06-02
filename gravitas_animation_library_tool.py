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
import json
import math
import os
import re
import traceback
from datetime import datetime, timezone

from bpy.props import (
    BoolProperty,
    EnumProperty,
    FloatProperty,
    IntProperty,
    PointerProperty,
    StringProperty,
)
from bpy.types import Operator, Panel, PropertyGroup


TEMP_COLLECTION_NAME = "__GRAVITAS_ANIMATION_DONOR_TEMP__"
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
    mirrored["locomotion"] = _mirror_locomotion_tracks(
        clip_payload.get("locomotion", {})
    )

    source = mirrored.get("source", {})
    source["mirrored_from_clip_id"] = source_clip_id
    source["mirror_plane"] = "X"
    mirrored["source"] = source

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
):
    if end_frame < start_frame:
        raise RuntimeError(f"Bad frame range: {start_frame} -> {end_frame}")

    sample_every_n = max(int(sample_every_n), 1)

    canonical_leafs = _rig_leaf_names(rig_json)
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

    summary = {
        "clip_id": clip_id,
        "display_name": clip_payload["display_name"],
        "relative_path": relative_path,
        "rig_id": clip_payload["rig_id"],
        "rig_version": clip_payload["rig_version"],
        "pose_mode": clip_payload["pose_mode"],
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

    donor_file_path: StringProperty(
        name="Donor Animation File",
        subtype="FILE_PATH",
        default="",
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


# ============================================================
# Operators
# ============================================================

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

            clip_payload = {
                "schema": "com.gravitas.jockanim.v0",
                "clip_id": clip_id,
                "display_name": settings.display_name.strip() or clip_id,
                "rig_id": rig["rig_id"],
                "rig_version": rig["version"],
                "pose_mode": "absoluteLocal",
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
                "timing": {
                    "fps": fps,
                    "duration_seconds": duration_seconds,
                    "looping": bool(settings.looping),
                },
                "joints": _rig_leaf_names(rig),
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

        layout.separator()

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
    GravitasAnimationLibrarySettings,
    GRAVITAS_OT_load_animation_manifest,
    GRAVITAS_OT_load_selected_clip_metadata,
    GRAVITAS_OT_delete_selected_clip_from_manifest,
    GRAVITAS_OT_import_donor_animation,
    GRAVITAS_OT_validate_donor_rig,
    GRAVITAS_OT_export_jock_clip,
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

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Iterable


def _vec(value: Iterable[float]) -> tuple[float, float, float]:
    values = tuple(float(component) for component in value)
    if len(values) != 3 or not all(math.isfinite(component) for component in values):
        raise ValueError("camera framing contains a nonfinite vector")
    return values


def _add(a: tuple[float, float, float], b: tuple[float, float, float]):
    return tuple(a[index] + b[index] for index in range(3))


def _sub(a: tuple[float, float, float], b: tuple[float, float, float]):
    return tuple(a[index] - b[index] for index in range(3))


def _scale(value: tuple[float, float, float], scalar: float):
    return tuple(component * scalar for component in value)


def _dot(a: tuple[float, float, float], b: tuple[float, float, float]) -> float:
    return sum(a[index] * b[index] for index in range(3))


def _cross(a: tuple[float, float, float], b: tuple[float, float, float]):
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _length(value: tuple[float, float, float]) -> float:
    return math.sqrt(_dot(value, value))


def _normalized(value: tuple[float, float, float]):
    magnitude = _length(value)
    if not math.isfinite(magnitude) or magnitude <= 0.000_001:
        raise ValueError("camera framing axis is degenerate")
    return _scale(value, 1 / magnitude)


def _axis(name: str) -> tuple[float, float, float]:
    axes = {
        "x": (1.0, 0.0, 0.0),
        "y": (0.0, 1.0, 0.0),
        "z": (0.0, 0.0, 1.0),
        "-x": (-1.0, 0.0, 0.0),
        "-y": (0.0, -1.0, 0.0),
        "-z": (0.0, 0.0, -1.0),
    }
    try:
        return axes[name.lower()]
    except KeyError as error:
        raise ValueError(f"unsupported camera control axis: {name}") from error


def _matrix_multiply(a: list[list[float]], b: list[list[float]]):
    return [
        [sum(a[row][index] * b[index][column] for index in range(4))
         for column in range(4)]
        for row in range(4)
    ]


def _column_major(matrix: list[list[float]]) -> list[float]:
    return [
        0.0 if matrix[row][column] == 0 else matrix[row][column]
        for column in range(4)
        for row in range(4)
    ]


@dataclass(frozen=True)
class CameraFraming:
    control_prim_path: str
    center: tuple[float, float, float]
    right: tuple[float, float, float]
    up: tuple[float, float, float]
    forward: tuple[float, float, float]
    half_extents: tuple[float, float, float]
    bounds_minimum: tuple[float, float, float]
    bounds_maximum: tuple[float, float, float]
    subject_from_camera: list[float]
    clip_from_camera: list[float]
    clip_from_subject: list[float]
    field_of_view_degrees: float
    near_meters: float
    far_meters: float
    framing_padding: float

    def descriptor_payload(self, source_asset: str, source_sha256: str) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "sourceAsset": source_asset,
            "sourceAssetSHA256": source_sha256,
            "controlPrimPath": self.control_prim_path,
            "centerSubjectMeters": list(self.center),
            "rightAxisSubject": list(self.right),
            "upAxisSubject": list(self.up),
            "forwardAxisSubject": list(self.forward),
            "halfExtentsMeters": list(self.half_extents),
        }


def resolve_camera_framing(
    stage: Any,
    subject_mesh_path: str,
    control: dict[str, Any],
) -> CameraFraming:
    from pxr import Gf, UsdGeom

    control_path = control["primPath"]
    mesh_prim = stage.GetPrimAtPath(subject_mesh_path)
    control_prim = stage.GetPrimAtPath(control_path)
    control_mesh = UsdGeom.Mesh(control_prim)
    if not mesh_prim or not control_mesh:
        raise ValueError(f"camera framing control is not a mesh: {control_path}")
    points = control_mesh.GetPointsAttr().Get()
    counts = list(control_mesh.GetFaceVertexCountsAttr().Get() or [])
    indices = list(control_mesh.GetFaceVertexIndicesAttr().Get() or [])
    if points is None or len(points) != 8 or counts != [4] * 6 or len(indices) != 24:
        raise ValueError("camera framing control must remain one eight-point, six-quad cube")

    local_points = [_vec(point) for point in points]
    local_minimum = tuple(min(point[axis] for point in local_points) for axis in range(3))
    local_maximum = tuple(max(point[axis] for point in local_points) for axis in range(3))
    local_center = tuple(
        (local_minimum[axis] + local_maximum[axis]) * 0.5 for axis in range(3)
    )
    local_half = tuple(
        (local_maximum[axis] - local_minimum[axis]) * 0.5 for axis in range(3)
    )
    if not all(half > 0 for half in local_half):
        raise ValueError("camera framing control has a zero local extent")

    xform_cache = UsdGeom.XformCache()
    world_from_subject = xform_cache.GetLocalToWorldTransform(mesh_prim)
    subject_from_world = world_from_subject.GetInverse()
    world_from_control = xform_cache.GetLocalToWorldTransform(control_prim)

    def subject_point(local: tuple[float, float, float]):
        world = world_from_control.Transform(Gf.Vec3d(*local))
        return _vec(subject_from_world.Transform(world))

    center = subject_point(local_center)

    def subject_axis(name: str):
        local_axis = _axis(name)
        endpoint = subject_point(_add(local_center, local_axis))
        vector = _sub(endpoint, center)
        return _normalized(vector), _length(vector)

    right, right_scale = subject_axis(control["rightLocalAxis"])
    forward, forward_scale = subject_axis(control["forwardLocalAxis"])
    up, up_scale = subject_axis(control["upLocalAxis"])
    if max(abs(_dot(right, up)), abs(_dot(right, forward)), abs(_dot(up, forward))) > 0.001:
        raise ValueError("camera framing control axes are not orthogonal")
    if _dot(_cross(forward, up), right) < 0.999:
        raise ValueError("camera framing control axes are not right-handed")

    axis_index = {"x": 0, "y": 1, "z": 2}
    width_half = local_half[axis_index[control["rightLocalAxis"].lstrip("-")]] * right_scale
    height_half = local_half[axis_index[control["upLocalAxis"].lstrip("-")]] * up_scale
    depth_half = local_half[axis_index[control["forwardLocalAxis"].lstrip("-")]] * forward_scale
    half_extents = (width_half, height_half, depth_half)
    if not all(0.005 <= value <= 0.375 for value in half_extents):
        raise ValueError(f"camera framing cube is not head-sized: {half_extents}")

    subject_corners = [subject_point(point) for point in local_points]
    bounds_minimum = tuple(min(point[axis] for point in subject_corners) for axis in range(3))
    bounds_maximum = tuple(max(point[axis] for point in subject_corners) for axis in range(3))

    fov = float(control["verticalFieldOfViewDegrees"])
    near = float(control["nearMeters"])
    far = float(control["farMeters"])
    padding = float(control["framingPadding"])
    if not 15 <= fov <= 60 or near <= 0 or far <= near or padding < 1:
        raise ValueError("camera framing projection parameters are invalid")
    frame_distance = max(width_half, height_half) * padding / math.tan(math.radians(fov) * 0.5)
    position = _sub(center, _scale(forward, depth_half + frame_distance))
    back = _scale(forward, -1)

    subject_from_camera_rows = [
        [right[0], up[0], back[0], position[0]],
        [right[1], up[1], back[1], position[1]],
        [right[2], up[2], back[2], position[2]],
        [0.0, 0.0, 0.0, 1.0],
    ]
    camera_from_subject_rows = [
        [right[0], right[1], right[2], -_dot(right, position)],
        [up[0], up[1], up[2], -_dot(up, position)],
        [back[0], back[1], back[2], -_dot(back, position)],
        [0.0, 0.0, 0.0, 1.0],
    ]
    y = 1 / math.tan(math.radians(fov) * 0.5)
    z = far / (near - far)
    clip_from_camera_rows = [
        [y, 0.0, 0.0, 0.0],
        [0.0, y, 0.0, 0.0],
        [0.0, 0.0, z, z * near],
        [0.0, 0.0, -1.0, 0.0],
    ]
    clip_from_subject_rows = _matrix_multiply(
        clip_from_camera_rows,
        camera_from_subject_rows,
    )

    center_clip = [
        sum(clip_from_subject_rows[row][column] * (*center, 1.0)[column]
            for column in range(4))
        for row in range(4)
    ]
    if center_clip[3] <= 0 or abs(center_clip[0] / center_clip[3]) > 0.000_01 or \
            abs(center_clip[1] / center_clip[3]) > 0.000_01:
        raise ValueError("camera framing does not center the control cube")

    return CameraFraming(
        control_prim_path=control_path,
        center=center,
        right=right,
        up=up,
        forward=forward,
        half_extents=half_extents,
        bounds_minimum=bounds_minimum,
        bounds_maximum=bounds_maximum,
        subject_from_camera=_column_major(subject_from_camera_rows),
        clip_from_camera=_column_major(clip_from_camera_rows),
        clip_from_subject=_column_major(clip_from_subject_rows),
        field_of_view_degrees=fov,
        near_meters=near,
        far_meters=far,
        framing_padding=padding,
    )

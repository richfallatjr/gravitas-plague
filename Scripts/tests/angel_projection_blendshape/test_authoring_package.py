import tempfile
import unittest
import struct
import zlib
import zipfile
from pathlib import Path

from pxr import Gf, Sdf, Usd, UsdGeom, UsdSkel, UsdUtils, Vt

from Scripts.angel_projection_blendshape.package import build_staged_package
from Scripts.angel_projection_blendshape.validation import validate_pair


class AuthoringPackageTests(unittest.TestCase):
    def test_sparse_target_is_authored_and_idempotently_replaced(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            base = self.make_asset(directory, "base", jaw_delta=0)
            target = self.make_asset(
                directory,
                "target",
                jaw_delta=-0.1,
                include_authoring_controls=True,
            )
            descriptor = {
                "sparseOffsetEpsilonMeters": 0.000001,
                "maximumDisplacementAsHeadBoundsFraction": 0.2,
                "skelRootPrimPath": "/root",
                "meshBindings": [{
                    "basePrimPath": "/root/mesh",
                    "targetPrimPath": "/root/mesh",
                }],
                "cameraFramingControl": {
                    "primPath": "/root/face_proxy/Cube_001",
                    "rightLocalAxis": "x",
                    "forwardLocalAxis": "y",
                    "upLocalAxis": "z",
                    "verticalFieldOfViewDegrees": 30,
                    "nearMeters": 0.02,
                    "farMeters": 20,
                    "framingPadding": 1.12,
                },
                "projectionMaskPackagePath": "textures/projection-mask.png",
            }
            first_validation = validate_pair(base, target, descriptor)
            first = directory / "first.usdz"
            build_staged_package(
                base,
                first_validation,
                "jawOpenProjection",
                first,
            )
            self.assert_binding(first)

            second_validation = validate_pair(first, target, descriptor)
            second = directory / "second.usdz"
            build_staged_package(
                first,
                second_validation,
                "jawOpenProjection",
                second,
            )
            self.assert_binding(second)

    def make_asset(
        self,
        directory: Path,
        name: str,
        jaw_delta: float,
        include_authoring_controls: bool = False,
    ) -> Path:
        layer = directory / f"{name}.usda"
        stage = Usd.Stage.CreateNew(str(layer))
        root = UsdGeom.Xform.Define(stage, "/root")
        stage.SetDefaultPrim(root.GetPrim())
        UsdGeom.SetStageMetersPerUnit(stage, 1)
        UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
        mesh = UsdGeom.Mesh.Define(stage, "/root/mesh")
        mesh.CreatePointsAttr(Vt.Vec3fArray([
            Gf.Vec3f(0, 0, 0),
            Gf.Vec3f(1, 0, 0),
            Gf.Vec3f(0, 1 + jaw_delta, 0),
        ]))
        mesh.CreateFaceVertexCountsAttr(Vt.IntArray([3]))
        mesh.CreateFaceVertexIndicesAttr(Vt.IntArray([0, 1, 2]))
        mesh.CreateExtentAttr(Vt.Vec3fArray([
            Gf.Vec3f(0, min(0, jaw_delta), 0),
            Gf.Vec3f(1, 1, 0),
        ]))
        if include_authoring_controls:
            proxy = UsdGeom.Mesh.Define(stage, "/root/face_proxy/Cube_001")
            proxy.CreatePointsAttr(Vt.Vec3fArray([
                Gf.Vec3f(-0.1, -0.1, -0.1), Gf.Vec3f(0.1, -0.1, -0.1),
                Gf.Vec3f(0.1, 0.1, -0.1), Gf.Vec3f(-0.1, 0.1, -0.1),
                Gf.Vec3f(-0.1, -0.1, 0.1), Gf.Vec3f(0.1, -0.1, 0.1),
                Gf.Vec3f(0.1, 0.1, 0.1), Gf.Vec3f(-0.1, 0.1, 0.1),
            ]))
            proxy.CreateFaceVertexCountsAttr(Vt.IntArray([4] * 6))
            proxy.CreateFaceVertexIndicesAttr(Vt.IntArray([
                0, 1, 2, 3, 4, 7, 6, 5, 0, 4, 5, 1,
                1, 5, 6, 2, 2, 6, 7, 3, 4, 0, 3, 7,
            ]))
            mask = directory / "textures" / "projection-mask.png"
            self.write_mask(mask)
            root.GetPrim().CreateAttribute(
                "projectionMask", Sdf.ValueTypeNames.Asset
            ).Set(Sdf.AssetPath("textures/projection-mask.png"))
        stage.GetRootLayer().Save()
        package = directory / f"{name}.usdz"
        self.assertTrue(
            UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(layer)), str(package))
        )
        if include_authoring_controls:
            with zipfile.ZipFile(package, "a", compression=zipfile.ZIP_STORED) as archive:
                archive.write(
                    directory / "textures" / "projection-mask.png",
                    "textures/projection-mask.png",
                )
        return package

    def write_mask(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        width = height = 1024
        scanline = b"\x00" + (b"\xff\xff\xff\xff" * width)
        raw = scanline * height

        def chunk(name: bytes, data: bytes) -> bytes:
            return (
                struct.pack(">I", len(data)) + name + data +
                struct.pack(">I", zlib.crc32(name + data) & 0xFFFF_FFFF)
            )

        path.write_bytes(
            b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw, level=9)) +
            chunk(b"IEND", b"")
        )

    def assert_binding(self, path: Path) -> None:
        stage = Usd.Stage.Open(str(path))
        binding = UsdSkel.BindingAPI(stage.GetPrimAtPath("/root/mesh"))
        names = list(binding.GetBlendShapesAttr().Get())
        targets = list(binding.GetBlendShapeTargetsRel().GetTargets())
        self.assertEqual(names, ["jawOpenProjection"])
        self.assertEqual(len(targets), 1)
        shape = UsdSkel.BlendShape(stage.GetPrimAtPath(targets[0]))
        self.assertEqual(len(shape.GetOffsetsAttr().Get()), 1)
        self.assertEqual(list(shape.GetPointIndicesAttr().Get()), [2])


if __name__ == "__main__":
    unittest.main()

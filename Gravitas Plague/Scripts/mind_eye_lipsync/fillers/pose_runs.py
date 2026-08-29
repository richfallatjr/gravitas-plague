from __future__ import annotations

POSE_BITS = {"rest": 1, "small": 2, "wide": 4, "round": 8, "teeth": 16}


def compact(poses: list[str], evidence: list[int]) -> list[dict]:
    if not poses or len(poses) != len(evidence): raise ValueError("Invalid filler pose stream")
    runs = []
    start, pose, mask = 0, poses[0], evidence[0]
    for index in range(1, len(poses)):
        if poses[index] != pose:
            runs.append({"startFrame": start, "endFrameExclusive": index,
                         "pose": pose, "evidenceMask": mask})
            start, pose, mask = index, poses[index], evidence[index]
        else:
            mask |= evidence[index]
    runs.append({"startFrame": start, "endFrameExclusive": len(poses),
                 "pose": pose, "evidenceMask": mask})
    return runs

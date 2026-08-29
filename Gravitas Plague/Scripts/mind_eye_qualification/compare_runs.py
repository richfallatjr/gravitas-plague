from __future__ import annotations

from typing import Any, Iterable

from .metrics import bytes_to_mib, checkpoint_footprint, median


def compare_control(control_reports: Iterable[dict], enabled_reports: Iterable[dict]) -> dict[str, Any]:
    controls = [checkpoint_footprint(report, "storySystemsReady") for report in control_reports]
    enabled = [checkpoint_footprint(report, "afterVisualAttach") for report in enabled_reports]
    controls = [value for value in controls if value is not None]
    enabled = [value for value in enabled if value is not None]
    control_median = median(controls)
    enabled_median = median(enabled)
    increment = None
    if control_median is not None and enabled_median is not None:
        increment = bytes_to_mib(enabled_median - control_median)
    return {
        "controlMedianPhysicalFootprintBytes": control_median,
        "enabledMedianPhysicalFootprintBytes": enabled_median,
        "activeIncrementMiB": increment,
    }


def compare_qwen(control_reports: Iterable[dict], overlap_reports: Iterable[dict]) -> dict[str, Any]:
    controls = [checkpoint_footprint(report, "qwenGenerationPeak") for report in control_reports]
    overlaps = [checkpoint_footprint(report, "qwenGenerationPeak") for report in overlap_reports]
    controls = [value for value in controls if value is not None]
    overlaps = [value for value in overlaps if value is not None]
    control_median = median(controls)
    overlap_median = median(overlaps)
    increment = None
    if control_median is not None and overlap_median is not None:
        increment = bytes_to_mib(overlap_median - control_median)
    return {
        "qwenControlMedianPhysicalFootprintBytes": control_median,
        "qwenOverlapMedianPhysicalFootprintBytes": overlap_median,
        "qwenOverlapIncrementMiB": increment,
    }

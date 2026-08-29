from mind_eye_qualification.compare_runs import compare_control
from mind_eye_qualification.release_matrix import evaluate_matrix


def report(checkpoint, footprint):
    return {"events": [{"checkpoint": checkpoint, "resource": {"process": {"physicalFootprintBytes": footprint}}}]}


def test_control_comparison_uses_matching_checkpoints():
    result = compare_control(
        [report("storySystemsReady", 100 * 1_048_576)],
        [report("afterVisualAttach", 120 * 1_048_576)],
    )
    assert result["activeIncrementMiB"] == 20


def test_matrix_infers_unambiguous_feature_mode_from_runtime_report():
    matrix = {
        "requiredRuns": [{
            "scenario": "controlStoryScene",
            "configuration": "releaseNoDebugger",
            "featureMode": "disabledControl",
            "minimumRepetitions": 1,
        }]
    }
    reports = [{"run": {
        "scenario": "controlStoryScene",
        "configuration": "releaseNoDebugger",
    }}]
    assert evaluate_matrix(reports, matrix)["status"] == "PASS"

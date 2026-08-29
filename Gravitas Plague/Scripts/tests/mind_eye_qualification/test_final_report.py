from mind_eye_qualification.final_report import final_decision, manual_review_template


def test_missing_device_evidence_is_blocked_not_pass():
    passing = {"status": "PASS"}
    review = manual_review_template()
    for item in review["items"]:
        item["status"] = "pass"
    review.update({"reviewer": "R", "device": "Vision Pro", "visionOS": "27"})
    inputs = {name: passing for name in (
        "sourceAudit", "builtAppAudit", "archiveAudit", "thinningAudit",
        "reportValidation", "budgetEvaluation", "automatedTests", "matrixEvaluation",
    )}
    inputs["manualVisualReview"] = review
    inputs["testFlightActual"] = False
    result = final_decision(inputs)
    assert result["decision"] == "BLOCKED"
    assert "actualTestFlight" in result["blockers"]

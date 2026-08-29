from mind_eye_qualification.built_bundle_audit import find_unique_app


def test_unique_app_rejects_ambiguous_search(tmp_path):
    (tmp_path / "A.app").mkdir()
    (tmp_path / "B.app").mkdir()
    try:
        find_unique_app(tmp_path)
    except ValueError as error:
        assert "found 2" in str(error)
    else:
        raise AssertionError("ambiguous app search must fail")

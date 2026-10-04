import pictunnel_ml


def test_version_is_semver_like():
    parts = pictunnel_ml.__version__.split(".")
    assert len(parts) == 3
    assert all(p.isdigit() for p in parts)

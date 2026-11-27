"""The official Redis logo is a trademark asset: never committed, shown only if the user put it in
flask/static/brand/ (downloaded from brand.redis.io). The page works without it."""


def test_no_logo_file_no_img(client, app_module, monkeypatch, tmp_path):
    monkeypatch.setattr(app_module, "BRAND_DIR", tmp_path)
    html = client.get("/").get_data(as_text=True)
    assert "Redis_Logo_Red_RGB.svg" not in html
    assert "chaos-header" in html          # header still there, just without the image


def test_logo_file_is_shown(client, app_module, monkeypatch, tmp_path):
    (tmp_path / "Redis_Logo_Red_RGB.svg").write_text("<svg xmlns='http://www.w3.org/2000/svg'/>")
    monkeypatch.setattr(app_module, "BRAND_DIR", tmp_path)
    html = client.get("/").get_data(as_text=True)
    assert 'src="/static/brand/Redis_Logo_Red_RGB.svg"' in html
    assert 'alt="Redis"' in html


def test_brand_dir_is_gitignored():
    from pathlib import Path
    ignore = (Path(__file__).resolve().parents[2] / ".gitignore").read_text()
    assert "flask/static/brand/" in ignore

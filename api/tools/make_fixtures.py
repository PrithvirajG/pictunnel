"""Generate tiny real-format media fixtures and their hashing vectors.

Encoders are not byte-for-byte reproducible, so run this only when adding fixtures:
    uv run --with pillow --with pillow-heif --with imageio-ffmpeg python api/tools/make_fixtures.py
"""
import hashlib
import json
import subprocess
from pathlib import Path

import imageio_ffmpeg
import pillow_heif
from PIL import Image

PROTOCOL = Path(__file__).resolve().parent.parent / "protocol"
FIXTURES = PROTOCOL / "fixtures"
EXIF_IFD = 0x8769
DATETIME_ORIGINAL = 0x9003
TAKEN = "2024:05:06 10:00:00"
MAX_BYTES = 64 * 1024


def gradient(size: int = 16) -> Image.Image:
    img = Image.new("RGB", (size, size))
    img.putdata([(x * 16 % 256, y * 16 % 256, 128) for y in range(size) for x in range(size)])
    return img


def make_jpeg(path: Path) -> None:
    img = gradient()
    exif = img.getexif()
    exif.get_ifd(EXIF_IFD)[DATETIME_ORIGINAL] = TAKEN
    img.save(path, "JPEG", quality=85, exif=exif)


def make_heic(path: Path) -> None:
    pillow_heif.register_heif_opener()
    gradient().save(path, "HEIF", quality=50)


def make_mp4(path: Path) -> None:
    subprocess.run(
        [
            imageio_ffmpeg.get_ffmpeg_exe(), "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=size=16x16:rate=10:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-metadata", "creation_time=2024-05-06T10:00:00Z",
            "-movflags", "+faststart", str(path),
        ],
        check=True,
    )


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    makers = {"tiny.jpg": make_jpeg, "tiny.heic": make_heic, "tiny.mp4": make_mp4}
    cases = []
    for name, make in makers.items():
        path = FIXTURES / name
        make(path)
        size = path.stat().st_size
        assert size < MAX_BYTES, f"{name} is {size} bytes; fixtures must stay under 64 KiB"
        ext = name.split(".")[-1]
        # HEIC carries no embedded date; only claim one for jpg/mp4.
        dated = ", dated 2024-05-06T10:00:00Z" if ext in ("jpg", "mp4") else ", no embedded date"
        cases.append(
            {
                "name": "fixture_" + name.replace(".", "_"),
                "description": f"Real {ext.upper()} file ({size} bytes){dated}.",
                "input": {"file": f"fixtures/{name}"},
                "expected_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        )
    doc = {"schema_version": 1, "kind": "hashing", "description": "Hashes of small real media files.", "cases": cases}
    target = PROTOCOL / "vectors" / "hashing" / "fixtures.json"
    target.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8", newline="\n")
    for case in cases:
        print(case["name"], case["expected_sha256"])


if __name__ == "__main__":
    main()

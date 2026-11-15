"""Build the release zip: dist/AuctionJudge-<version>.zip with one AuctionJudge folder inside.

Usage: python build.py
The version comes from the TOC. LICENSE, README.md and CHANGELOG.md are added to the folder.
"""
import pathlib
import re
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent
ADDON = ROOT / "AuctionJudge"
EXTRA = ["LICENSE", "README.md", "CHANGELOG.md"]


def main():
    toc = (ADDON / "AuctionJudge.toc").read_text(encoding="utf-8")
    version = re.search(r"^## Version:\s*(\S+)", toc, re.M).group(1)
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    target = dist / f"AuctionJudge-{version}.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for path in sorted(ADDON.rglob("*")):
            if path.is_file():
                z.write(path, pathlib.PurePosixPath("AuctionJudge") / path.relative_to(ADDON).as_posix())
        for name in EXTRA:
            z.write(ROOT / name, f"AuctionJudge/{name}")
    print(target)
    with zipfile.ZipFile(target) as z:
        for info in z.infolist():
            print(f"  {info.file_size:>7}  {info.filename}")


if __name__ == "__main__":
    main()

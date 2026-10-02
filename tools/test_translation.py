"""Run all offline translation regressions in isolated LuaJIT runtimes.

Install test dependencies: lupa, lxml, tinycss2, cssselect2.
An optional --epub PATH checks a device EPUB read-only as well.
"""

import argparse
from pathlib import Path
import runpy
import sys
import tempfile

from lupa.luajit21 import LuaRuntime


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epub", type=Path, help="Optional device EPUB to inspect without changing it")
    args = parser.parse_args()
    if args.epub and not args.epub.is_file():
        parser.error(f"EPUB does not exist: {args.epub}")
    tools = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="miuread-regression-") as directory:
        for name in ("test_translation.lua", "test_translation_generation.lua", "test_translation_fetch.lua", "test_internal_links.lua"):
            path = tools / name
            lua = LuaRuntime(unpack_returned_tuples=True)
            lua.globals().arg = lua.table_from({0: path.as_posix(), 1: Path(directory).as_posix()})
            lua.execute(path.read_text(encoding="utf-8"), name=path.as_posix())
    previous_argv = sys.argv
    try:
        for name in ("test_translation_archive.py", "test_translation_css.py"):
            path = tools / name
            sys.argv = [str(path)]
            if name == "test_translation_css.py" and args.epub:
                sys.argv.append(str(args.epub.resolve()))
            runpy.run_path(str(path), run_name="__main__")
    finally:
        sys.argv = previous_argv
    print("All offline translation regressions passed")


if __name__ == "__main__":
    main()

"""Recompile the Strata engine after patching, the way Strata's Dockerfile builds it.

Updates engine/BUILD.json's source hash so setup.py treats the patched engine as
current instead of compiling or downloading another one at start.
"""
import json
import os
import shutil
import sys

sys.path.insert(0, os.getcwd())
import setup  # noqa: E402

meta_path = setup.ROOT / "engine" / "BUILD.json"
meta = json.loads(meta_path.read_text())
arch = ";".join(str(a) for a in meta["archs"])

llama = setup.get_llama_cpp()
nvcc, _ = setup.find_nvcc()
build = setup.ROOT / "build"
setup.cmake_build(setup.ROOT, build, "strata",
                  ["-DSTRATA_ENABLE_CUDA=ON", "-DSTRATA_BUILD_TESTS=OFF",
                   f"-DCMAKE_CUDA_ARCHITECTURES={arch}", f"-DCMAKE_CUDA_COMPILER={nvcc}",
                   f"-DSTRATA_GGML_DIR={llama}"], None, "build-strata.bat")
shutil.copy2(build / setup.EXE, setup.ROOT / "engine" / setup.EXE)
shutil.rmtree(build)

meta["src"] = setup.source_hash(setup.ENGINE_SOURCES)
meta_path.write_text(json.dumps(meta, indent=1))
print(f"engine rebuilt for {arch}, src {meta['src']}")

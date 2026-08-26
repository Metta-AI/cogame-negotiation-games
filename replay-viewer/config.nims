import std/[os, strformat, strutils]

let rootDir = currentSourcePath().parentDir().parentDir()
let distDir = rootDir / "replay-viewer" / "dist"

if not dirExists(distDir):
  mkDir(distDir)

switch("path", rootDir / "src")
switch("nimcache", distDir / "nimcache")
switch("threads", "off")
--os:linux
--cpu:wasm32
--cc:clang
--clang.exe:emcc
--clang.linkerexe:emcc
--clang.cpp.exe:emcc
--clang.cpp.linkerexe:emcc
--mm:arc
--exceptions:goto
--define:noSignalHandler
--define:release
# Route allocations through emscripten's malloc; with Nim's own allocator a
# bad free silently poisons the freelists, dlmalloc traps loudly instead.
--define:useMalloc

# ABORTING_MALLOC: with -d:useMalloc Nim never checks malloc for nil, and
# wasm32 has no memory protection, so a failed allocation would write
# through the nil pointer into address 0 and corrupt the module's globals.
#
# MODULARIZE=1 + EXPORT_NAME are a MATCHED PAIR with the JS bootstrap in
# static_replay.js, which calls the factory NegotiationReplayModule(). A
# shell that instead waits for Module.onRuntimeInitialized deadlocks with
# every file present and every asset 200 (cogame-lantern, 2026-08-23).
switch(
  "passL",
  (&"""
  -o {distDir / "negotiation_replay.js"}
  -O2
  -s ALLOW_MEMORY_GROWTH
  -s ABORTING_MALLOC=1
  -s ENVIRONMENT=web
  -s MODULARIZE=1
  -s EXPORT_NAME=NegotiationReplayModule
  -s EXPORTED_RUNTIME_METHODS=HEAPU8
  -s EXPORTED_FUNCTIONS=_main,_malloc,_free,_neg_load_replay,_neg_payload_ptr,_neg_payload_len,_neg_error_ptr,_neg_error_len
  """).replace("\n", " ")
)

#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# swayimg is a meson project with no library target: every decoder is a .cpp that registers itself with
# FormatFactory from a static object. So meson configures the project (generating buildconf.hpp) and
# compiles all of upstream's objects with the sanitizer flags; the harnesses link those objects directly
# (all of them except main.cpp, the way upstream's own swayimg_test is linked).
FUZZ_DIR="$SRC/mayhem/build-fuzz"
TEST_DIR="$SRC/mayhem/build-test"
OUT="$SRC"

# Every format library the image ships: "enabled" so a missing one fails the build instead of silently
# compiling the decoder out. Wayland is not needed to decode (DRM is the UI meson requires); no ffmpeg.
MESON_OPTS=(
  -Dwayland=disabled -Dcompositor=disabled -Ddrm=enabled -Dliblua=luajit -Dvideo=disabled
  -Dexr=enabled -Dgif=enabled -Dheif=enabled -Davif=enabled -Djpeg=enabled -Djp2=enabled -Djxl=enabled
  -Dkrita=enabled -Dpng=enabled -Dsvg=enabled -Dtiff=enabled -Dsixel=enabled -Draw=enabled -Dwebp=enabled
  -Dexif=enabled -Dbash=disabled -Dzsh=disabled
)
# OpenEXR and minizip-ng are static archives under /opt/toolchains/deps: their private deps must be linked.
STATIC_LIBS="$(pkg-config --static --libs OpenEXR minizip-ng)"

meson_setup() { # <dir> <c/c++ flags> <link flags> [extra meson options...]
  local dir="$1" flags="$2" ldflags="$3"; shift 3
  local opts=(--buildtype=plain -Db_ndebug=false "-Dc_args=$flags" "-Dcpp_args=$flags"
              "-Dc_link_args=$ldflags" "-Dcpp_link_args=$ldflags" "${MESON_OPTS[@]}" "$@")
  if [ -f "$dir/build.ninja" ]; then
    meson configure "$dir" "${opts[@]}"
  else
    meson setup "$dir" "$SRC" "${opts[@]}"
  fi
}

# UBSan's `alignment` check is relaxed (only it; ASan and the rest of UBSan stay halting): the in-tree
# decoders read multi-byte fields with reinterpret_cast loads at arbitrary file offsets (bmp, dicom, tga),
# which UBSan reports within seconds on the first mutated input of every target that reaches them and
# which is harmless on the x86-64 hosts this runs on; leaving it on masks every deeper bug in those decoders.
# Only meaningful when sanitizers are on (an empty SANITIZER_FLAGS builds with none).
NO_ALIGN=""
case "$SANITIZER_FLAGS" in *undefined*) NO_ALIGN="-fno-sanitize=alignment" ;; esac

# 1) the sanitized, coverage-instrumented upstream objects
meson_setup "$FUZZ_DIR" "-O1 $SANITIZER_FLAGS $NO_ALIGN -fsanitize=fuzzer-no-link $DEBUG_FLAGS" "$SANITIZER_FLAGS"
mapfile -t OBJS < <(ninja -C "$FUZZ_DIR" -t targets all | sed -n 's|^\(swayimg\.p/[^:]*\.o\):.*|\1|p')
ninja -C "$FUZZ_DIR" -j"$MAYHEM_JOBS" "${OBJS[@]}"
LINK_OBJS=()
for o in "${OBJS[@]}"; do
  [ "$o" = "swayimg.p/src_main.cpp.o" ] || LINK_OBJS+=("$FUZZ_DIR/$o")
done
[ "${#LINK_OBJS[@]}" -gt 20 ] || { echo "too few swayimg objects: ${#LINK_OBJS[@]}" >&2; exit 1; }

LIBS="$(pkg-config --libs xkbcommon fontconfig freetype2 luajit libdrm exiv2 libheif libavif libjpeg \
  libopenjp2 libjxl libjxl_threads libpng librsvg-2.0 libsixel libraw libtiff-4 libwebp libwebpdemux) \
  -lgif $STATIC_LIBS -lpthread"
INC=(-std=c++20 -I"$SRC/src" -I"$SRC/src/external" -I"$FUZZ_DIR")

# 2) harnesses: one libFuzzer binary + one -standalone reproducer each
OBJ_DIR="$FUZZ_DIR/harness"
mkdir -p "$OBJ_DIR"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ_DIR/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ_DIR/standalone_main.o"

link_harness() { # <name> <harness .o>
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$2" "$OBJ_DIR/lsan_off.o" "${LINK_OBJS[@]}" \
    $LIBS -o "$OUT/$1"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$2" "$OBJ_DIR/standalone_main.o" "$OBJ_DIR/lsan_off.o" \
    "${LINK_OBJS[@]}" $LIBS -o "$OUT/$1-standalone"
}

HFLAGS="-O1 $SANITIZER_FLAGS $NO_ALIGN -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
for fmt in bmp tga pnm dicom xbm farbfeld qoi jp2 gif png tiff svg jpg webp jxl exr kra heif avif sixel raw; do
  extra=""
  [ "$fmt" = jpg ] && extra="-DFUZZ_PREVIEW"
  $CXX $HFLAGS "${INC[@]}" "-DFUZZ_FORMAT=\"$fmt\"" $extra -c "$SRC/mayhem/harnesses/fuzz_format.cpp" \
    -o "$OBJ_DIR/fuzz_$fmt.o"
  link_harness "fuzz_$fmt" "$OBJ_DIR/fuzz_$fmt.o"
done
for h in any urilist; do
  $CXX $HFLAGS "${INC[@]}" -c "$SRC/mayhem/harnesses/fuzz_$h.cpp" -o "$OBJ_DIR/fuzz_$h.o"
  link_harness "fuzz_$h" "$OBJ_DIR/fuzz_$h.o"
done

# 3) upstream's gtest suite (swayimg_test), with the project's normal flags, for mayhem/test.sh
meson_setup "$TEST_DIR" "-O2 $COVERAGE_FLAGS" "$COVERAGE_FLAGS $STATIC_LIBS" -Dtests=enabled
ninja -C "$TEST_DIR" -j"$MAYHEM_JOBS" swayimg_test

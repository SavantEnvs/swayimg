# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form, PREFERRED) — builds ON TOP of the org C/C++ base
# image (ghcr.io/savantenvs/base). The base already provides debian + clang/llvm +
# libFuzzer/afl++ + the identities + the build-contract ENV, so this only adds the
# per-commit build (built on top of the prebuilt base, rather than building the toolchain in-image).
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

# The org base, pinned to a fixed DATE-tagged base (YYYYMMDD; shared by all integrations
# minted against it). Use the current dated tag; pin by digest in production: ...base@sha256:<digest>.
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an
# empty value breaks clang ("must be a non-negative decimal integer") both here and for
# any in-image rebuild. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# To change it for a build (e.g. ASan-only, or add MSan): --build-arg SANITIZER_FLAGS="...".
# Declare it WITHOUT a default (no '='): an undefaulted ARG lets the base ENV flow through to
# build.sh when not passed, and an explicit --build-arg overrides it. (An empty default — `=` —
# would instead shadow the base ENV and silently wipe the sanitizers.)
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instrument the TEST build to measure how much of the project
# the suite exercises — --build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping".
# Empty by default (no effect on the normal oracle build); build.sh appends it to the test build only.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# swayimg's build deps (meson project; DRM UI only — Wayland is not needed for decoding) plus every
# optional image-format library apt ships, so all decoders are compiled in. gtest for the upstream suite.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      meson ninja-build pkg-config cmake \
      libxkbcommon-dev libfontconfig-dev libfreetype-dev libluajit-5.1-dev libdrm-dev \
      libgif-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev libopenjp2-7-dev libjxl-dev \
      librsvg2-dev libheif-dev libavif-dev libsixel-dev libraw-dev libexiv2-dev \
      zlib1g-dev libimath-dev libdeflate-dev libopenjph-dev \
      libgtest-dev libomp-19-dev locales \
 && sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen && locale-gen \
 && rm -rf /var/lib/apt/lists/*

# OpenEXR: upstream requires >= 3.4, trixie ships 3.2 -> static build from a pinned tarball (SPEC 6.2 item 19).
ARG OPENEXR_VER=3.4.9
ARG OPENEXR_SHA256=328c6fcd794b2538d71c65b401264e6745cf65cbc18f404e55ec3c0230d2373c
RUN d=/opt/toolchains/deps/openexr-${OPENEXR_VER} && mkdir -p "$d/src" /tmp/dep-build \
 && curl -fsSL -o /tmp/dep.tgz \
      https://github.com/AcademySoftwareFoundation/openexr/archive/refs/tags/v${OPENEXR_VER}.tar.gz \
 && echo "${OPENEXR_SHA256}  /tmp/dep.tgz" | sha256sum -c - \
 && tar -xzf /tmp/dep.tgz --strip-components=1 -C "$d/src" \
 && cmake -S "$d/src" -B /tmp/dep-build -G Ninja -DCMAKE_INSTALL_PREFIX="$d" \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_C_FLAGS="-O2 -g -gdwarf-3" -DCMAKE_CXX_FLAGS="-O2 -g -gdwarf-3" \
      -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_TESTING=OFF \
      -DOPENEXR_BUILD_TOOLS=OFF -DOPENEXR_BUILD_EXAMPLES=OFF -DOPENEXR_INSTALL_DOCS=OFF \
      -DOPENEXR_FORCE_INTERNAL_IMATH=OFF -DOPENEXR_FORCE_INTERNAL_DEFLATE=OFF -DOPENEXR_FORCE_INTERNAL_OPENJPH=OFF \
      -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
 && cmake --build /tmp/dep-build -j"$(nproc)" && cmake --install /tmp/dep-build \
 && rm -rf /tmp/dep-build /tmp/dep.tgz && chmod -R a+rX "$d"

# minizip-ng (Krita .kra container): not packaged by Debian -> static build from a pinned tarball.
ARG MINIZIP_VER=4.2.2
ARG MINIZIP_SHA256=71af7b9799856d8b03619df3949e9c1be9703f8de0795af71399ba283cb27aac
RUN d=/opt/toolchains/deps/minizip-ng-${MINIZIP_VER} && mkdir -p "$d/src" /tmp/dep-build \
 && curl -fsSL -o /tmp/dep.tgz https://github.com/zlib-ng/minizip-ng/archive/refs/tags/${MINIZIP_VER}.tar.gz \
 && echo "${MINIZIP_SHA256}  /tmp/dep.tgz" | sha256sum -c - \
 && tar -xzf /tmp/dep.tgz --strip-components=1 -C "$d/src" \
 && cmake -S "$d/src" -B /tmp/dep-build -G Ninja -DCMAKE_INSTALL_PREFIX="$d" \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_C_FLAGS="-O2 -g -gdwarf-3" \
      -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DMZ_COMPAT=OFF -DMZ_FETCH_LIBS=OFF \
      -DMZ_ZLIB=ON -DMZ_BZIP2=OFF -DMZ_LZMA=OFF -DMZ_ZSTD=OFF -DMZ_LIBCOMP=OFF -DMZ_PKCRYPT=OFF \
      -DMZ_WZAES=OFF -DMZ_OPENSSL=OFF -DMZ_LIBBSD=OFF -DMZ_ICONV=OFF -DMZ_PPMD=OFF \
 && cmake --build /tmp/dep-build -j"$(nproc)" && cmake --install /tmp/dep-build \
 && rm -rf /tmp/dep-build /tmp/dep.tgz && chmod -R a+rX "$d"
ENV PKG_CONFIG_PATH=/opt/toolchains/deps/openexr-3.4.9/lib/pkgconfig:/opt/toolchains/deps/minizip-ng-4.2.2/lib/pkgconfig
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history) is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Anything a Dockerfile step materializes into the tree (downloaded fixtures, generated headers,
# vendored deps) MUST be committed or (re)created by build.sh: rlenv's patch grader runs
# `git clean -ffdX` before every graded build, so a gitignored, untracked file is gone by then and
# every honest patch scores zero (SPEC §6.2 item 16; verify-repo.sh checks it).
#
# OPTIONAL compile-cache pre-fill (SPEC §6.2 item 18). Bases minted with /opt/mayhem/ccache/prefill
# run the build under rlenv's pinned ccache, so the patch grader's first (otherwise cold) rebuild is
# warm — this is what keeps large C/C++ targets inside the build time limit. Older bases fall back to
# the plain build; a missing or stale pre-fill only costs a cold cache. Never enable ccache in
# build.sh or via ENV/PATH, and keep the compiler resolving by name (CC=clang) or nothing is cached.
RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

# Run the project's functional tests at build time IF the repo ships them (mayhem/test.sh is
# optional — omit it only when the repo has no tests meaningful for RL). A failing suite fails the
# image build, so the commit image is guaranteed to build AND pass its own tests.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem

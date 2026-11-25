#!/bin/sh
# Builds libchiaki from the pinned chiaki-ng submodule into build/libchiaki as
# static libraries. Idempotent: safe to re-run after a submodule bump.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHIAKI="$ROOT/third_party/chiaki-ng"
OUT="$ROOT/build/libchiaki"
PYENV="$ROOT/build/pyenv"
BREW=/opt/homebrew

# 1. Dependency check: report everything missing at once, install nothing.
missing=""
for tool in cmake ninja pkg-config uv; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
for pkg in opus json-c miniupnpc libevent openssl@3; do
  brew list --versions "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
done
if [ -n "$missing" ]; then
  echo "Eksik bağımlılıklar:$missing" >&2
  echo "Kurmak için: brew install$missing" >&2
  exit 1
fi

# 2. Submodules: only the four chiaki-ng submodules libchiaki needs.
git -C "$ROOT" submodule update --init third_party/chiaki-ng
for sub in third-party/nanopb third-party/jerasure third-party/gf-complete third-party/curl; do
  git -C "$CHIAKI" submodule update --init --depth 1 "$sub" \
    || git -C "$CHIAKI" submodule update --init "$sub"
done

# 3. Isolated Python for the nanopb generator. chiaki-ng's lib/protobuf needs a
#    `protoc` executable; nanopb's generator/protoc wrapper provides one on top of
#    grpcio-tools, so no Homebrew protobuf is required.
if [ ! -x "$PYENV/bin/python" ]; then
  uv venv --quiet --python 3.12 "$PYENV"
fi
uv pip install --quiet --python "$PYENV/bin/python" protobuf grpcio-tools

export PATH="$PYENV/bin:$PATH"
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
export PKG_CONFIG_PATH="$BREW/opt/openssl@3/lib/pkgconfig:$BREW/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# 4. Configure + build only the chiaki-lib target.
#    Opus is pinned to its own prefix on purpose: chiaki-ng's FindOpus otherwise resolves to
#    $BREW/include, which then precedes openssl@3 on the compile line. When another OpenSSL
#    major is installed there, libchiaki is compiled against its headers and fails to link.
cmake -S "$CHIAKI" -B "$OUT" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DPYTHON_EXECUTABLE="$PYENV/bin/python" \
  -DPROTOC="$CHIAKI/third-party/nanopb/generator/protoc" \
  -DOPENSSL_ROOT_DIR="$BREW/opt/openssl@3" \
  -DOpus_INCLUDE_DIRS="$BREW/opt/opus/include" \
  -DOpus_LIBRARIES="$BREW/opt/opus/lib/libopus.dylib" \
  -DCHIAKI_ENABLE_GUI=OFF \
  -DCHIAKI_ENABLE_CLI=OFF \
  -DCHIAKI_ENABLE_TESTS=OFF \
  -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
  -DCHIAKI_ENABLE_SETSU=OFF \
  -DCHIAKI_ENABLE_SPEEX=OFF \
  -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF \
  -DCHIAKI_ENABLE_PI_DECODER=OFF \
  -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF \
  -DCURL_USE_LIBPSL=OFF \
  -DUSE_NGHTTP2=OFF \
  -DCURL_USE_LIBSSH2=OFF \
  -DUSE_LIBIDN2=OFF \
  -DCURL_BROTLI=OFF \
  -DCURL_ZSTD=OFF
cmake --build "$OUT" --target chiaki-lib

# 5. Record exact versions next to the build.
{
  echo "chiaki-ng $(git -C "$CHIAKI" rev-parse HEAD)"
  for pkg in opus json-c miniupnpc libevent openssl@3; do brew list --versions "$pkg"; done
  "$PYENV/bin/python" -c 'import google.protobuf as p; print("python-protobuf", p.__version__)'
  cmake --version | head -1
} > "$OUT/VERSIONS.txt"

echo "libchiaki hazır: $OUT"
find "$OUT" -name '*.a' -not -path '*/CMakeFiles/*' | sed "s|$ROOT/||" | sort

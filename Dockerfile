# MC compiler development image — the full toolchain the build/test gates need, pinned to
# match .github/workflows/ci.yml so a local container reproduces CI exactly. Multi-arch:
# builds natively on linux/amd64 and linux/arm64 (Apple Silicon), selecting the matching
# Zig release at build time. The repo itself is NOT copied in — mount it at /work (see
# docker-compose.yml) so host edits are live; the image is just the toolchain.
FROM ubuntu:24.04

# Pinned to the version setup-zig fetches in CI.
ARG ZIG_VERSION=0.16.0
# Pinned to the major installed in .github/workflows/ci.yml.
ARG LLVM_MAJOR=18

ENV DEBIAN_FRONTEND=noninteractive
ENV MC_LLVM_MAJOR=${LLVM_MAJOR}

# Toolchain:
#   clang        — the C backend's compile-check + the LLVM cross-compiler for riscv64/aarch64
#   lld          — ld.lld, the linker for the cross-compiled kernel/driver objects
#   llvm         — llc / opt / llvm-as for the LLVM backend sweeps
#   qemu-system-* — riscv64 (misc), aarch64 (arm), x86_64 — the integration tests boot real images
#   binutils     — nm / ld / objcopy used by the toolchain scripts
#   python3      — the spec/llvm sweeps and the mcfuzz harness
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates wget xz-utils ; \
    apt-get install -y --no-install-recommends \
        clang-${LLVM_MAJOR} lld-${LLVM_MAJOR} llvm-${LLVM_MAJOR} \
        qemu-system-misc qemu-system-arm qemu-system-x86 \
        binutils python3 git bash make; \
    rm -rf /var/lib/apt/lists/*

# The toolchain scripts call clang/llc/opt/llvm-as/ld.lld by their unversioned names.
# Symlink the pinned major to those names, then assert the whole set resolves.
RUN set -eux; \
    for tool in clang clang++ llc opt llvm-as llvm-dis ld.lld lld wasm-ld; do \
        cand=""; \
        if [ -x "/usr/lib/llvm-${LLVM_MAJOR}/bin/${tool}" ]; then \
            cand="/usr/lib/llvm-${LLVM_MAJOR}/bin/${tool}"; \
        elif [ -x "/usr/bin/${tool}-${LLVM_MAJOR}" ]; then \
            cand="/usr/bin/${tool}-${LLVM_MAJOR}"; \
        fi; \
        [ -n "$cand" ] && ln -sf "$cand" /usr/local/bin/"$tool" || true; \
    done; \
    command -v clang; command -v llc; command -v opt; command -v llvm-as; command -v ld.lld; command -v nm; \
    clang --version | grep -E "version ${LLVM_MAJOR}\\."; \
    llc --version | grep -E "version ${LLVM_MAJOR}\\."; \
    opt --version | grep -E "version ${LLVM_MAJOR}\\."

# Zig: fetch the exact release tarball for this build's architecture from ziglang.org's
# index.json (naming-scheme- and arch-agnostic), so the same Dockerfile works on amd64/arm64.
RUN set -eux; \
    case "$(uname -m)" in \
        x86_64) zarch=x86_64 ;; \
        aarch64|arm64) zarch=aarch64 ;; \
        *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    url="$(python3 -c "import json,urllib.request; d=json.load(urllib.request.urlopen('https://ziglang.org/download/index.json')); print(d['${ZIG_VERSION}']['${zarch}-linux']['tarball'])")"; \
    wget -qO /tmp/zig.tar.xz "$url"; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    ln -sf /opt/zig/zig /usr/local/bin/zig; \
    rm /tmp/zig.tar.xz; \
    zig version

WORKDIR /work

# Default to an interactive shell; override with e.g. `zig build fast` / `zig build m0`.
CMD ["bash"]

FROM archlinux:base-devel

RUN pacman -Syu --noconfirm --needed \
      aarch64-linux-gnu-binutils \
      aarch64-linux-gnu-gcc \
      bc \
      bison \
      busybox \
      ccache \
      clang \
      cpio \
      dtc \
      flex \
      git \
      jq \
      libelf \
      lld \
      llvm \
      numactl \
      openssl \
      pahole \
      perf \
      python \
      qemu-img \
      qemu-system-aarch64 \
      qemu-system-riscv \
      qemu-system-x86 \
      riscv64-linux-gnu-binutils \
      riscv64-linux-gnu-gcc \
      rng-tools \
      rust \
      rust-bindgen \
      rust-src \
      socat \
      sparse \
      squashfs-tools \
      stress-ng \
      trace-cmd \
      zig \
    && pacman -Scc --noconfirm

WORKDIR /work

CMD ["bash"]

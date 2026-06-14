# Convenience wrappers around the dockerized toolchain (see Dockerfile / docker-compose.yml).
# These give the same commands on Linux, macOS (incl. Apple Silicon), and Windows/WSL.
#
#   make docker-build   # build the toolchain image
#   make shell          # interactive shell in the container at /work
#   make test           # zig build test          (compiler unit + spec suite)
#   make fast           # zig build fast          (host-only inner-loop gate, ~7s)
#   make m0             # zig build m0            (full milestone gate: qemu + llvm)
#   make run CMD='...'  # run an arbitrary command in the container
#
# Native (non-docker) equivalents are `zig build <step>` when the toolchain is installed.

COMPOSE ?= docker compose
RUN     := $(COMPOSE) run --rm dev

.PHONY: docker-build shell test fast m0 abi-test opt-test run

docker-build:
	$(COMPOSE) build dev

shell:
	$(RUN)

test:
	$(RUN) zig build test

fast:
	$(RUN) zig build fast

m0:
	$(RUN) zig build m0

abi-test:
	$(RUN) zig build abi-test

opt-test:
	$(RUN) zig build opt-test

run:
	$(RUN) $(CMD)

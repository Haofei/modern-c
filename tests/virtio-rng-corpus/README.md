# virtio-rng differential corpora

Each `.vrng` file is a stable event sequence accepted by
`tools/virtio-rng-experiment/run-host-differential.sh`. The host runner links
the Linux experiment's executable specification and C, Rust, and MC candidates.
It replays every committed sequence against all candidates.

On a differential failure, bounded enumeration writes the shortest discovered
sequence to `failure-<event-hash>.vrng`. The synthetic fixture validates that
capture is deterministic, that the sequence passes after the injected defect is
removed, and that replay with the same defect reproduces the mismatch.

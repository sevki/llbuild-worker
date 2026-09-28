# llbuild-worker

A remote content-addressable storage service for Apple llbuild2, implemented as a Cloudflare Worker with Swift and [workers-swift](https://github.com/sevki/workers-swift).

## Design status

This repository is starting from an empty state. The first design target is a native llbuild2 client calling a Swift distributed actor hosted by the Worker, using the native WebSocket transport and `RPCGateway` introduced in [workers-swift PR #12](https://github.com/sevki/workers-swift/pull/12).

See [docs/design.md](docs/design.md) for the architecture, proposed service surface, data flow, and open protocol questions.

## Status

Design only. No CAS identity encoding, storage layout, or production protocol has been implemented yet.

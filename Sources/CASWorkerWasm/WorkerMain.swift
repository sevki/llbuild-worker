// Entry point for the Worker Wasm module. It is linked as a WASI reactor, so
// this never runs: the shim calls the `workers_js_main` export that
// `@Event(.fetch)` generates in CASWorker, which is linked in through the
// WASI-only dependency in Package.swift. Nothing is imported here so the
// native build, which does not build CASWorker, still compiles this target.
@main
enum WorkerMain {
    static func main() {}
}

// Serves the built Worker (build/worker) in a local workerd and prints its
// URL, for end-to-end tests. Durable Object state lives in a temporary
// directory that is removed on exit.
//
//   node Scripts/serve-worker.mjs [--port N]
//
// Prints a single line `READY http://127.0.0.1:<port>` once it answers HTTP.
import { spawn } from "node:child_process";
import { copyFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const workerDir = join(root, "build", "worker");
const classes = { CASGATEWAY: "CASGateway", CASSHARD: "CASShardObject" };

function freePort() {
  return new Promise((resolvePort, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolvePort(port));
    });
  });
}

const portFlag = process.argv.indexOf("--port");
const port = portFlag > 0 ? Number(process.argv[portFlag + 1]) : await freePort();
const directory = await mkdtemp(join(tmpdir(), "llbuild-worker-"));
await mkdir(join(directory, "disk"));
for (const file of ["worker.mjs", "WorkersSwift.wasm"]) {
  await copyFile(join(workerDir, file), join(directory, file));
}

const bindings = Object.entries(classes)
  .map(([name]) => `(name = ${JSON.stringify(name)}, durableObjectNamespace = ${JSON.stringify(classes[name])})`)
  .join(", ");
// enableSql exposes state.storage.sql; a SQLite-backed namespace needs
// disk-backed storage, provided by the DiskDirectory service below.
const namespaces = Object.values(classes)
  .map((name) => `(className = ${JSON.stringify(name)}, uniqueKey = "llbuild-worker-${name}", enableSql = true)`)
  .join(", ");
await writeFile(join(directory, "config.capnp"), `
using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (name = "main", worker = .worker),
    (name = "disk", disk = (path = ${JSON.stringify(join(directory, "disk"))}, writable = true)),
  ],
  sockets = [(name = "http", address = "127.0.0.1:${port}", http = (), service = "main")],
);

const worker :Workerd.Worker = (
  modules = [
    (name = "worker.mjs", esModule = embed "worker.mjs"),
    (name = "WorkersSwift.wasm", wasm = embed "WorkersSwift.wasm"),
  ],
  bindings = [${bindings}],
  durableObjectNamespaces = [${namespaces}],
  durableObjectStorage = (localDisk = "disk"),
  compatibilityDate = "2026-01-01",
);
`);

const child = spawn(process.env.WORKERD_BIN ?? require("workerd").default,
  ["serve", join(directory, "config.capnp")], { cwd: directory, stdio: ["ignore", "pipe", "pipe"] });
const output = [];
const forward = process.env.DEBUG_WORKERD ? (chunk) => process.stderr.write(chunk) : () => {};
child.stdout.on("data", (chunk) => { output.push(chunk.toString()); forward(chunk); });
child.stderr.on("data", (chunk) => { output.push(chunk.toString()); forward(chunk); });

let stopping = false;
async function stop(code) {
  if (stopping) return;
  stopping = true;
  if (child.exitCode === null) {
    const exited = new Promise((done) => child.once("exit", done));
    child.kill("SIGTERM");
    await exited;
  }
  await rm(directory, { recursive: true, force: true });
  process.exit(code);
}
process.on("SIGTERM", () => stop(0));
process.on("SIGINT", () => stop(0));
child.on("exit", (code) => {
  if (!stopping) {
    console.error(`workerd exited with ${code}:\n${output.join("")}`);
    stop(1);
  }
});

const deadline = Date.now() + 120_000;
while (true) {
  try {
    await fetch(`http://127.0.0.1:${port}/`);
    break;
  } catch {
    if (Date.now() > deadline) {
      console.error(`workerd did not start listening:\n${output.join("")}`);
      await stop(1);
    }
    await new Promise((delay) => setTimeout(delay, 250));
  }
}
console.log(`READY http://127.0.0.1:${port}`);
setInterval(() => {}, 1 << 30); // stay alive until signalled

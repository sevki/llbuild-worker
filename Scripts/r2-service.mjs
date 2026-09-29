// A minimal in-memory stand-in for R2, used only to test locally in raw
// workerd, which has no R2 emulator. Speaks workerd's r2Bucket wire protocol
// (adapted from WorkerKit's e2e harness).
const entries = new Map();

function notFound() {
  return new Response(null, {
    status: 404,
    headers: { "CF-R2-Error": JSON.stringify({ version: 0, v4code: 10007, message: "The specified key does not exist." }) },
  });
}

function metadataFor(key, entry) {
  return {
    name: key,
    version: "1",
    size: entry.value.byteLength,
    etag: entry.etag,
    uploaded: entry.uploaded,
    httpFields: entry.httpFields,
    customFields: Object.entries(entry.customFields).map(([k, v]) => ({ k, v })),
  };
}

// Concatenates the JSON metadata and (optionally) the object's raw bytes
// into one body, with CF-R2-Metadata-Size marking where the JSON ends.
function metadataResponse(metadata, body) {
  const json = new TextEncoder().encode(JSON.stringify(metadata));
  const bytes = body ? new Uint8Array(json.length + body.byteLength) : json;
  if (body) {
    bytes.set(json, 0);
    bytes.set(body, json.length);
  }
  return new Response(bytes, { headers: { "CF-R2-Metadata-Size": String(json.length) } });
}

export default {
  async fetch(request) {
    if (request.method === "GET") {
      const req = JSON.parse(request.headers.get("CF-R2-Request"));
      if (req.method === "list") {
        const prefix = req.prefix ?? "";
        const limit = req.limit ?? 1000;
        const start = req.cursor ? Number(req.cursor) : 0;
        const names = [...entries.keys()].filter((name) => name.startsWith(prefix)).sort();
        const page = names.slice(start, start + limit);
        const truncated = start + limit < names.length;
        return metadataResponse({
          objects: page.map((name) => metadataFor(name, entries.get(name))),
          truncated,
          cursor: truncated ? String(start + limit) : "",
          delimitedPrefixes: [],
        });
      }
      const entry = entries.get(req.object);
      if (!entry) {
        return notFound();
      }
      return req.method === "head"
        ? metadataResponse(metadataFor(req.object, entry))
        : metadataResponse(metadataFor(req.object, entry), entry.value);
    }

    // PUT: either a put or a delete, told apart by the "method" field in
    // the JSON prefix of the body.
    const metadataSize = Number(request.headers.get("CF-R2-Metadata-Size"));
    const body = new Uint8Array(await request.arrayBuffer());
    const req = JSON.parse(new TextDecoder().decode(body.subarray(0, metadataSize)));
    if (req.method === "delete") {
      for (const key of req.object !== undefined ? [req.object] : req.objects) {
        entries.delete(key);
      }
      return new Response(JSON.stringify({}));
    }
    const value = body.subarray(metadataSize);
    const customFields = Object.fromEntries((req.customFields ?? []).map(({ k, v }) => [k, v]));
    const entry = {
      value,
      etag: Math.random().toString(36).slice(2),
      uploaded: Date.now(),
      httpFields: req.httpFields ?? {},
      customFields,
    };
    console.log("R2PUT", req.object, value.byteLength); // lets tests see what reaches R2
    entries.set(req.object, entry);
    return metadataResponse(metadataFor(req.object, entry));
  },
};

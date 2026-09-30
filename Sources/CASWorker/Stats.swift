import CASProtocol
import Distributed
import Foundation
import Html
import JavaScriptKit
import WorkerKit
import WorkerKitDistributed

// Usage statistics for the `/stats` page. Traffic is counted per day in one
// Durable Object (`CASStatsObject`); storage totals are not counted but read
// from the shards when the page is rendered.

/// Days of history the stats object keeps.
let statsRetentionDays = 90

/// One counter's value for one day. `Int64`: the Worker is 32-bit WebAssembly,
/// where `Int` overflows at 2.1 GB and byte counters pass that in a day.
struct StatsCounter: Codable, Sendable {
    var day: Int
    var name: String
    var value: Int64
}

/// What one shard holds. Bodies kept in R2 are counted in `objectsInR2` but
/// not in `inlineBytes`, which only covers what sits in the shard's SQLite.
struct ShardTotals: Codable, Sendable {
    var objects: Int
    var objectsInR2: Int
    var inlineBytes: Int64
    var actions: Int
    var largeObjects: Int
    var largeBytes: Int64
}

/// The per-day traffic counters, as the names recorded by `StatsBackend`.
enum StatsName {
    static let hits = "action_hits"
    static let misses = "action_misses"
    static let actionsPut = "actions_put"
    static let objectsPut = "objects_put"
    static let objectsGot = "objects_got"
    static let bytesUp = "bytes_up"
    static let bytesDown = "bytes_down"
    static let connections = "connections"
}

/// One network's connection count over the reporting window.
struct ASNStat: Codable, Sendable {
    var asn: Int
    var asOrganization: String
    var country: String
    var connections: Int
}

/// Daily traffic counters, in the SQLite of a single Durable Object.
distributed actor CASStatsKeeper {
    typealias ActorSystem = WorkersActorSystem

    private let storage: SQLStorage
    private let state: DurableObjectState
    private var schemaReady = false
    private var prunedDay = 0

    init(actorSystem: WorkersActorSystem, sql: SQLStorage, state: DurableObjectState) {
        self.actorSystem = actorSystem
        self.storage = sql
        self.state = state
    }

    /// Tells every page watching `/stats/live` what was just counted, as a
    /// `DayStats` holding only the increments.
    private func broadcast(day: Int, deltas: [String: Int]) {
        let viewers = state.getWebSockets(tag: statsViewerTag)
        guard !viewers.isEmpty else { return }
        var event = DayStats(date: isoDate(day: day))
        for (name, delta) in deltas { event.add(name, Int64(delta)) }
        guard let data = try? JSONEncoder().encode(event) else { return }
        let text = String(decoding: data, as: UTF8.self)
        for viewer in viewers { viewer.send(text) }
    }

    private func database() throws -> SQLStorage {
        if !schemaReady {
            try storage.exec(
                "CREATE TABLE IF NOT EXISTS counters (day INTEGER NOT NULL, name TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (day, name))")
            try storage.exec(
                """
                CREATE TABLE IF NOT EXISTS asn_counts (
                    day INTEGER NOT NULL, asn INTEGER NOT NULL,
                    as_organization TEXT NOT NULL, country TEXT NOT NULL,
                    count INTEGER NOT NULL, PRIMARY KEY (day, asn)
                )
                """)
            try storage.exec(
                "CREATE TABLE IF NOT EXISTS connections_raw (day INTEGER NOT NULL, ip TEXT, asn INTEGER, connected_at INTEGER NOT NULL)")
            schemaReady = true
        }
        return storage
    }

    /// Prunes every table's history to `statsRetentionDays`, at most once per
    /// distinct `day` seen (`record` and `recordConnection` both call this).
    private func pruneIfNeeded(day: Int, db: SQLStorage) throws {
        guard prunedDay != day else { return }
        prunedDay = day
        let cutoff = day - statsRetentionDays
        try db.exec("DELETE FROM counters WHERE day < ?", cutoff)
        try db.exec("DELETE FROM asn_counts WHERE day < ?", cutoff)
        try db.exec("DELETE FROM connections_raw WHERE day < ?", cutoff)
    }

    distributed func record(day: Int, deltas: [String: Int]) throws {
        let db = try database()
        for (name, delta) in deltas where delta != 0 {
            try db.exec(
                "INSERT INTO counters (day, name, value) VALUES (?, ?, ?) ON CONFLICT(day, name) DO UPDATE SET value = value + excluded.value",
                day, name, delta)
        }
        try pruneIfNeeded(day: day, db: db)
        broadcast(day: day, deltas: deltas)
    }

    distributed func counters(since day: Int) throws -> [StatsCounter] {
        try database().exec("SELECT day, name, value FROM counters WHERE day >= ? ORDER BY day", day).rows()
            .compactMap { row in
                guard let day = row["day", as: Int.self], let name = row["name", as: String.self],
                      let value = row["value", as: Double.self] else { return nil }
                // Read as a JS number (exact to 9 PB) rather than Int, which is 32-bit here.
                return StatsCounter(day: day, name: name, value: Int64(value))
            }
    }

    /// Records one incoming connection: bumps `asn_counts` when Cloudflare
    /// identified the network, and always appends to `connections_raw` for
    /// the operator's own inspection (never surfaced over `/stats`).
    distributed func recordConnection(day: Int, ip: String?, asn: Int?, asOrganization: String?, country: String?) throws {
        let db = try database()
        if let asn {
            try db.exec(
                """
                INSERT INTO asn_counts (day, asn, as_organization, country, count) VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(day, asn) DO UPDATE SET count = count + 1
                """,
                day, asn, asOrganization ?? "", country ?? "")
        }
        try db.exec(
            "INSERT INTO connections_raw (day, ip, asn, connected_at) VALUES (?, ?, ?, ?)",
            day, ip, asn, Int(Date().timeIntervalSince1970))
        try pruneIfNeeded(day: day, db: db)
    }

    /// The networks with the most connections since `day`, most first.
    distributed func topASNs(since day: Int, limit: Int) throws -> [ASNStat] {
        try database().exec(
            """
            SELECT asn, MAX(as_organization) AS as_organization, MAX(country) AS country, SUM(count) AS connections
            FROM asn_counts WHERE day >= ? GROUP BY asn ORDER BY SUM(count) DESC LIMIT ?
            """,
            day, limit
        ).rows().compactMap { row in
            guard let asn = row["asn", as: Int.self],
                  let asOrganization = row["as_organization", as: String.self],
                  let country = row["country", as: String.self],
                  let connections = row["connections", as: Double.self] else { return nil }
            return ASNStat(asn: asn, asOrganization: asOrganization, country: country, connections: Int(connections))
        }
    }

    /// How many distinct connecting IPs were seen since `day`.
    distributed func distinctIPCount(since day: Int) throws -> Int {
        let count = try database().exec(
            "SELECT COUNT(DISTINCT ip) AS count FROM connections_raw WHERE ip IS NOT NULL AND day >= ?", day
        ).rows().first?["count", as: Double.self] ?? 0
        return Int(count)
    }
}

/// Tag of the WebSockets that `/stats/live` viewers connect with.
let statsViewerTag = "live"

/// Most pages that can watch at once; each one is a hibernatable WebSocket
/// this object pushes to on every counted event.
let statsMaxViewers = 100

/// The Durable Object hosting the one `CASStatsKeeper`, and the WebSocket
/// endpoint the stats page watches for live updates. Viewers only listen:
/// anything they send is ignored.
@DurableObject
final class CASStatsObject {
    let state: DurableObjectState
    let hostSystem: WorkersActorSystem
    let keeper: CASStatsKeeper

    init(state: DurableObjectState, env: Env) {
        self.state = state
        let hostSystem = WorkersActorSystem()
        self.hostSystem = hostSystem
        let sql = state.storage.sql
        keeper = hostSystem.host(state.id) { CASStatsKeeper(actorSystem: $0, sql: sql, state: state) }
    }

    func fetch(_ req: Request) async throws -> Response {
        guard req.headers.get("Upgrade")?.lowercased() == "websocket" else {
            return .error("Expected Upgrade: websocket", 426)
        }
        guard state.getWebSockets(tag: statsViewerTag).count < statsMaxViewers else {
            return .error("Too many viewers", 503)
        }
        return .webSocketUpgrade(state.acceptWebSocket(tags: [statsViewerTag]))
    }
}

/// Reaches the stats object, or nothing when the `CASSTATS` binding is absent
/// (a deployment from before statistics existed keeps working without them).
struct StatsClient: Sendable {
    let keeper: CASStatsKeeper

    init?(env: Env, scope: String) {
        guard env.jsObject["CASSTATS"].object != nil else { return nil }
        let namespace = env.durableObject("CASSTATS")
        guard let keeper = try? CASStatsKeeper.resolve(
            id: namespace.idFromName("stats/\(scope)"), using: WorkersActorSystem(durableObjects: namespace)) else {
            return nil
        }
        self.keeper = keeper
    }

    static func today() -> Int { Int(Date().timeIntervalSince1970 / 86_400) }

    /// Counting must never slow or fail a cache operation, so this does not
    /// wait for the stats object and drops what it cannot record.
    func record(_ deltas: [String: Int]) {
        let keeper = keeper
        let day = Self.today()
        Task { try? await keeper.record(day: day, deltas: deltas) }
    }

    /// Records one incoming connection's network, fire-and-forget like `record(_:)`.
    func recordConnection(ip: String?, cf: Request.CFProperties?) {
        let keeper = keeper
        let day = Self.today()
        Task {
            try? await keeper.recordConnection(
                day: day, ip: ip, asn: cf?.asn, asOrganization: cf?.asOrganization, country: cf?.country)
        }
    }
}

/// A `CASBackend` that counts what passes through it.
struct StatsBackend: CASBackend {
    let inner: any CASBackend
    let stats: StatsClient

    func contains(digest: String) async throws -> Bool {
        try await inner.contains(digest: digest)
    }

    func put(digest: String, refs: [String], data: String) async throws {
        try await inner.put(digest: digest, refs: refs, data: data)
        stats.record([StatsName.objectsPut: 1, StatsName.bytesUp: Self.decodedSize(ofBase64: data)])
    }

    func get(digest: String) async throws -> CASObjectPayload? {
        let object = try await inner.get(digest: digest)
        if let object {
            stats.record([StatsName.objectsGot: 1, StatsName.bytesDown: Self.decodedSize(ofBase64: object.data)])
        }
        return object
    }

    func actionGet(key: String) async throws -> String? {
        let value = try await inner.actionGet(key: key)
        stats.record([value == nil ? StatsName.misses : StatsName.hits: 1])
        return value
    }

    func actionPut(key: String, value: String) async throws {
        try await inner.actionPut(key: key, value: value)
        stats.record([StatsName.actionsPut: 1])
    }

    func traceGet(key: String) async throws -> [String]? {
        try await inner.traceGet(key: key)
    }

    func tracePut(key: String, keys: [String]) async throws {
        try await inner.tracePut(key: key, keys: keys)
    }

    func putLarge(digest: String, refs: [String], manifest: String) async throws {
        try await inner.putLarge(digest: digest, refs: refs, manifest: manifest)
    }

    func getLarge(digest: String) async throws -> CASLargeObject? {
        try await inner.getLarge(digest: digest)
    }

    private static func decodedSize(ofBase64 text: String) -> Int {
        let utf8 = text.utf8
        let padding = utf8.reversed().prefix(2).filter { $0 == UInt8(ascii: "=") }.count
        return max(0, utf8.count / 4 * 3 - padding)
    }
}

// MARK: - Report

struct DayStats: Codable, Sendable {
    var date: String
    var hits = 0
    var misses = 0
    var actionsPut = 0
    var objectsPut = 0
    var objectsGot = 0
    var bytesUp: Int64 = 0
    var bytesDown: Int64 = 0
    var connections = 0

    /// Adds `value` to the field the counter `name` feeds.
    mutating func add(_ name: String, _ value: Int64) {
        let count = Int(clamping: value)
        switch name {
        case StatsName.hits: hits += count
        case StatsName.misses: misses += count
        case StatsName.actionsPut: actionsPut += count
        case StatsName.objectsPut: objectsPut += count
        case StatsName.objectsGot: objectsGot += count
        case StatsName.bytesUp: bytesUp += value
        case StatsName.bytesDown: bytesDown += value
        case StatsName.connections: connections += count
        default: break
        }
    }
}

struct StatsReport: Codable, Sendable {
    var enabled: Bool
    var generatedAt: Int
    var storage: ShardTotals
    /// Newest day first, for the days that saw any traffic.
    var days: [DayStats]
    /// The networks with the most connections in the window, most first.
    var topASNs: [ASNStat]
    /// Distinct connecting IPs seen in the window. Never broken down by IP:
    /// the raw addresses stay in `connections_raw`, for the operator's own
    /// inspection, and are never read back over `/stats` or `/stats.json`.
    var distinctIPs: Int
}

/// How many days of traffic the page and `/stats.json` cover.
let statsWindowDays = 30

/// How many networks `topASNs` reports.
let statsTopASNsLimit = 10

func gatherStats(env: Env, scope: String) async -> StatsReport {
    var storage = ShardTotals(objects: 0, objectsInR2: 0, inlineBytes: 0, actions: 0, largeObjects: 0, largeBytes: 0)
    if let shards = try? ShardBackend(namespace: env.durableObject("CASSHARD"), scope: scope).allShards() {
        // Every shard at once: one after another, the round trips added up to seconds.
        let all = await withTaskGroup(of: ShardTotals?.self) { group in
            for shard in shards { group.addTask { try? await shard.totals() } }
            var collected = [ShardTotals]()
            for await totals in group { if let totals { collected.append(totals) } }
            return collected
        }
        for totals in all {
            storage.objects += totals.objects
            storage.objectsInR2 += totals.objectsInR2
            storage.inlineBytes += totals.inlineBytes
            storage.actions += totals.actions
            storage.largeObjects += totals.largeObjects
            storage.largeBytes += totals.largeBytes
        }
    }

    let now = Int(Date().timeIntervalSince1970)
    let sinceDay = StatsClient.today() - statsWindowDays + 1
    guard let client = StatsClient(env: env, scope: scope),
          let counters = try? await client.keeper.counters(since: sinceDay) else {
        return StatsReport(enabled: false, generatedAt: now, storage: storage, days: [], topASNs: [], distinctIPs: 0)
    }
    var byDay = [Int: DayStats]()
    for counter in counters {
        var day = byDay[counter.day] ?? DayStats(date: isoDate(day: counter.day))
        day.add(counter.name, counter.value)
        byDay[counter.day] = day
    }
    let days = byDay.sorted { $0.key > $1.key }.map(\.value)
    let topASNs = (try? await client.keeper.topASNs(since: sinceDay, limit: statsTopASNsLimit)) ?? []
    let distinctIPs = (try? await client.keeper.distinctIPCount(since: sinceDay)) ?? 0
    return StatsReport(enabled: true, generatedAt: now, storage: storage, days: days, topASNs: topASNs, distinctIPs: distinctIPs)
}

/// `YYYY-MM-DD` for a day count since 1970-01-01 (proleptic Gregorian).
func isoDate(day: Int) -> String {
    let z = day + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let dayOfMonth = doy - (153 * mp + 2) / 5 + 1
    let month = mp < 10 ? mp + 3 : mp - 9
    let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
    func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
    return "\(pad(year, 4))-\(pad(month, 2))-\(pad(dayOfMonth, 2))"
}

func formatBytes(_ bytes: Int64) -> String { ByteSize.format(bytes) }

func formatPercent(_ part: Int, of total: Int) -> String {
    total == 0 ? "n/a" : "\(Int((Double(part) / Double(total) * 100).rounded()))%"
}

// MARK: - Page

private let statsStyle: StaticString = """
    body { max-width: 720px; padding: clamp(1rem, 4vw, 2rem); }
    table { border-collapse: collapse; width: 100%; margin-bottom: 1.5rem; }
    th, td { text-align: right; padding: 0.3rem clamp(0.35rem, 1.5vw, 0.6rem); border-bottom: 1px solid var(--border); }
    th:first-child, td:first-child { text-align: left; }
    #live-stored { overflow-x: auto; }
    .tiles { display: flex; gap: 1rem; flex-wrap: wrap; margin-bottom: 1.5rem; }
    .tile { flex: 1; min-width: 7.5rem; background: var(--panel); padding: 1rem; }
    .tile strong { display: block; font-size: clamp(1.4rem, 5vw, 1.6rem); }
    /* One card per day, as many per row as fit: a card is a fixed set of
       figures, so no column of a table can be pushed off a narrow screen. */
    .days { display: grid; gap: 1rem; margin-bottom: 1.5rem;
            grid-template-columns: repeat(auto-fill, minmax(min(100%, 15rem), 1fr)); }
    .day { background: var(--panel); padding: 1rem; }
    .day h3 { margin: 0 0 0.5rem; font-size: 1rem; }
    .metric { display: flex; justify-content: space-between; gap: 1rem; padding: 0.25rem 0;
              border-bottom: 1px solid var(--border); }
    .metric:last-child { border-bottom: 0; }
    .flash { animation: flash 1.5s ease-out; }
    @keyframes flash {
        from { background-color: var(--flash); }
        to { background-color: transparent; }
    }
    @media (prefers-reduced-motion: reduce) {
        .flash { animation: none; }
    }
    """

/// One day's figures as label and value pairs, the rows of its card.
private func dayFigures(_ day: DayStats) -> [(label: String, value: String)] {
    let lookups = day.hits + day.misses
    return [
        ("Hit rate", formatPercent(day.hits, of: lookups)),
        ("Hits", String(day.hits)),
        ("Misses", String(day.misses)),
        ("Lookups", String(lookups)),
        ("Connections", String(day.connections)),
        ("Uploaded", formatBytes(day.bytesUp)),
        ("Downloaded", formatBytes(day.bytesDown)),
    ]
}

private func dayCard(_ day: DayStats) -> Node {
    .div(attributes: [.class("day")],
        .h3(.text(day.date)),
        .fragment(dayFigures(day).map { figure in
            .div(attributes: [.class("metric")], .span(.text(figure.label)), .strong(.text(figure.value)))
        }))
}

private func statRow(_ label: String, _ value: String) -> ChildOf<Tag.Table> {
    .tr(.td(.text(label)), .td(.text(value)))
}

private func storedTable(_ storage: ShardTotals) -> Node {
    let large = "\(storage.largeObjects) (\(formatBytes(storage.largeBytes)))"
    var rows = [ChildOf<Tag.Table>]()
    rows.append(statRow("Objects", String(storage.objects)))
    rows.append(statRow("Large objects", large))
    rows.append(statRow("Cached actions", String(storage.actions)))
    rows.append(statRow("Held in the shard databases", formatBytes(storage.inlineBytes)))
    rows.append(statRow("Objects with bodies in R2", String(storage.objectsInR2)))
    return .table(.fragment(rows))
}

private func asnTable(_ topASNs: [ASNStat]) -> Node {
    guard !topASNs.isEmpty else {
        return .p(.small("No connections recorded yet."))
    }
    var rows: [ChildOf<Tag.Table>] = [.tr(.th("ASN"), .th("Organization"), .th("Country"), .th("Connections"))]
    for asn in topASNs {
        rows.append(.tr(
            .td(.text(String(asn.asn))),
            .td(.text(asn.asOrganization)),
            .td(.text(asn.country)),
            .td(.text(String(asn.connections)))))
    }
    return .table(.fragment(rows))
}

/// Keeps the page current: renders the tiles and tables from `/stats.json`
/// (the same figures the server rendered), applies the increments pushed over
/// `/stats/live`, and reloads every 30 seconds because storage totals are not
/// pushed. Without JavaScript the server-rendered page stands as it is.
private let statsScript: StaticString = """
    (function () {
      var report = null;
      // This page's own scope prefix (e.g. "/prod" for /prod/stats, "" for
      // the unscoped default at /stats): every fetch and the live WebSocket
      // below must carry it, or they silently pull the default scope's data
      // onto a scoped page.
      var statsPath = location.pathname.charAt(location.pathname.length - 1) === '/'
        ? location.pathname.slice(0, -1) : location.pathname;
      var prefix = statsPath.slice(-6) === '/stats' ? statsPath.slice(0, -6) : '';
      var fields = ['hits', 'misses', 'actionsPut', 'objectsPut', 'objectsGot', 'bytesUp', 'bytesDown', 'connections'];
      // The unit symbols and the step between them come from the server.
      var tiles = document.getElementById('live-tiles');
      var units = tiles.getAttribute('data-byte-units').split(',');
      var step = Number(tiles.getAttribute('data-byte-step'));
      function bytes(n) {
        if (n < step) return n + ' B';
        var u = 0, v = n;
        while (v >= step && u < units.length - 1) { v /= step; u++; }
        var t = Math.round(v * TENTHS);
        if (t >= step * TENTHS && u < units.length - 1) { v /= step; u++; t = Math.round(v * TENTHS); }
        return Math.floor(t / TENTHS) + '.' + (t % TENTHS) + ' ' + units[u];
      }
      // The figures on a day's card, in order: label and how to get its text.
      var dayFigures = [
        ['Hit rate', function (d) { return pct(d.hits, d.hits + d.misses); }],
        ['Hits', function (d) { return d.hits; }],
        ['Misses', function (d) { return d.misses; }],
        ['Lookups', function (d) { return d.hits + d.misses; }],
        ['Connections', function (d) { return d.connections; }],
        ['Uploaded', function (d) { return bytes(d.bytesUp); }],
        ['Downloaded', function (d) { return bytes(d.bytesDown); }]
      ];
      function pct(part, total) { return total === 0 ? 'n/a' : Math.round(part / total * 100) + '%'; }
      function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
      function sum(key) { return report.days.reduce(function (a, d) { return a + d[key]; }, 0); }
      // Cells with a data-k key are the ones highlighted when their text changes.
      function keyed(key, text) { return '<td data-k="' + key + '">' + text + '</td>'; }
      function statRow(label, value) { return '<tr><td>' + label + '</td>' + keyed('stored:' + label, value) + '</tr>'; }
      function tile(key, value, label) { return '<div class="tile"><strong data-k="' + key + '">' + value + '</strong>' + label + '</div>'; }
      function set(id, html) { var e = document.getElementById(id); if (e) e.innerHTML = html; }
      // A changed value flashes and fades over FLASH_MS. The pieces are rebuilt
      // on every render, so a flash still running when the next render comes
      // resumes where it was, by starting its animation that far in.
      var TENTHS = 10; // one decimal place
      var FLASH_MS = 1500, shown = {}, changedAt = {}, rendered = false;
      function highlight() {
        var now = Date.now();
        Array.prototype.forEach.call(document.querySelectorAll('[data-k]'), function (el) {
          var key = el.getAttribute('data-k'), text = el.textContent;
          if ((key in shown && shown[key] !== text) || (rendered && !(key in shown))) changedAt[key] = now;
          shown[key] = text;
          var age = now - (changedAt[key] || 0);
          if (changedAt[key] && age < FLASH_MS) {
            el.classList.add('flash');
            el.style.animationDelay = '-' + age + 'ms';
          }
        });
        rendered = true;
      }
      function status(text) { var e = document.getElementById('live-status'); if (e) e.textContent = text; }
      function render() {
        var hits = sum('hits'), misses = sum('misses');
        set('live-tiles',
          tile('tile:rate', pct(hits, hits + misses), 'cache hit rate') +
          tile('tile:hits', hits, 'cache hits') +
          tile('tile:misses', misses, 'cache misses') +
          tile('tile:lookups', hits + misses, 'cache lookups') +
          tile('tile:connections', sum('connections'), 'client connections') +
          tile('tile:distinctIPs', report.distinctIPs, 'distinct IPs') +
          tile('tile:transferred', bytes(sum('bytesUp') + sum('bytesDown')), 'transferred'));
        var s = report.storage;
        set('live-stored', '<table>' +
          statRow('Objects', s.objects) +
          statRow('Large objects', s.largeObjects + ' (' + bytes(s.largeBytes) + ')') +
          statRow('Cached actions', s.actions) +
          statRow('Held in the shard databases', bytes(s.inlineBytes)) +
          statRow('Objects with bodies in R2', s.objectsInR2) + '</table>');
        var asns = report.topASNs || [];
        set('live-asns', asns.length ? '<table><tr><th>ASN</th><th>Organization</th><th>Country</th><th>Connections</th></tr>' +
          asns.map(function (a) {
            return '<tr><td>' + a.asn + '</td><td>' + esc(a.asOrganization) + '</td><td>' + esc(a.country) + '</td><td>' + a.connections + '</td></tr>';
          }).join('') + '</table>' : '<p><small>No connections recorded yet.</small></p>');
        if (!report.enabled) {
          set('live-days', '<p>Traffic counters are not enabled on this deployment.</p>');
        } else {
          set('live-days', '<div class="days">' + report.days.map(function (d) {
            return '<div class="day"><h3>' + d.date + '</h3>' + dayFigures.map(function (f) {
              return '<div class="metric"><span>' + f[0] + '</span><strong data-k="day:' + d.date + ':' + f[0] + '">' + f[1](d) + '</strong></div>';
            }).join('') + '</div>';
          }).join('') + '</div>');
        }
        highlight();
      }
      function load() {
        fetch(prefix + '/stats.json').then(function (r) { return r.json(); }).then(function (r) { report = r; render(); });
      }
      function apply(event) {
        if (!report || !report.enabled) return;
        var day = report.days.filter(function (d) { return d.date === event.date; })[0];
        if (!day) {
          day = { date: event.date };
          fields.forEach(function (f) { day[f] = 0; });
          report.days.unshift(day);
        }
        fields.forEach(function (f) { day[f] += event[f] || 0; });
        render();
      }
      function connect() {
        var socket = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + prefix + '/stats/live');
        socket.onopen = function () { status('Live'); load(); };
        socket.onmessage = function (message) { apply(JSON.parse(message.data)); };
        socket.onclose = function () { status('Reconnecting...'); setTimeout(connect, 3000); };
      }
      status('Connecting...');
      load();
      connect();
      setInterval(load, 30000);
    })();
    """

private func statsDocument(_ report: StatsReport) -> Node {
    let hits = report.days.reduce(0) { $0 + $1.hits }
    let misses = report.days.reduce(0) { $0 + $1.misses }
    let connections = report.days.reduce(0) { $0 + $1.connections }
    let up = report.days.reduce(Int64(0)) { $0 + $1.bytesUp }
    let down = report.days.reduce(Int64(0)) { $0 + $1.bytesDown }

    func tile(_ value: String, _ label: String) -> Node {
        .div(attributes: [.class("tile")], .strong(.text(value)), .text(label))
    }

    let byDay: Node
    if report.enabled {
        byDay = .div(attributes: [.class("days")], .fragment(report.days.map(dayCard)))
    } else {
        byDay = .p("Traffic counters are not enabled on this deployment.")
    }

    return .document(
        .html(
            .head(
                .meta(attributes: [.charset(.utf8)]),
                .title("xcache stats"),
                .meta(viewport: .width(.deviceWidth), .initialScale(1)),
                .style(safe: siteStyle),
                .style(safe: statsStyle)
            ),
            .body(
                .h1("xcache stats"),
                .p(.text("Last \(statsWindowDays) days of traffic, and what the cache holds now. "),
                   .a(attributes: [.href("/")], "Back to setup"), "."),

                .p(attributes: [.id("live-status")], .text("Not live: JavaScript is off.")),

                .div(attributes: [.class("tiles"), .id("live-tiles"), .data("byte-units", ByteSize.unitSymbols.joined(separator: ",")), .data("byte-step", String(ByteSize.step))],
                    tile(formatPercent(hits, of: hits + misses), "cache hit rate"),
                    tile(String(hits), "cache hits"),
                    tile(String(misses), "cache misses"),
                    tile(String(hits + misses), "cache lookups"),
                    tile(String(connections), "client connections"),
                    tile(String(report.distinctIPs), "distinct IPs"),
                    tile(formatBytes(up + down), "transferred")
                ),

                .h2("Stored now"),
                .div(attributes: [.id("live-stored")], storedTable(report.storage)),
                .p(.small("Sizes of bodies kept in R2 that are not part of a large object are not tracked, so the byte figures are a lower bound.")),

                .h2("Top networks"),
                .div(attributes: [.id("live-asns")], asnTable(report.topASNs)),

                .h2("By day"),
                .div(attributes: [.id("live-days")], byDay),
                .p(.small("Connections are WebSocket sessions, not distinct users: everyone shares one access token. Counting is best effort and may miss events.")),

                siteFooter,
                .script(safe: statsScript)
            )
        )
    )
}

func statsResponse(env: Env, scope: String, json: Bool) async -> Response {
    let report = await gatherStats(env: env, scope: scope)
    guard json else { return .html(statsDocument(report)) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let body = try? encoder.encode(report) else { return .error("Could not encode stats", 500) }
    return Response(
        status: 200,
        headers: [("content-type", "application/json; charset=utf-8")],
        body: [UInt8](body))
}

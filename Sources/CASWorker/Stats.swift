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

/// One counter's value for one day.
struct StatsCounter: Codable, Sendable {
    var day: Int
    var name: String
    var value: Int
}

/// What one shard holds. Bodies kept in R2 are counted in `objectsInR2` but
/// not in `inlineBytes`, which only covers what sits in the shard's SQLite.
struct ShardTotals: Codable, Sendable {
    var objects: Int
    var objectsInR2: Int
    var inlineBytes: Int
    var actions: Int
    var largeObjects: Int
    var largeBytes: Int
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
        for (name, delta) in deltas { event.add(name, delta) }
        guard let data = try? JSONEncoder().encode(event) else { return }
        let text = String(decoding: data, as: UTF8.self)
        for viewer in viewers { viewer.send(text) }
    }

    private func database() throws -> SQLStorage {
        if !schemaReady {
            try storage.exec(
                "CREATE TABLE IF NOT EXISTS counters (day INTEGER NOT NULL, name TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (day, name))")
            schemaReady = true
        }
        return storage
    }

    distributed func record(day: Int, deltas: [String: Int]) throws {
        let db = try database()
        for (name, delta) in deltas where delta != 0 {
            try db.exec(
                "INSERT INTO counters (day, name, value) VALUES (?, ?, ?) ON CONFLICT(day, name) DO UPDATE SET value = value + excluded.value",
                day, name, delta)
        }
        if prunedDay != day {
            prunedDay = day
            try db.exec("DELETE FROM counters WHERE day < ?", day - statsRetentionDays)
        }
        broadcast(day: day, deltas: deltas)
    }

    distributed func counters(since day: Int) throws -> [StatsCounter] {
        try database().exec("SELECT day, name, value FROM counters WHERE day >= ? ORDER BY day", day).rows()
            .compactMap { row in
                guard let day = row["day", as: Int.self], let name = row["name", as: String.self],
                      let value = row["value", as: Int.self] else { return nil }
                return StatsCounter(day: day, name: name, value: value)
            }
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

    init?(env: Env) {
        guard env.jsObject["CASSTATS"].object != nil else { return nil }
        let namespace = env.durableObject("CASSTATS")
        guard let keeper = try? CASStatsKeeper.resolve(
            id: namespace.idFromName("stats"), using: WorkersActorSystem(durableObjects: namespace)) else {
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
    var bytesUp = 0
    var bytesDown = 0
    var connections = 0

    /// Adds `value` to the field the counter `name` feeds.
    mutating func add(_ name: String, _ value: Int) {
        switch name {
        case StatsName.hits: hits += value
        case StatsName.misses: misses += value
        case StatsName.actionsPut: actionsPut += value
        case StatsName.objectsPut: objectsPut += value
        case StatsName.objectsGot: objectsGot += value
        case StatsName.bytesUp: bytesUp += value
        case StatsName.bytesDown: bytesDown += value
        case StatsName.connections: connections += value
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
}

/// How many days of traffic the page and `/stats.json` cover.
let statsWindowDays = 30

func gatherStats(env: Env) async -> StatsReport {
    var storage = ShardTotals(objects: 0, objectsInR2: 0, inlineBytes: 0, actions: 0, largeObjects: 0, largeBytes: 0)
    if let shards = try? ShardBackend(namespace: env.durableObject("CASSHARD")).allShards() {
        for shard in shards {
            guard let totals = try? await shard.totals() else { continue }
            storage.objects += totals.objects
            storage.objectsInR2 += totals.objectsInR2
            storage.inlineBytes += totals.inlineBytes
            storage.actions += totals.actions
            storage.largeObjects += totals.largeObjects
            storage.largeBytes += totals.largeBytes
        }
    }

    let now = Int(Date().timeIntervalSince1970)
    guard let client = StatsClient(env: env),
          let counters = try? await client.keeper.counters(since: StatsClient.today() - statsWindowDays + 1) else {
        return StatsReport(enabled: false, generatedAt: now, storage: storage, days: [])
    }
    var byDay = [Int: DayStats]()
    for counter in counters {
        var day = byDay[counter.day] ?? DayStats(date: isoDate(day: counter.day))
        day.add(counter.name, counter.value)
        byDay[counter.day] = day
    }
    let days = byDay.sorted { $0.key > $1.key }.map(\.value)
    return StatsReport(enabled: true, generatedAt: now, storage: storage, days: days)
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

func formatBytes(_ bytes: Int) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    let tenths = Int((value * 10).rounded())
    return unit == 0 ? "\(bytes) B" : "\(tenths / 10).\(tenths % 10) \(units[unit])"
}

func formatPercent(_ part: Int, of total: Int) -> String {
    total == 0 ? "n/a" : "\(Int((Double(part) / Double(total) * 100).rounded()))%"
}

// MARK: - Page

private let statsStyle: StaticString = """
    body { max-width: 720px; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 1.5rem; }
    th, td { text-align: right; padding: 0.3rem 0.6rem; border-bottom: 1px solid var(--border); }
    th:first-child, td:first-child { text-align: left; }
    .tiles { display: flex; gap: 1rem; flex-wrap: wrap; margin-bottom: 1.5rem; }
    .tile { flex: 1; min-width: 140px; background: var(--panel); padding: 1rem; }
    .tile strong { display: block; font-size: 1.6rem; }
    .flash { animation: flash 1.5s ease-out; }
    @keyframes flash {
        from { background-color: var(--flash); }
        to { background-color: transparent; }
    }
    @media (prefers-reduced-motion: reduce) {
        .flash { animation: none; }
    }
    """

private func dayRow(_ day: DayStats) -> ChildOf<Tag.Table> {
    let lookups = day.hits + day.misses
    let rate = formatPercent(day.hits, of: lookups)
    return .tr(
        .td(.text(day.date)),
        .td(.text(rate)),
        .td(.text(String(lookups))),
        .td(.text(String(day.connections))),
        .td(.text(formatBytes(day.bytesUp))),
        .td(.text(formatBytes(day.bytesDown))))
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

/// Keeps the page current: renders the tiles and tables from `/stats.json`
/// (the same figures the server rendered), applies the increments pushed over
/// `/stats/live`, and reloads every 30 seconds because storage totals are not
/// pushed. Without JavaScript the server-rendered page stands as it is.
private let statsScript: StaticString = """
    (function () {
      var report = null;
      var fields = ['hits', 'misses', 'actionsPut', 'objectsPut', 'objectsGot', 'bytesUp', 'bytesDown', 'connections'];
      function bytes(n) {
        var units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'], v = n, u = 0;
        while (v >= 1024 && u < units.length - 1) { v /= 1024; u++; }
        if (u === 0) return n + ' B';
        var t = Math.round(v * 10);
        return Math.floor(t / 10) + '.' + (t % 10) + ' ' + units[u];
      }
      function pct(part, total) { return total === 0 ? 'n/a' : Math.round(part / total * 100) + '%'; }
      function sum(key) { return report.days.reduce(function (a, d) { return a + d[key]; }, 0); }
      function headRow(cells) { return '<tr>' + cells.map(function (c) { return '<th>' + c + '</th>'; }).join('') + '</tr>'; }
      // Cells with a data-k key are the ones highlighted when their text changes.
      function keyed(key, text) { return '<td data-k="' + key + '">' + text + '</td>'; }
      function statRow(label, value) { return '<tr><td>' + label + '</td>' + keyed('stored:' + label, value) + '</tr>'; }
      function tile(key, value, label) { return '<div class="tile"><strong data-k="' + key + '">' + value + '</strong>' + label + '</div>'; }
      function set(id, html) { var e = document.getElementById(id); if (e) e.innerHTML = html; }
      // A changed value flashes and fades over FLASH_MS. The pieces are rebuilt
      // on every render, so a flash still running when the next render comes
      // resumes where it was, by starting its animation that far in.
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
          tile('tile:lookups', hits + misses, 'cache lookups') +
          tile('tile:connections', sum('connections'), 'client connections') +
          tile('tile:transferred', bytes(sum('bytesUp') + sum('bytesDown')), 'transferred'));
        var s = report.storage;
        set('live-stored', '<table>' +
          statRow('Objects', s.objects) +
          statRow('Large objects', s.largeObjects + ' (' + bytes(s.largeBytes) + ')') +
          statRow('Cached actions', s.actions) +
          statRow('Held in the shard databases', bytes(s.inlineBytes)) +
          statRow('Objects with bodies in R2', s.objectsInR2) + '</table>');
        if (!report.enabled) {
          set('live-days', '<p>Traffic counters are not enabled on this deployment.</p>');
        } else {
          set('live-days', '<table>' +
            headRow(['Day', 'Hit rate', 'Lookups', 'Connections', 'Uploaded', 'Downloaded']) +
            report.days.map(function (d) {
              var values = [pct(d.hits, d.hits + d.misses), d.hits + d.misses, d.connections, bytes(d.bytesUp), bytes(d.bytesDown)];
              return '<tr><td>' + d.date + '</td>' + values.map(function (v, i) { return keyed('day:' + d.date + ':' + i, v); }).join('') + '</tr>';
            }).join('') + '</table>');
        }
        highlight();
      }
      function load() {
        fetch('/stats.json').then(function (r) { return r.json(); }).then(function (r) { report = r; render(); });
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
        var socket = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/stats/live');
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
    let up = report.days.reduce(0) { $0 + $1.bytesUp }
    let down = report.days.reduce(0) { $0 + $1.bytesDown }

    func tile(_ value: String, _ label: String) -> Node {
        .div(attributes: [.class("tile")], .strong(.text(value)), .text(label))
    }

    let byDay: Node
    if report.enabled {
        var rows = [ChildOf<Tag.Table>]()
        for day in report.days {
            rows.append(dayRow(day))
        }
        byDay = .table(
            .tr(.th("Day"), .th("Hit rate"), .th("Lookups"), .th("Connections"), .th("Uploaded"), .th("Downloaded")),
            .fragment(rows))
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

                .div(attributes: [.class("tiles"), .id("live-tiles")],
                    tile(formatPercent(hits, of: hits + misses), "cache hit rate"),
                    tile(String(hits + misses), "cache lookups"),
                    tile(String(connections), "client connections"),
                    tile(formatBytes(up + down), "transferred")
                ),

                .h2("Stored now"),
                .div(attributes: [.id("live-stored")], storedTable(report.storage)),
                .p(.small("Sizes of bodies kept in R2 that are not part of a large object are not tracked, so the byte figures are a lower bound.")),

                .h2("By day"),
                .div(attributes: [.id("live-days")], byDay),
                .p(.small("Connections are WebSocket sessions, not distinct users: everyone shares one access token. Counting is best effort and may miss events.")),

                siteFooter,
                .script(safe: statsScript)
            )
        )
    )
}

func statsResponse(env: Env, json: Bool) async -> Response {
    let report = await gatherStats(env: env)
    guard json else { return .html(statsDocument(report)) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let body = try? encoder.encode(report) else { return .error("Could not encode stats", 500) }
    return Response(
        status: 200,
        headers: [("content-type", "application/json; charset=utf-8")],
        body: [UInt8](body))
}

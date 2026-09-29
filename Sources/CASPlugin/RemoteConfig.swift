import Foundation

/// Where the shared tier lives, from the options a client gives the plugin.
///
/// Xcode's build system passes the plugin one option for it,
/// `remote-service-path`, taken from the COMPILATION_CACHE_REMOTE_SERVICE_PATH
/// build setting. That setting is a *path*, so this plugin also accepts a path
/// to a small config file holding the Worker's URL, next to a URL given
/// directly. Precedence: `remote-url`, then `remote-service-path`, then the
/// LLBUILD_CAS_REMOTE_URL environment variable.
///
/// The config file is either the URL on its own or `{"url": "..."}`.
enum RemoteConfig {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static func resolve(
        options: [String: String], environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL? {
        if let value = options["remote-url"] {
            return try url(from: value, source: "remote-url")
        }
        if let value = options["remote-service-path"], !value.isEmpty {
            if isHTTP(value) {
                return try url(from: value, source: "remote-service-path")
            }
            return try url(fromConfigFileAt: value)
        }
        if let value = environment["LLBUILD_CAS_REMOTE_URL"], !value.isEmpty {
            return try url(from: value, source: "LLBUILD_CAS_REMOTE_URL")
        }
        return nil
    }

    private static func isHTTP(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://")
    }

    private static func url(from value: String, source: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
            throw Failure(description: "\(source) must be an http(s) URL: \(value)")
        }
        return url
    }

    private static func url(fromConfigFileAt path: String) throws -> URL {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw Failure(description: "remote-service-path \(path) is neither an http(s) URL nor a readable config file")
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") {
            struct Config: Decodable { var url: String }
            guard let config = try? JSONDecoder().decode(Config.self, from: Data(text.utf8)) else {
                throw Failure(description: "\(path) is not valid config JSON; expected {\"url\": \"...\"}")
            }
            return try url(from: config.url, source: path)
        }
        return try url(from: text, source: path)
    }
}

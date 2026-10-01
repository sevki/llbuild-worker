import Html
import WorkerKit

/// The landing page served at `/`, distinct from `/__rpc` (see `fetch(_:_:_:)`
/// in Worker.swift), which is where the actual CAS traffic goes.
private let indexDocument: Node = .document(
    .html(
        .head(
            .meta(attributes: [.charset(.utf8)]),
            .title("xcache"),
            .meta(viewport: .width(.deviceWidth), .initialScale(1)),
            .style(safe: siteStyle)
        ),
        .body(
            .h1("xcache (pronounced 'ten cache')"),
            .p("A remote content-addressable store for swiftc's compilation caching, hosted on Cloudflare Workers®."),
            .p("Native clients (", .code("castool"), ", the swiftc plugin) speak to ", .code("/__rpc"), " over a WebSocket."),

            .p("Install the prebuilt plugin and the local cache daemon (macOS arm64, Linux x86_64) and point the plugin at it:"),
            .pre(.code("curl --proto '=https' --tlsv1.2 -sSf https://xcache.devtoo.ls/setup | sh")),
            .p("The daemon (", .code("casd"), ") listens on ", .code("127.0.0.1:4170"), " and keeps one connection to this cache, so a build does not open one per compiler process; without it builds are much slower. The installer starts it as a user service and uses it only once it answers; if it cannot (no systemd user session, no release yet), it points the plugin at this cache directly and says so. ", .code("LLBUILD_CAS_NO_DAEMON=1"), " skips it."),
            .p("The cache requires an access token. The installer asks for it (or reads ", .code("LLBUILD_CAS_TOKEN"), ") and saves it to ", .code("~/.config/llbuild-cas-remote-token"), ", where the plugin, the daemon and ", .code("castool"), " look for it."),

            .h2("swiftc"),
            .pre(.code(
                """
                swift build --product CASPlugin

                swiftc -c main.swift -explicit-module-build -cache-compile-job \\
                  -cas-path ~/.cache/llbuild-cas \\
                  -cas-plugin-path .build/debug/libCASPlugin.so \\
                  -cas-plugin-option remote-url=https://xcache.devtoo.ls \\
                  -Rcache-compile-job
                """
            )),
            .p("Without ", .code("remote-url"), " the plugin is a plain local CAS. Build the plugin in release (", .code("swift build -c release --product CASPlugin"), ") for real use."),

            .h2("Xcode® / Swift® Build"),
            .p("Swift Build loads a CAS plugin from ", .code("COMPILATION_CACHE_PLUGIN_PATH"), " and reads ", .code("COMPILATION_CACHE_REMOTE_SERVICE_PATH"), " as a path to a file holding the Worker's URL (or the URL itself):"),
            .pre(.code(
                """
                echo https://xcache.devtoo.ls > ~/.config/llbuild-cas-remote
                swift build -c release --product CASPlugin   # libCASPlugin.dylib on macOS, .so on Linux
                """
            )),
            .pre(.code(
                """
                COMPILATION_CACHE_ENABLE_CACHING = YES
                SWIFT_ENABLE_EXPLICIT_MODULES = YES
                SWIFT_USE_INTEGRATED_DRIVER = YES
                COMPILATION_CACHE_ENABLE_PLUGIN = YES
                COMPILATION_CACHE_PLUGIN_PATH = /path/to/libCASPlugin.dylib
                COMPILATION_CACHE_REMOTE_SERVICE_PATH = /Users/you/.config/llbuild-cas-remote
                """
            )),

            siteFooter
        )
    )
)

extension Response {
    /// A `200 OK` HTML response rendered from an `Html.Node`.
    static func html(_ node: Node) -> Response {
        Response(
            status: 200,
            headers: [("content-type", "text/html; charset=utf-8")],
            body: Array(render(node).utf8))
    }
}

func indexResponse() -> Response {
    .html(indexDocument)
}

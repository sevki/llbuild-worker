import Html
import WorkerKit

let apple_trademarks = ["Xcode®", "Swift®"]
let cloudflare_trademarks = ["Cloudflare®", "Cloudflare Workers®"]
let apple_trademark_notice_template = apple_trademarks.joined(separator: " and ") + " are trademarks of Apple Inc., registered in the U.S. and other countries and regions."
let cloudflare_trademark_notice = cloudflare_trademarks.joined(separator: " and ") + " are trademarks and/or registered trademarks of Cloudflare, Inc."
let devtools_affiliation_notice = "Devtools Ltd. is not affiliated with, or endorsed or sponsored by, Apple Inc. or Cloudflare, Inc."

/// The landing page served at `/`, distinct from `/__rpc` (see `fetch(_:_:_:)`
/// in Worker.swift), which is where the actual CAS traffic goes.
private let indexDocument: Node = .document(
    .html(
        .head(
            .meta(attributes: [.charset(.utf8)]),
            .title("xcache"),
            .meta(viewport: .width(.deviceWidth), .initialScale(1)),
            .style(safe: """
                body {
                    max-width: 640px;
                    margin: 0 auto;
                    padding: 2rem;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                }
                pre {
                    overflow-x: auto;
                    background: #f5f5f5;
                    padding: 1rem;
                }
                .site-footer {
                    text-align: center;
                    padding: 1rem;
                    color: #666;
                }
                """)
        ),
        .body(
            .h1("xcache (pronounced 'ten cache')"),
            .p("A remote content-addressable store for swiftc's compilation caching, hosted on Cloudflare Workers®."),
            .p("Native clients (", .code("castool"), ", the swiftc plugin) speak to ", .code("/__rpc"), " over a WebSocket."),

            .p("Install the prebuilt plugin (macOS arm64, Linux x86_64) and point it at this cache:"),
            .pre(.code("curl --proto '=https' --tlsv1.2 -sSf https://xcache.devtoo.ls/setup | sh")),
            .p("The cache requires an access token. The installer asks for it (or reads ", .code("LLBUILD_CAS_TOKEN"), ") and saves it to ", .code("~/.config/llbuild-cas-remote-token"), ", where the plugin and ", .code("castool"), " look for it."),

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

            .footer(attributes: [.class("site-footer")],
                .small(
                    "© 2026 Devtools Ltd. All rights reserved.",
                    .br,
                    "Devtools Ltd is a limited company registered in England (№ ",
                    .a(attributes: [
                        .href("https://find-and-update.company-information.service.gov.uk/company/16372953"),
                        .target(.blank),
                        .rel(.init(rawValue: "noopener noreferrer")),
                    ], "16372953"),
                    ")."
                ),
                .p(.text("")),
                .small(.text(apple_trademark_notice_template)),
                .p(.text("")),
                .small(.text(cloudflare_trademark_notice)),
                .p(.text("")),
                .small(.text(devtools_affiliation_notice)),
            ),
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

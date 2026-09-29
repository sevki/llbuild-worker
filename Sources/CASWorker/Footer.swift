import Html

// The footer every page carries: copyright and company details, the
// trademark notices Apple and Cloudflare ask for, and the disclaimer that
// this is not their product.

let apple_trademarks = ["Xcode®", "Swift®"]
let cloudflare_trademarks = ["Cloudflare®", "Cloudflare Workers®"]
let apple_trademark_notice_template = apple_trademarks.joined(separator: " and ") + " are trademarks of Apple Inc., registered in the U.S. and other countries and regions."
let cloudflare_trademark_notice = cloudflare_trademarks.joined(separator: " and ") + " are trademarks and/or registered trademarks of Cloudflare, Inc."
let devtools_affiliation_notice = "Devtools Ltd. is not affiliated with, or endorsed or sponsored by, Apple Inc. or Cloudflare, Inc."

let siteFooter: Node = .footer(attributes: [.class("site-footer")],
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
    .small(.text(devtools_affiliation_notice))
)

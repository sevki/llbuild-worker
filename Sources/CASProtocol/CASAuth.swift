import Foundation

/// The token a client presented: `Authorization: Bearer <token>` if sent,
/// otherwise the `token` query parameter. The native WebSocket client has no
/// way to add headers to its upgrade request, so it carries the token in the
/// URL. Tokens are usually URL-safe, but the client builds the URL with
/// URLQueryItem, which may percent-encode characters such as the padding `=`
/// of a base64 token, so the query value is percent-decoded before it is
/// compared.
public func presentedToken(url: String, authorization: String?) -> String? {
    if let authorization, authorization.hasPrefix("Bearer ") {
        return String(authorization.dropFirst("Bearer ".count))
    }
    guard let question = url.firstIndex(of: "?") else { return nil }
    let query = url[url.index(after: question)...].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
    for pair in query.split(separator: "&") {
        if pair.hasPrefix("token=") {
            let raw = String(pair.dropFirst("token=".count))
            return raw.removingPercentEncoding ?? raw
        }
    }
    return nil
}

/// Compares without an early exit on the first differing byte.
public func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let a = Array(a.utf8), b = Array(b.utf8)
    var difference = a.count ^ b.count
    for index in 0..<max(a.count, b.count) {
        difference |= Int(index < a.count ? a[index] : 0) ^ Int(index < b.count ? b[index] : 0)
    }
    return difference == 0
}

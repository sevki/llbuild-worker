import PrefixesDuSI

/// Sizes in SI units: powers of 1000, so 1 kB is 1000 bytes (the binary
/// KiB/MiB of 1024 are a different unit). Storage and transfer are quoted this
/// way, R2 included. The prefixes' symbols and exponents come from the
/// SystemeInternational package rather than being written out here.
public enum ByteSize {
    /// The prefixes used, smallest first: symbol and power of ten, read from the
    /// package's prefix types.
    private static let prefixes: [(symbol: String, exponent: Int)] = [
        (Kilo.symbol, Kilo.scale.exponent),
        (Mega.symbol, Mega.scale.exponent),
        (Giga.symbol, Giga.scale.exponent),
        (Tera.symbol, Tera.scale.exponent),
    ]

    /// How much bigger each unit is than the one before: the gap between two
    /// prefixes' powers of ten (k to M is 10^3), so 1000, not written out here.
    public static let step: Int64 = scale(exponent: prefixes[1].exponent - prefixes[0].exponent)

    /// Digits after the decimal point; `tenthsFactor` scales a size to them.
    private static let fractionDigits = 1
    private static let tenthsFactor: Int64 = scale(exponent: fractionDigits)

    /// Unit symbols from one byte upward: B, kB, MB, GB, TB.
    public static let unitSymbols: [String] = ["B"] + prefixes.map { $0.symbol + "B" }

    /// `1234567` -> "1.2 MB". Whole bytes below 1 kB, otherwise one decimal.
    public static func format(_ bytes: Int) -> String {
        format(Int64(bytes))
    }

    /// The arithmetic is 64-bit on purpose: the Worker runs as 32-bit
    /// WebAssembly, where `Int` overflows at 2.1 GB and 10^12 (a terabyte)
    /// does not fit, which trapped the stats page.
    public static func format(_ bytes: Int64) -> String {
        guard bytes >= step else { return "\(bytes) B" }
        var index = 0
        for candidate in prefixes.indices where bytes >= scale(exponent: prefixes[candidate].exponent) {
            index = candidate
        }
        var tenths = roundedTenths(bytes, exponent: prefixes[index].exponent)
        // 999.95 kB rounds to 1000.0 kB; that reads better as 1.0 MB.
        if tenths >= step * tenthsFactor, index + 1 < prefixes.count {
            index += 1
            tenths = roundedTenths(bytes, exponent: prefixes[index].exponent)
        }
        let fraction = String(tenths % tenthsFactor)
        let padded = String(repeating: "0", count: fractionDigits - fraction.count) + fraction
        return "\(tenths / tenthsFactor).\(padded) \(unitSymbols[index + 1])"
    }

    private static func scale(exponent: Int) -> Int64 {
        var value: Int64 = 1
        for _ in 0..<exponent { value *= 10 }
        return value
    }

    private static func roundedTenths(_ bytes: Int64, exponent: Int) -> Int64 {
        let unit = scale(exponent: exponent)
        return (bytes * tenthsFactor + unit / 2) / unit
    }
}

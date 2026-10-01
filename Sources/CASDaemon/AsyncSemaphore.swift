/// Limits how many tasks run a section at once; waiters go in the order they asked.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) {
        available = max(1, count)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

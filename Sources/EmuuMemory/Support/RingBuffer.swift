import Foundation

/// Fixed-capacity FIFO. Appending past capacity overwrites the oldest element, so memory use is
/// bounded no matter how long the governor runs. Value type; O(1) append.
public struct RingBuffer<Element>: Sendable where Element: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    /// Index of the oldest element once the buffer is full.
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var isFull: Bool { storage.count == capacity }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Elements oldest first.
    public var elements: [Element] {
        guard storage.count == capacity, head != 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    public var first: Element? {
        guard !storage.isEmpty else { return nil }
        return storage.count == capacity ? storage[head] : storage[0]
    }

    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        if storage.count < capacity { return storage[storage.count - 1] }
        return storage[(head + capacity - 1) % capacity]
    }

    /// Calls `body` for each element oldest first without allocating a new array.
    public func forEach(_ body: (Element) throws -> Void) rethrows {
        if storage.count < capacity {
            for e in storage { try body(e) }
        } else {
            for i in 0..<capacity { try body(storage[(head + i) % capacity]) }
        }
    }
}

extension RingBuffer: Equatable where Element: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.capacity == rhs.capacity && lhs.elements == rhs.elements }
}

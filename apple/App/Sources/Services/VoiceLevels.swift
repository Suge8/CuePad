import Synchronization

nonisolated final class VoiceLevels: Sendable {
    let input = Peak()
    let output = Peak()

    final class Peak: Sendable {
        private let value = Atomic<Int16>(0)

        func record(_ samples: UnsafeBufferPointer<Int16>) {
            var loudest: Int16 = 0
            for sample in samples { loudest = max(loudest, sample == .min ? .max : abs(sample)) }
            var current = value.load(ordering: .relaxed)
            while loudest > current {
                let (exchanged, original) = value.compareExchange(expected: current, desired: loudest, ordering: .relaxed)
                if exchanged { break }
                current = original
            }
        }

        func take() -> Double { Double(value.exchange(0, ordering: .relaxed)) / Double(Int16.max) }
    }

    struct Gate {
        static let interval = Duration.milliseconds(50)
        private static let threshold = 0.02, quietMs = 300
        private var loud = false, quietFor = 0, span = 0.0

        mutating func update(_ peak: Double) -> (loud: Bool, peak: Double)? {
            if peak > Self.threshold {
                quietFor = 0
                span = max(span, peak)
                guard !loud else { return nil }
                loud = true
                return (true, peak)
            }
            guard loud else { return nil }
            quietFor += 50
            guard quietFor >= Self.quietMs else { return nil }
            loud = false
            defer { span = 0 }
            return (false, span)
        }
    }
}

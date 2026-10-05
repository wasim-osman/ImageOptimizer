import Foundation
import ImageOptimizerCore

/// Persists `LifetimeStats` as JSON in UserDefaults. The accumulation logic lives in Core, where
/// it is unit-tested; this is only the UserDefaults glue around it.
@MainActor
final class LifetimeStatsStore {
    static let shared = LifetimeStatsStore()
    private let defaultsKey = "lifetimeStats.v1"
    private(set) var stats: LifetimeStats

    private init() {
        if let data = UserDefaults.standard.data(forKey: "lifetimeStats.v1"),
           let decoded = try? JSONDecoder().decode(LifetimeStats.self, from: data) {
            stats = decoded
        } else {
            stats = LifetimeStats()
        }
    }

    func record(inputBytes: Int64, outputBytes: Int64) {
        stats.record(inputBytes: inputBytes, outputBytes: outputBytes)
        guard let data = try? JSONEncoder().encode(stats) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

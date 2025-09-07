import Foundation
import Collections

/// Represents a build execution plan manifest with strategy-specific data
enum BuildPlan: Sendable {
    /// Maximum number of concurrent builds in parallel mode
    static let maxParallelism = 4
    
    /// Serial execution plan with ordered targets
    case serial(targets: [CacheSystem.CacheTarget])
    
    /// Parallel execution plan with dependency graph
    case parallel(
        targets: [String: CacheSystem.CacheTarget],
        dependencyMap: [String: Set<String>],
        dependentMap: [String: Set<String>]
    )
    
    
    // MARK: - Computed Properties
    
    /// Whether this plan uses parallel execution
    var isParallel: Bool {
        switch self {
        case .serial:
            return false
        case .parallel:
            return true
        }
    }
    
    /// Returns the maximum concurrency for this build plan
    var maxConcurrency: Int {
        switch self {
        case .serial:
            return 1
        case .parallel:
            return Self.maxParallelism
        }
    }
    
    /// Returns whether isolated DerivedData should be used
    var shouldUseIsolatedDerivedData: Bool {
        switch self {
        case .serial:
            return false
        case .parallel:
            return true
        }
    }
    
    /// Returns total number of targets in this build plan
    var totalTargetCount: Int {
        switch self {
        case .serial(let targets):
            return targets.count
        case .parallel(let targets, _, _):
            return targets.count
        }
    }
    
    /// Build strategy computed from the enum case
    var strategy: BuildStrategy {
        switch self {
        case .serial:
            return .serial
        case .parallel:
            return .parallel
        }
    }
    
    /// Extracts direct dependency target names from a CacheTarget's dependencies
    /// - Parameter target: Source target to extract dependencies from
    /// - Returns: Array of dependency target names for build planning
    static func extractDirectDependencies(from target: CacheSystem.CacheTarget) -> [String] {
        return target.buildProduct.target.dependencies.compactMap { dependency in
            switch dependency {
            case .module(let module, _):
                return module.name
            case .product(let product, _):
                return product.modules.first?.name
            }
        }
    }
}

// MARK: - CustomStringConvertible

/// Build execution strategy
enum BuildStrategy: Sendable {
    case serial
    case parallel
    
    var displayName: String {
        switch self {
        case .serial:
            return "Serial"
        case .parallel:
            return "Dynamic Parallel"
        }
    }
}

extension BuildPlan: CustomStringConvertible {
    var description: String {
        switch self {
        case .serial(let targets):
            let targetNames = targets.map { $0.buildProduct.target.name }
            return "Serial BuildPlan: [\(targetNames.joined(separator: ", "))]"
            
        case .parallel(let targets, _, _):
            let targetNames = Array(targets.keys).sorted()
            return "Dynamic Parallel BuildPlan: [\(targetNames.joined(separator: ", "))]"
        }
    }
}


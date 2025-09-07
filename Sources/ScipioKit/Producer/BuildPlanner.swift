import Foundation
import Collections

/// Creates build plans from dependency graphs, supporting both serial and parallel execution
struct BuildPlanner {
    
    /// Creates a build plan from a dependency graph
    /// - Parameters:
    ///   - dependencyGraph: The dependency graph of targets to build
    ///   - strategy: Build strategy to use (serial or parallel)
    /// - Returns: A BuildPlan ready for execution
    static func createBuildPlan(
        from dependencyGraph: DependencyGraph<CacheSystem.CacheTarget>,
        strategy: BuildStrategy
    ) -> BuildPlan {
        switch strategy {
        case .serial:
            return createSerialBuildPlan(from: dependencyGraph)
        case .parallel:
            return createParallelBuildPlan(from: dependencyGraph)
        }
    }
    
    // MARK: - Serial Build Plan
    
    /// Creates a serial build plan with ordered targets
    /// Processes dependency graph in topological order for serial execution
    private static func createSerialBuildPlan(
        from dependencyGraph: DependencyGraph<CacheSystem.CacheTarget>
    ) -> BuildPlan {
        var orderedTargets: [CacheSystem.CacheTarget] = []
        var remainingGraph = dependencyGraph
        
        // Process dependency graph level by level (topological sort)
        while !remainingGraph.isEmpty {
            let leafTargets = remainingGraph.leafs.map(\.value)
            
            if !leafTargets.isEmpty {
                orderedTargets.append(contentsOf: leafTargets)
                
                // Remove completed targets from graph
                remainingGraph.remove(leafTargets)
            } else {
                break // Prevent infinite loop in case of circular dependencies
            }
        }
        
        return .serial(targets: orderedTargets)
    }
    
    // MARK: - Parallel Build Plan
    
    /// Creates a parallel build plan with dependency graph data
    /// - Parameter dependencyGraph: Source dependency graph of build targets
    /// - Returns: Parallel BuildPlan with dependency maps for dynamic execution
    private static func createParallelBuildPlan(
        from dependencyGraph: DependencyGraph<CacheSystem.CacheTarget>
    ) -> BuildPlan {
        let components = createDynamicBuildComponents(from: dependencyGraph)
        
        return .parallel(
            targets: components.targets,
            dependencyMap: components.dependencyMap,
            dependentMap: components.dependentMap
        )
    }
    
    // MARK: - Private Implementation
    
    /// Creates components needed for parallel BuildPlan construction
    /// - Parameter dependencyGraph: Source dependency graph of build targets
    /// - Returns: Complete set of components for parallel BuildPlan
    private static func createDynamicBuildComponents(
        from dependencyGraph: DependencyGraph<CacheSystem.CacheTarget>
    ) -> DynamicBuildPlanComponents {
        let targets = createTargetsMap(from: dependencyGraph)
        let dependencyMap = createDependencyMap(from: targets)
        let dependentMap = createDependentMap(from: dependencyMap)
        
        return DynamicBuildPlanComponents(
            targets: targets,
            dependencyMap: dependencyMap,
            dependentMap: dependentMap
        )
    }
    
    /// Creates targets mapping from dependency graph using high-order functions
    /// - Parameter dependencyGraph: Source dependency graph
    /// - Returns: Dictionary mapping target names to CacheTargets
    private static func createTargetsMap(
        from dependencyGraph: DependencyGraph<CacheSystem.CacheTarget>
    ) -> [String: CacheSystem.CacheTarget] {
        return dependencyGraph.allNodes
            .map(\.value)
            .reduce(into: [String: CacheSystem.CacheTarget]()) { result, target in
                result[target.buildProduct.target.name] = target
            }
    }
    
    /// Creates dependency mapping using high-order functions
    /// - Parameter targets: Map of all targets
    /// - Returns: Dictionary mapping target names to their dependency sets
    private static func createDependencyMap(
        from targets: [String: CacheSystem.CacheTarget]
    ) -> [String: Set<String>] {
        return targets.mapValues { target in
            Set(BuildPlan.extractDirectDependencies(from: target))
        }
    }
    
    /// Creates reverse dependency mapping (dependents) using functional approach
    /// - Parameter dependencyMap: Forward dependency mapping
    /// - Returns: Dictionary mapping targets to their dependents
    private static func createDependentMap(
        from dependencyMap: [String: Set<String>]
    ) -> [String: Set<String>] {
        return dependencyMap
            .flatMap { targetName, dependencies in
                dependencies.map { dependency in (dependency, targetName) }
            }
            .reduce(into: [String: Set<String>]()) { result, pair in
                result[pair.0, default: Set()].insert(pair.1)
            }
    }
}

/// Components structure for BuildPlan construction
struct DynamicBuildPlanComponents {
    let targets: [String: CacheSystem.CacheTarget]
    let dependencyMap: [String: Set<String>]
    let dependentMap: [String: Set<String>]
}

// MARK: - Dependency Graph Extensions

extension DependencyGraph {
    /// Returns true if the graph has no more nodes
    var isEmpty: Bool {
        allNodes.isEmpty
    }
}

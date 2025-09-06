import Foundation
import OrderedCollections

/// Represents targets that share a common dependency and can be built in parallel after that dependency completes
struct DependencyCluster: Hashable, Sendable {
    let id: String
    let dependentTargets: Set<BuildProduct>
    let sharedDependency: BuildProduct
    
    init(id: String, dependentTargets: Set<BuildProduct>, sharedDependency: BuildProduct) {
        self.id = id
        self.dependentTargets = dependentTargets
        self.sharedDependency = sharedDependency
    }
}

/// Analyzes dependency graphs to identify clusters that can be built in parallel
struct DependencyClusterAnalyzer {
    
    /// Analyzes the dependency graph and groups targets by their shared dependencies
    /// - Parameter dependencyGraph: The complete dependency graph of build targets
    /// - Returns: Array of dependency clusters grouped by shared dependency
    func analyzeClusters(from dependencyGraph: DependencyGraph<BuildProduct>) -> [DependencyCluster] {
        // Find targets that directly depend on the same dependency
        let dependencyGroups = groupTargetsBySharedDependencies(graph: dependencyGraph)
        
        // Create initial clusters
        let initialClusters = dependencyGroups
            .enumerated()
            .map { index, groupPair in
                let (sharedDep, dependentTargets) = groupPair
                return DependencyCluster(
                    id: "cluster_\(index)",
                    dependentTargets: Set(dependentTargets),
                    sharedDependency: sharedDep
                )
            }
        
        // Merge clusters that have overlapping targets to prevent framework assembly conflicts
        return mergeClustersWithOverlappingTargets(initialClusters)
    }
    
    /// Groups targets by their shared dependencies
    private func groupTargetsBySharedDependencies(
        graph: DependencyGraph<BuildProduct>
    ) -> [BuildProduct: [BuildProduct]] {
        var dependencyToTargets: [BuildProduct: [BuildProduct]] = [:]
        
        // For each node, check what it depends on
        graph.allNodes.forEach { node in
            node.children.forEach { childNode in
                dependencyToTargets[childNode.value, default: []].append(node.value)
            }
        }
        
        // Only return dependencies that are shared by multiple targets
        return dependencyToTargets.filter { _, targets in targets.count > 1 }
    }
    
    /// Finds all leaf dependencies in the entire dependency graph
    func findAllLeafDependencies(in graph: DependencyGraph<BuildProduct>) -> Set<BuildProduct> {
        return Set(graph.leafs.map(\.value))
    }
    
    /// Determines the build order using topological sort principles
    func determineBuildOrder(for clusters: [DependencyCluster], originalGraph: DependencyGraph<BuildProduct>) throws -> InternalBuildPlan {
        // Get all shared dependencies that need to be built first
        let sharedDependencies = clusters.map(\.sharedDependency)
        let sharedDependenciesBuildOrder = try createBuildOrderForDependencies(sharedDependencies, from: originalGraph)
        
        // Create build plans for each cluster
        let clusterBuildPlans = try clusters.map { cluster in
            let clusterBuildOrder = try createBuildOrderForCluster(cluster, from: originalGraph)
            
            // Calculate all transitive dependencies for targets in this cluster
            let allTransitiveDependencies = cluster.dependentTargets.reduce(into: Set<BuildProduct>()) { result, target in
                let transitiveDeps = findAllDependencies(of: target, in: originalGraph)
                result.formUnion(transitiveDeps)
            }
            
            return ClusterBuildPlan(
                cluster: cluster,
                buildOrder: clusterBuildOrder,
                allTransitiveDependencies: allTransitiveDependencies
            )
        }
        
        return InternalBuildPlan(
            sharedDependenciesBuildOrder: sharedDependenciesBuildOrder,
            clusterPlans: clusterBuildPlans
        )
    }
    
    /// Creates build order for shared dependencies including their deep dependencies
    private func createBuildOrderForDependencies(_ dependencies: [BuildProduct], from originalGraph: DependencyGraph<BuildProduct>) throws -> [BuildProduct] {
        // Get all dependencies of shared dependencies (deep traversal)
        let allDependenciesOfSharedDeps = Set(dependencies.flatMap { dep in
            findAllDependencies(of: dep, in: originalGraph)
        })
        
        // Include the shared dependencies themselves
        let allTargetsToSort = allDependenciesOfSharedDeps.union(Set(dependencies))
        
        return try topologicalSort(Array(allTargetsToSort)) { target in
            originalGraph.allNodes
                .first { $0.value == target }?
                .children
                .compactMap { $0.value }
                .filter { allTargetsToSort.contains($0) } ?? []
        }
    }
    
    /// Creates build order for targets within a cluster using topological sort
    private func createBuildOrderForCluster(_ cluster: DependencyCluster, from originalGraph: DependencyGraph<BuildProduct>) throws -> [BuildProduct] {
        let clusterTargets = cluster.dependentTargets
        
        return try topologicalSort(Array(clusterTargets)) { target in
            originalGraph.allNodes
                .first { $0.value == target }?
                .children
                .compactMap { $0.value }
                .filter { clusterTargets.contains($0) } ?? []
        }
    }
    
    /// Finds all dependencies of a given target (deep traversal)
    private func findAllDependencies(of target: BuildProduct, in graph: DependencyGraph<BuildProduct>) -> Set<BuildProduct> {
        guard let targetNode = graph.allNodes.first(where: { $0.value == target }) else {
            return []
        }
        
        var allDependencies: Set<BuildProduct> = []
        var visited: Set<BuildProduct> = []
        
        func traverse(_ node: DependencyGraph<BuildProduct>.Node) {
            guard !visited.contains(node.value) else { return }
            visited.insert(node.value)
            
            node.children.forEach { child in
                allDependencies.insert(child.value)
                traverse(child)
            }
        }
        
        traverse(targetNode)
        return allDependencies
    }
    
    /// Resolves clusters with overlapping targets to prevent framework assembly conflicts
    /// Uses target assignment instead of aggressive merging to preserve parallelism
    /// - Parameter clusters: Initial clusters that may have target overlaps
    /// - Returns: Clusters with no target overlaps, preserving parallelism where possible
    private func mergeClustersWithOverlappingTargets(_ clusters: [DependencyCluster]) -> [DependencyCluster] {
        guard !clusters.isEmpty else { return [] }
        
        // First, try to resolve conflicts by assigning targets to optimal clusters
        let resolvedClusters = resolveTargetConflictsByAssignment(clusters)
        
        // Only merge clusters that still have significant overlaps after assignment
        return mergeRemainingOverlappingClusters(resolvedClusters)
    }
    
    /// Assigns overlapping targets to optimal clusters to minimize conflicts
    /// - Parameter clusters: Initial clusters with potential overlaps
    /// - Returns: Clusters with targets assigned to minimize overlaps
    private func resolveTargetConflictsByAssignment(_ clusters: [DependencyCluster]) -> [DependencyCluster] {
        var resolvedClusters: [DependencyCluster] = []
        var assignedTargets: Set<BuildProduct> = []
        
        // Sort clusters by dependency count (prefer clusters with fewer dependencies for assignment priority)
        let sortedClusters = clusters.sorted { cluster1, cluster2 in
            cluster1.dependentTargets.count < cluster2.dependentTargets.count
        }
        
        for cluster in sortedClusters {
            // Remove targets that have already been assigned to other clusters
            let availableTargets = cluster.dependentTargets.subtracting(assignedTargets)
            
            // Only create cluster if it has remaining targets
            if !availableTargets.isEmpty {
                let updatedCluster = DependencyCluster(
                    id: cluster.id,
                    dependentTargets: availableTargets,
                    sharedDependency: cluster.sharedDependency
                )
                resolvedClusters.append(updatedCluster)
                assignedTargets.formUnion(availableTargets)
            }
        }
        
        return resolvedClusters
    }
    
    /// Merges clusters that still have overlapping targets after assignment resolution
    /// - Parameter clusters: Clusters after target assignment resolution
    /// - Returns: Final clusters with no overlaps
    private func mergeRemainingOverlappingClusters(_ clusters: [DependencyCluster]) -> [DependencyCluster] {
        var result: [DependencyCluster] = []
        var remaining = clusters
        
        while !remaining.isEmpty {
            let current = remaining.removeFirst()
            
            // Find clusters with significant overlap (>50% of targets)
            let overlappingClusters = remaining.enumerated().compactMap { (index, candidate) -> (Int, DependencyCluster)? in
                let intersection = current.dependentTargets.intersection(candidate.dependentTargets)
                let overlapRatio = Double(intersection.count) / Double(min(current.dependentTargets.count, candidate.dependentTargets.count))
                
                return overlapRatio > 0.5 ? (index, candidate) : nil
            }
            
            if overlappingClusters.isEmpty {
                // No significant overlaps, keep cluster as-is
                result.append(current)
            } else {
                // Merge clusters with significant overlaps
                var clustersToMerge = [current]
                
                // Remove overlapping clusters from remaining (in reverse order to maintain indices)
                for (index, cluster) in overlappingClusters.reversed() {
                    clustersToMerge.append(cluster)
                    remaining.remove(at: index)
                }
                
                let mergedCluster = mergeClusterGroup(clustersToMerge)
                result.append(mergedCluster)
            }
        }
        
        return result
    }
    
    /// Merges multiple clusters into a single cluster
    /// - Parameter clusters: Clusters to merge
    /// - Returns: Single merged cluster
    private func mergeClusterGroup(_ clusters: [DependencyCluster]) -> DependencyCluster {
        guard !clusters.isEmpty else {
            fatalError("Cannot merge empty cluster group")
        }
        
        if clusters.count == 1 {
            return clusters[0]
        }
        
        // Combine all targets
        let allTargets = clusters.reduce(into: Set<BuildProduct>()) { result, cluster in
            result.formUnion(cluster.dependentTargets)
        }
        
        // Use the first shared dependency as the primary one
        // In a merged cluster, we'll handle multiple shared dependencies in the build plan
        let primarySharedDependency = clusters[0].sharedDependency
        
        // Create merged cluster ID
        let clusterIds = clusters.map { $0.id }.sorted()
        let mergedId = clusterIds.joined(separator: "_")
        
        return DependencyCluster(
            id: mergedId,
            dependentTargets: allTargets,
            sharedDependency: primarySharedDependency
        )
    }
}

/// Internal build plan structure for dependency analysis
struct InternalBuildPlan {
    let sharedDependenciesBuildOrder: [BuildProduct]
    let clusterPlans: [ClusterBuildPlan]
}

/// Main build plan structure inspired by SPM's BuildPlan
struct BuildPlan {
    let sharedDependencies: [BuildProduct]
    let clusterPlans: [ClusterBuildPlan]
    let executionStrategy: ExecutionStrategy
    
    enum ExecutionStrategy: CustomStringConvertible {
        case sequential
        case parallel
        
        var description: String {
            switch self {
            case .sequential: return "sequential"
            case .parallel: return "parallel"
            }
        }
    }
    
    /// Legacy compatibility
    var sharedDependenciesBuildOrder: [BuildProduct] {
        sharedDependencies
    }
}

/// Represents the build plan for a single cluster
struct ClusterBuildPlan {
    let cluster: DependencyCluster
    let buildOrder: [BuildProduct]
    let allTransitiveDependencies: Set<BuildProduct>
}

// MARK: - BuildProduct Identifiable Conformance
extension BuildProduct: Identifiable {
    var id: String {
        "\(package.id)_\(target.name)"
    }
}
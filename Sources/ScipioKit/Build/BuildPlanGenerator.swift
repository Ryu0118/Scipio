import Foundation
import Collections
import OrderedCollections
import PackageManifestKit

final class BuildPlanGenerator {
    
    private let enableParallelBuild: Bool
    
    init(enableParallelBuild: Bool) {
        self.enableParallelBuild = enableParallelBuild
    }
    
    func generateBuildPlan(
        from dependencyGraph: DependencyGraph<CacheSystem.CacheTarget>
    ) throws -> BuildPlan {
        
        logger.info("📋 Generating build plan...")
        
        let buildProductGraph = dependencyGraph.map { $0.buildProduct }
        let clusters = analyzeDependencyClusters(from: buildProductGraph)
        let executionStrategy = determineExecutionStrategy(for: clusters)
        
        return try createBuildPlan(
            executionStrategy: executionStrategy,
            clusters: clusters,
            buildProductGraph: buildProductGraph
        )
    }
    
    private func analyzeDependencyClusters(
        from buildProductGraph: DependencyGraph<BuildProduct>
    ) -> [DependencyCluster] {
        let analyzer = DependencyClusterAnalyzer()
        let clusters = analyzer.analyzeClusters(from: buildProductGraph)
        
        logger.info("🔍 Dependency analysis: found \(clusters.count) clusters with shared dependencies")
        clusters.enumerated().forEach { index, cluster in
            logger.info("📊 Cluster \(index): \(cluster.dependentTargets.count) targets depend on \(cluster.sharedDependency.target.name)")
        }
        
        return clusters
    }
    
    private func determineExecutionStrategy(for clusters: [DependencyCluster]) -> BuildPlan.ExecutionStrategy {
        let canUseParallel = enableParallelBuild && !clusters.isEmpty
        let executionStrategy: BuildPlan.ExecutionStrategy = canUseParallel ? .parallel : .sequential
        
        logger.info("🚀 Selected execution strategy: \(executionStrategy) (parallel enabled: \(enableParallelBuild), clusters found: \(!clusters.isEmpty))")
        
        return executionStrategy
    }
    
    private func createBuildPlan(
        executionStrategy: BuildPlan.ExecutionStrategy,
        clusters: [DependencyCluster],
        buildProductGraph: DependencyGraph<BuildProduct>
    ) throws -> BuildPlan {
        switch executionStrategy {
        case .parallel:
            return try createParallelBuildPlan(clusters: clusters, buildProductGraph: buildProductGraph)
        case .sequential:
            return createSequentialBuildPlan()
        }
    }
    
    private func createParallelBuildPlan(
        clusters: [DependencyCluster],
        buildProductGraph: DependencyGraph<BuildProduct>
    ) throws -> BuildPlan {
        let analyzer = DependencyClusterAnalyzer()
        let internalBuildPlan = try analyzer.determineBuildOrder(for: clusters, originalGraph: buildProductGraph)
        
        return BuildPlan(
            sharedDependencies: internalBuildPlan.sharedDependenciesBuildOrder,
            clusterPlans: internalBuildPlan.clusterPlans,
            executionStrategy: .parallel
        )
    }
    
    private func createSequentialBuildPlan() -> BuildPlan {
        return BuildPlan(
            sharedDependencies: [],
            clusterPlans: [],
            executionStrategy: .sequential
        )
    }
}
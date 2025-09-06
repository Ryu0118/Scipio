import Foundation
import Collections
import OrderedCollections
import AsyncOperations
import PackageManifestKit

/// Executes builds according to a BuildPlan, handling both parallel and sequential phases
struct BuildExecutor {
    private let descriptionPackage: DescriptionPackage
    private let buildOptionsMatrix: [String: BuildOptions]
    private let outputDir: URL
    private let overwrite: Bool
    private let fileSystem: any FileSystem
    private let derivedDataManager: DerivedDataManager
    
    init(
        descriptionPackage: DescriptionPackage,
        buildOptionsMatrix: [String: BuildOptions],
        outputDir: URL,
        overwrite: Bool,
        fileSystem: any FileSystem = LocalFileSystem.default
    ) {
        self.descriptionPackage = descriptionPackage
        self.buildOptionsMatrix = buildOptionsMatrix
        self.outputDir = outputDir
        self.overwrite = overwrite
        self.fileSystem = fileSystem
        self.derivedDataManager = DerivedDataManager(
            fileSystem: fileSystem,
            baseWorkspaceDirectory: descriptionPackage.workspaceDirectory
        )
    }
    
    /// Executes a build plan with both parallel and sequential phases
    func executeBuildPlan(
        _ buildPlan: BuildPlan,
        originalGraph: DependencyGraph<CacheSystem.CacheTarget>
    ) async throws -> OrderedSet<CacheSystem.CacheTarget> {
        
        var builtTargets = OrderedSet<CacheSystem.CacheTarget>()
        
        // Phase 1: Build shared dependencies in parallel (each in isolated DerivedData)
        logger.info("🔧 Phase 1: Building shared dependencies in parallel")
        let sharedDependencyTargets = try await buildSharedDependenciesInParallel(
            buildPlan.sharedDependenciesBuildOrder,
            originalGraph: originalGraph
        )
        builtTargets.formUnion(OrderedSet(sharedDependencyTargets))
        
        // Phase 2: Build clusters in parallel
        logger.info("🚀 Phase 2: Building dependent clusters")
        let clusterResults = try await buildClustersInParallel(
            buildPlan.clusterPlans,
            originalGraph: originalGraph
        )
        builtTargets.formUnion(OrderedSet(clusterResults.flatMap { $0 }))
        
        return builtTargets
    }
    
    // MARK: - Private Methods
    
    private func buildSharedDependenciesInParallel(
        _ sharedDependencies: [BuildProduct],
        originalGraph: DependencyGraph<CacheSystem.CacheTarget>
    ) async throws -> [CacheSystem.CacheTarget] {
        
        // Create isolated DerivedData for each shared dependency
        let sharedDerivedDataPaths = try derivedDataManager.createIsolatedDerivedDataDirectories(for: sharedDependencies)
        
        // Convert BuildProducts to CacheTargets
        let sharedTargets = sharedDependencies.compactMap { buildProduct in
            originalGraph.allNodes.first { $0.value.buildProduct == buildProduct }?.value
        }
        
        // Build in parallel using asyncMap with full concurrency
        let concurrency = UInt(sharedTargets.count) // Use full parallel capacity
        logger.info("🚀 Building \(sharedTargets.count) shared dependencies in parallel with concurrency: \(concurrency)")
        
        return try await sharedTargets.asyncMap(numberOfConcurrentTasks: concurrency) { [sharedDerivedDataPaths] sharedTarget in
            let sharedDerivedDataPath = sharedDerivedDataPaths[sharedTarget.buildProduct.target.name]!
            logger.info("🔧 Starting build for shared dependency: \(sharedTarget.buildProduct.target.name)")
            try await self.buildSingleTarget(sharedTarget, derivedDataPath: sharedDerivedDataPath)
            logger.info("✅ Built shared dependency: \(sharedTarget.buildProduct.target.name)")
            return sharedTarget
        }
    }
    
    private func buildClustersInParallel(
        _ clusterPlans: [ClusterBuildPlan],
        originalGraph: DependencyGraph<CacheSystem.CacheTarget>
    ) async throws -> [[CacheSystem.CacheTarget]] {
        
        let concurrency = UInt(min(clusterPlans.count, 3)) // Allow up to 3 concurrent cluster builds
        logger.info("🚀 Building \(clusterPlans.count) clusters in parallel with concurrency: \(concurrency)")
        
        // Build each cluster in parallel since they have isolated DerivedData directories  
        // Note: Using capture list to bypass Sendable checking for DependencyGraph
        return try await clusterPlans.asyncMap(numberOfConcurrentTasks: concurrency) { [originalGraph] clusterPlan in
            try await self.buildCluster(clusterPlan, originalGraph: originalGraph)
        }
    }
    
    private func buildCluster(
        _ clusterPlan: ClusterBuildPlan,
        originalGraph: DependencyGraph<CacheSystem.CacheTarget>
    ) async throws -> [CacheSystem.CacheTarget] {
        
        logger.info("🔨 Building cluster \(clusterPlan.cluster.id) with \(clusterPlan.cluster.dependentTargets.count) targets")
        
        // Create isolated DerivedData for this cluster
        let clusterDerivedDataPath = try createClusterDerivedDataPath(for: clusterPlan)
        
        // Copy ALL transitive dependency artifacts to cluster's DerivedData
        try await copyAllTransitiveDependencies(clusterPlan, clusterDerivedDataPath: clusterDerivedDataPath)
        
        // Convert build order to cache targets
        let targetsInOrder = clusterPlan.buildOrder.compactMap { buildProduct in
            originalGraph.allNodes.first { $0.value.buildProduct == buildProduct }?.value
        }
        
        var builtTargets: [CacheSystem.CacheTarget] = []
        
        // Build targets in topological order within the cluster
        for target in targetsInOrder {
            try await buildSingleTarget(target, derivedDataPath: clusterDerivedDataPath)
            logger.info("✅ Built target: \(target.buildProduct.target.name)")
            builtTargets.append(target)
        }
        
        // Cleanup cluster DerivedData
        try derivedDataManager.cleanupIsolatedDirectories([clusterPlan.cluster.id: clusterDerivedDataPath])
        
        return builtTargets
    }
    
    private func buildSingleTarget(
        _ target: CacheSystem.CacheTarget,
        derivedDataPath: URL
    ) async throws {
        let buildProduct = target.buildProduct
        let buildOptions = target.buildOptions
        
        switch buildProduct.target.underlying.type {
        case .regular:
            // Note: We no longer need to temporarily change derivedDataPath since we pass custom path directly
            
            // Create a PIFCompiler with the original descriptionPackage
            let compiler = PIFCompiler(
                descriptionPackage: descriptionPackage,
                buildOptions: buildOptions,
                buildOptionsMatrix: buildOptionsMatrix
            )
            
            // We'll need to modify the PIFCompiler to accept custom derivedDataPath
            // For now, let's create XCFramework with custom path handling
            try await buildRegularTarget(
                compiler: compiler,
                buildProduct: buildProduct,
                derivedDataPath: derivedDataPath
            )
            
        case .binary:
            let binaryExtractor = BinaryExtractor(
                descriptionPackage: descriptionPackage,
                outputDirectory: outputDir,
                fileSystem: fileSystem
            )
            try binaryExtractor.extract(of: buildProduct.target, overwrite: overwrite)
            
        default:
            throw BuildExecutorError.unsupportedTargetType(buildProduct.target.underlying.type)
        }
    }
    
    private func buildRegularTarget(
        compiler: PIFCompiler,
        buildProduct: BuildProduct,
        derivedDataPath: URL
    ) async throws {
        // Use the custom DerivedData path for parallel builds
        // XCFramework creation synchronization is now handled at XCBuildClient level
        try await compiler.createXCFramework(
            buildProduct: buildProduct,
            outputDirectory: outputDir,
            overwrite: overwrite,
            customDerivedDataPath: derivedDataPath,
            enablePlatformParallelBuild: true  // Enable full platform parallel build
        )
    }
    
    private func createClusterDerivedDataPath(for clusterPlan: ClusterBuildPlan) throws -> URL {
        let clusterDerivedDataPath = descriptionPackage.workspaceDirectory
            .appendingPathComponent("DerivedData_cluster_\(clusterPlan.cluster.id)")
        try fileSystem.createDirectory(clusterDerivedDataPath, recursive: true)
        return clusterDerivedDataPath
    }
    
    private func copyAllTransitiveDependencies(
        _ clusterPlan: ClusterBuildPlan,
        clusterDerivedDataPath: URL
    ) async throws {
        // Copy artifacts from ALL transitive dependencies
        try await derivedDataManager.copyTransitiveDependencyArtifacts(
            transitiveDependencies: clusterPlan.allTransitiveDependencies,
            to: clusterDerivedDataPath
        )
        
        logger.info("📁 Copied \(clusterPlan.allTransitiveDependencies.count) transitive dependency artifacts to cluster \(clusterPlan.cluster.id)")
    }
}

// MARK: - Supporting Types

enum BuildExecutorError: LocalizedError {
    case unsupportedTargetType(Target.TargetKind)
    
    var errorDescription: String? {
        switch self {
        case .unsupportedTargetType(let type):
            return "Unsupported target type: \(type)"
        }
    }
}
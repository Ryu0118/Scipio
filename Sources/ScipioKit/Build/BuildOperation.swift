import Foundation
import Collections
import OrderedCollections
import AsyncOperations
import PackageManifestKit

/// Coordinates the overall build process, similar to SPM's BuildOperation
/// Responsible for orchestrating build planning, execution, and coordination
final class BuildOperation {
    
    /// Build configuration
    private let buildOptionsMatrix: [String: BuildOptions]
    private let outputDir: URL
    private let overwrite: Bool
    private let enableParallelBuild: Bool
    private let descriptionPackage: DescriptionPackage
    private let fileSystem: any FileSystem
    
    /// The computed build plan, if any
    private var _buildPlan: BuildPlan?
    
    /// Build executor for parallel execution
    private var buildExecutor: BuildExecutor?
    
    /// Build plan generator
    private let buildPlanGenerator: BuildPlanGenerator
    
    init(
        buildOptionsMatrix: [String: BuildOptions],
        outputDir: URL,
        overwrite: Bool,
        enableParallelBuild: Bool,
        descriptionPackage: DescriptionPackage,
        fileSystem: any FileSystem = LocalFileSystem.default
    ) {
        self.buildOptionsMatrix = buildOptionsMatrix
        self.outputDir = outputDir
        self.overwrite = overwrite
        self.enableParallelBuild = enableParallelBuild
        self.descriptionPackage = descriptionPackage
        self.fileSystem = fileSystem
        self.buildPlanGenerator = BuildPlanGenerator(enableParallelBuild: enableParallelBuild)
    }
    
    /// Executes the complete build operation
    func build(
        dependencyGraph: DependencyGraph<CacheSystem.CacheTarget>
    ) async throws -> OrderedSet<CacheSystem.CacheTarget> {
        
        // Generate build plan from dependency graph
        let buildPlan = try buildPlanGenerator.generateBuildPlan(from: dependencyGraph)
        self._buildPlan = buildPlan
        
        // Execute build plan
        return try await executeBuildPlan(buildPlan, originalGraph: dependencyGraph)
    }
    
    // MARK: - Private Methods
    
    private func executeBuildPlan(
        _ buildPlan: BuildPlan,
        originalGraph: DependencyGraph<CacheSystem.CacheTarget>
    ) async throws -> OrderedSet<CacheSystem.CacheTarget> {
        
        switch buildPlan.executionStrategy {
        case .sequential:
            return try await executeSequentialBuild(originalGraph)
        case .parallel:
            return try await executeParallelBuild(buildPlan, originalGraph: originalGraph)
        }
    }
    
    private func executeSequentialBuild(
        _ dependencyGraph: DependencyGraph<CacheSystem.CacheTarget>
    ) async throws -> OrderedSet<CacheSystem.CacheTarget> {
        
        logger.info("🔄 Executing sequential build...")
        var builtTargets = OrderedSet<CacheSystem.CacheTarget>()
        var graph = dependencyGraph
        
        while let leafNode = graph.leafs.first {
            let target = leafNode.value
            try await buildSingleTarget(target)
            builtTargets.append(target)
            graph.remove(target)
        }
        
        return builtTargets
    }
    
    private func executeParallelBuild(
        _ buildPlan: BuildPlan,
        originalGraph: DependencyGraph<CacheSystem.CacheTarget>
    ) async throws -> OrderedSet<CacheSystem.CacheTarget> {
        
        logger.info("🚀 Executing parallel build...")
        
        // Create build executor if not exists
        if buildExecutor == nil {
            buildExecutor = BuildExecutor(
                descriptionPackage: descriptionPackage,
                buildOptionsMatrix: buildOptionsMatrix,
                outputDir: outputDir,
                overwrite: overwrite,
                fileSystem: fileSystem
            )
        }
        
        return try await buildExecutor!.executeBuildPlan(buildPlan, originalGraph: originalGraph)
    }
    
    private func buildSingleTarget(_ target: CacheSystem.CacheTarget) async throws {
        let buildProduct = target.buildProduct
        let buildOptions = target.buildOptions
        
        switch buildProduct.target.underlying.type {
        case .regular:
            let compiler = PIFCompiler(
                descriptionPackage: descriptionPackage,
                buildOptions: buildOptions,
                buildOptionsMatrix: buildOptionsMatrix
            )
            try await compiler.createXCFramework(
                buildProduct: buildProduct,
                outputDirectory: outputDir,
                overwrite: overwrite
            )
        case .binary:
            let binaryExtractor = BinaryExtractor(
                descriptionPackage: descriptionPackage,
                outputDirectory: outputDir,
                fileSystem: fileSystem
            )
            try binaryExtractor.extract(of: buildProduct.target, overwrite: overwrite)
        default:
            throw BuildOperationError.unsupportedTargetType(buildProduct.target.underlying.type)
        }
    }
}

// MARK: - Supporting Types

enum BuildOperationError: LocalizedError {
    case unsupportedTargetType(Target.TargetKind)
    case buildPlanGenerationFailed(Error)
    
    public var errorDescription: String? {
        switch self {
        case .unsupportedTargetType(let type):
            return "Unsupported target type: \(type)"
        case .buildPlanGenerationFailed(let error):
            return "Build plan generation failed: \(error.localizedDescription)"
        }
    }
}
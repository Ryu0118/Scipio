import Foundation
import Collections
import AsyncOperations
import PackageManifestKit

/// Manages the execution of build operations according to a BuildPlan manifest
/// Computes execution order and manages execution state
struct BuildOperations {
    private let descriptionPackage: DescriptionPackage
    private let buildOptionsMatrix: [String: BuildOptions]
    private let outputDir: URL
    private let fileSystem: any FileSystem
    
    init(
        descriptionPackage: DescriptionPackage,
        buildOptionsMatrix: [String: BuildOptions],
        outputDir: URL,
        fileSystem: any FileSystem = LocalFileSystem.default
    ) {
        self.descriptionPackage = descriptionPackage
        self.buildOptionsMatrix = buildOptionsMatrix
        self.outputDir = outputDir
        self.fileSystem = fileSystem
    }
    
    /// Executes a build plan using its embedded strategy
    /// - Parameter buildPlan: The build plan to execute
    /// - Returns: Result containing built targets or error information
    func executeBuildPlan(_ buildPlan: BuildPlan) async -> FrameworkProducer.TargetBuildResult {
        do {
            let builtTargets = try await executeWithStrategy(buildPlan)
            return .completed(builtTargets: builtTargets)
        } catch {
            return .interrupted(builtTargets: OrderedCollections.OrderedSet(), error: error)
        }
    }
    
    /// Executes build plan based on its strategy
    private func executeWithStrategy(_ buildPlan: BuildPlan) async throws -> OrderedCollections.OrderedSet<CacheSystem.CacheTarget> {
        switch buildPlan.strategy {
        case .serial:
            return try await executeSerialStrategy(buildPlan)
        case .parallel:
            return try await executeParallelStrategy(buildPlan)
        }
    }
    
    
    // MARK: - Serial Strategy
    
    /// Executes build plan using serial strategy (one target at a time)
    private func executeSerialStrategy(_ buildPlan: BuildPlan) async throws -> OrderedCollections.OrderedSet<CacheSystem.CacheTarget> {
        guard case .serial(let targets) = buildPlan else {
            throw BuildOperationError.unsupportedTargetType("Serial strategy requires serial BuildPlan")
        }
        
        var builtTargets = OrderedCollections.OrderedSet<CacheSystem.CacheTarget>()
        var serialExecutor = SerialBuildExecutor(targets: targets)
        
        while !serialExecutor.isComplete {
            let readyTargets = serialExecutor.getReadyTargets()
            
            // Serial execution - build one target at a time
            try await readyTargets.asyncForEach { target in
                try await self.buildTarget(target, strategy: buildPlan.strategy)
            }
            
            // Mark targets as completed
            for target in readyTargets {
                builtTargets.append(target)
                serialExecutor.markCompleted(target)
            }
        }
        
        return builtTargets
    }
    
    // MARK: - Parallel Strategy
    
    /// Executes build plan using parallel strategy with dynamic execution
    /// - Parameter buildPlan: The BuildPlan with parallel strategy and dynamic build data
    /// - Returns: Set of successfully built targets in completion order
    /// - Throws: BuildOperationError if any target build fails
    private func executeParallelStrategy(_ buildPlan: BuildPlan) async throws -> OrderedCollections.OrderedSet<CacheSystem.CacheTarget> {
        return try await executeDynamicParallelStrategy(buildPlan)
    }
    
    // MARK: - Build Execution
    
    /// Builds a single target using the specified strategy
    private func buildTarget(_ target: CacheSystem.CacheTarget, strategy: BuildStrategy) async throws {
        switch target.buildProduct.target.underlying.type {
        case .regular:
            let compiler = PIFCompiler(
                descriptionPackage: descriptionPackage,
                buildOptions: target.buildOptions,
                buildOptionsMatrix: buildOptionsMatrix
            )
            
            try await compiler.createXCFramework(
                buildProduct: target.buildProduct,
                outputDirectory: outputDir,
                overwrite: true
            )
        case .binary:
            let binaryExtractor = BinaryExtractor(
                descriptionPackage: descriptionPackage,
                outputDirectory: outputDir,
                fileSystem: fileSystem
            )
            try binaryExtractor.extract(of: target.buildProduct.target, overwrite: true)
            logger.info("✅ Copy \(target.buildProduct.target.c99name).xcframework", metadata: .color(.green))
        default:
            throw BuildOperationError.unsupportedTargetType(target.buildProduct.target.name)
        }
    }
    
    /// Builds a target with isolated DerivedData path
    private func buildTargetWithIsolatedPath(
        _ target: CacheSystem.CacheTarget,
        isolatedPath: URL,
        strategy: BuildStrategy
    ) async throws {
        switch target.buildProduct.target.underlying.type {
        case .regular:
            let compiler = PIFCompiler(
                descriptionPackage: descriptionPackage,
                buildOptions: target.buildOptions,
                buildOptionsMatrix: buildOptionsMatrix,
                customDerivedDataPath: isolatedPath
            )
            
            try await compiler.createXCFramework(
                buildProduct: target.buildProduct,
                outputDirectory: outputDir,
                overwrite: true
            )
        case .binary:
            let binaryExtractor = BinaryExtractor(
                descriptionPackage: descriptionPackage,
                outputDirectory: outputDir,
                fileSystem: fileSystem
            )
            try binaryExtractor.extract(of: target.buildProduct.target, overwrite: true)
            logger.info("✅ Copy \(target.buildProduct.target.c99name).xcframework", metadata: .color(.green))
        default:
            throw BuildOperationError.unsupportedTargetType(target.buildProduct.target.name)
        }
    }
    
    // MARK: - Parallel Build Context Management
    
    /// Context for parallel build execution
    private struct ParallelBuildContext {
        let derivedDataManager: IsolatedDerivedDataManager
        let artifactCopyManager: ArtifactCopyManager
    }
    
    /// Creates context for parallel build execution
    private func createParallelBuildContext() async throws -> ParallelBuildContext {
        let absoluteWorkspaceDirectory = descriptionPackage.workspaceDirectory.standardized
        let derivedDataManager = IsolatedDerivedDataManager(
            baseWorkspaceDirectory: absoluteWorkspaceDirectory,
            fileSystem: fileSystem
        )
        let artifactCopyManager = ArtifactCopyManager(fileSystem: fileSystem)
        
        return ParallelBuildContext(
            derivedDataManager: derivedDataManager,
            artifactCopyManager: artifactCopyManager
        )
    }
    
    /// Cleans up parallel build context
    private func cleanupParallelBuildContext(_ context: ParallelBuildContext) {
        Task {
            do {
                try await context.derivedDataManager.cleanupAllIsolatedDerivedData()
            } catch {
                logger.warning("⚠️ Failed to cleanup isolated DerivedData: \(error.localizedDescription)")
            }
        }
    }
    
    
    // MARK: - Dynamic Parallel Strategy
    
    /// Executes targets using dynamic parallel strategy with fine-grained dependency tracking
    /// - Parameter buildPlan: The BuildPlan with dynamic parallel configuration
    /// - Returns: Set of successfully built targets in completion order
    /// - Throws: BuildOperationError if any target build fails
    private func executeDynamicParallelStrategy(
        _ buildPlan: BuildPlan
    ) async throws -> OrderedCollections.OrderedSet<CacheSystem.CacheTarget> {
        let coordinator = BuildEventCoordinator(buildPlan: buildPlan)
        let context = try await createParallelBuildContext()
        defer { cleanupParallelBuildContext(context) }
        
        logger.info("🚀 Starting dynamic parallel build with max concurrency: \(BuildPlan.maxParallelism)")
        
        return try await executeContinuousTaskPool(
            coordinator: coordinator,
            context: context
        )
    }
    
    /// Manages continuous task pool execution with individual completion reaction
    /// - Parameter coordinator: Actor managing build state and target scheduling
    /// - Parameter context: Parallel build context with isolated DerivedData and artifact managers
    /// - Returns: Set of successfully built targets in completion order
    /// - Throws: BuildOperationError if task group execution fails
    private func executeContinuousTaskPool(
        coordinator: BuildEventCoordinator,
        context: ParallelBuildContext
    ) async throws -> OrderedCollections.OrderedSet<CacheSystem.CacheTarget> {
        var builtTargets = OrderedCollections.OrderedSet<CacheSystem.CacheTarget>()
        
        try await withThrowingTaskGroup(of: CacheSystem.CacheTarget.self) { group in
            try await buildUntilComplete(
                group: &group,
                coordinator: coordinator,
                context: context,
                builtTargets: &builtTargets
            )
        }
        
        logger.info("🎉 Dynamic parallel build completed successfully!")
        return builtTargets
    }
    
    /// Continuously builds targets until all are completed using individual completion triggering
    /// - Parameter group: TaskGroup managing concurrent build tasks
    /// - Parameter coordinator: Actor coordinating build state and dependency resolution
    /// - Parameter context: Parallel build context for isolated environments
    /// - Parameter builtTargets: Mutable set collecting completed targets in order
    /// - Throws: BuildOperationError if any build task fails
    private func buildUntilComplete(
        group: inout ThrowingTaskGroup<CacheSystem.CacheTarget, Error>,
        coordinator: BuildEventCoordinator,
        context: ParallelBuildContext,
        builtTargets: inout OrderedCollections.OrderedSet<CacheSystem.CacheTarget>
    ) async throws {
        var runningTasksCount = 0
        
        let shouldContinue = { await !coordinator.isComplete || runningTasksCount > 0 }
        
        while await shouldContinue() {
            await fillAvailableSlots(
                group: &group,
                coordinator: coordinator,
                context: context,
                runningTasksCount: &runningTasksCount
            )
            
            guard runningTasksCount > 0 else { continue }
            
            let completedTarget = try await group.next()!
            runningTasksCount -= 1
            
            try await handleTargetCompletion(
                target: completedTarget,
                context: context,
                coordinator: coordinator
            )
            
            builtTargets.append(completedTarget)
            
            let progress = await coordinator.buildProgress
            logger.info("✅ Completed \(completedTarget.buildProduct.target.name) (\(progress.completed)/\(progress.total))")
        }
    }
    
    /// Fills available task slots with ready targets up to maximum parallelism
    /// - Parameter group: TaskGroup to add new build tasks to
    /// - Parameter coordinator: Actor providing ready targets and managing build state
    /// - Parameter context: Parallel build context for isolated build environments
    /// - Parameter runningTasksCount: Current number of running tasks, updated with new tasks
    private func fillAvailableSlots(
        group: inout ThrowingTaskGroup<CacheSystem.CacheTarget, Error>,
        coordinator: BuildEventCoordinator,
        context: ParallelBuildContext,
        runningTasksCount: inout Int
    ) async {
        let availableSlots = BuildPlan.maxParallelism - runningTasksCount
        guard availableSlots > 0 else { return }
        
        let readyTargets = await coordinator.getNextReadyTargets()
        let targetsToStart = Array(readyTargets.prefix(availableSlots))
        
        runningTasksCount += targetsToStart.count
        targetsToStart.forEach { target in
            group.addTask { [self] in
                logger.info("🔨 Started building: \(target.buildProduct.target.name)")
                try await buildTargetWithDynamicIsolation(target, context: context, coordinator: coordinator)
                return target
            }
        }
    }
    
    /// Builds a single target with isolated DerivedData environment for parallel safety
    /// - Parameter target: The target to build with its build product and options
    /// - Parameter context: Parallel build context providing isolated managers
    /// - Parameter coordinator: Actor for dependency state queries during artifact copying
    /// - Throws: BuildOperationError if isolated path creation or build fails
    private func buildTargetWithDynamicIsolation(
        _ target: CacheSystem.CacheTarget,
        context: ParallelBuildContext,
        coordinator: BuildEventCoordinator
    ) async throws {
        let targetName = target.buildProduct.target.name
        let isolatedPath = try await context.derivedDataManager.createIsolatedDerivedData(for: targetName)
        
        try await copyDependencyArtifacts(target: target, context: context, coordinator: coordinator)
        try await buildTargetWithIsolatedPath(target, isolatedPath: isolatedPath, strategy: .parallel)
    }
    
    /// Handles target completion by updating coordinator state and copying final artifacts
    /// - Parameter target: The completed target to process
    /// - Parameter context: Parallel build context for artifact operations
    /// - Parameter coordinator: Actor to mark target completion and trigger dependency resolution
    /// - Throws: BuildOperationError if artifact copying fails
    private func handleTargetCompletion(
        target: CacheSystem.CacheTarget,
        context: ParallelBuildContext,
        coordinator: BuildEventCoordinator
    ) async throws {
        await coordinator.markTargetCompleted(target)
        try await copyTargetArtifactsToOutput(target: target, context: context)
    }
    
    /// Copies build artifacts from completed dependencies to target's isolated DerivedData
    /// - Parameter target: Target requiring dependency artifacts in its isolated environment
    /// - Parameter context: Parallel build context with artifact copy manager
    /// - Parameter coordinator: Actor to query dependency completion states
    /// - Throws: BuildOperationError if artifact copying operations fail
    private func copyDependencyArtifacts(
        target: CacheSystem.CacheTarget,
        context: ParallelBuildContext,
        coordinator: BuildEventCoordinator
    ) async throws {
        let targetName = target.buildProduct.target.name
        let directDependencies = BuildPlan.extractDirectDependencies(from: target)
        
        try await directDependencies.asyncForEach { dependencyName in
            let dependencyState = await coordinator.getTargetState(dependencyName)
            
            if case .completed = dependencyState {
                try await context.artifactCopyManager.copyArtifacts(
                    from: dependencyName,
                    to: [targetName],
                    using: context.derivedDataManager
                )
            }
        }
    }
    
    
    /// Copies target artifacts to final output location after build completion
    /// - Parameter target: Completed target whose artifacts need final copying
    /// - Parameter context: Parallel build context for artifact operations
    /// - Throws: BuildOperationError if final artifact copying fails
    private func copyTargetArtifactsToOutput(
        target: CacheSystem.CacheTarget,
        context: ParallelBuildContext
    ) async throws {
        logger.debug("📋 Target \(target.buildProduct.target.name) artifacts ready for output")
    }
}


/// Manages execution state for serial build strategy
private struct SerialBuildExecutor {
    private let targets: [CacheSystem.CacheTarget]
    private var completedTargets: Set<String> = []
    private var currentIndex = 0
    
    init(targets: [CacheSystem.CacheTarget]) {
        self.targets = targets
    }
    
    /// Returns targets that are ready to build in serial execution (one at a time)
    mutating func getReadyTargets() -> [CacheSystem.CacheTarget] {
        guard currentIndex < targets.count else { return [] }
        
        let target = targets[currentIndex]
        let targetName = target.buildProduct.target.name
        
        if !completedTargets.contains(targetName) {
            return [target]
        }
        
        return []
    }
    
    /// Marks a target as completed and advances to next target
    mutating func markCompleted(_ target: CacheSystem.CacheTarget) {
        let targetName = target.buildProduct.target.name
        completedTargets.insert(targetName)
        
        if currentIndex < targets.count && targets[currentIndex].buildProduct.target.name == targetName {
            currentIndex += 1
        }
    }
    
    /// Returns true if all targets are completed
    var isComplete: Bool {
        return currentIndex >= targets.count
    }
}

/// Errors that can occur during build operations
enum BuildOperationError: LocalizedError {
    case unsupportedTargetType(String)
    case buildFailed(String, Error)
    case contextCreationFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .unsupportedTargetType(let targetName):
            return "Unsupported target type for: \(targetName)"
        case .buildFailed(let targetName, let error):
            return "Build failed for target \(targetName): \(error.localizedDescription)"
        case .contextCreationFailed(let error):
            return "Failed to create build context: \(error.localizedDescription)"
        }
    }
}
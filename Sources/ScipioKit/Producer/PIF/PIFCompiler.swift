import Foundation
import AsyncOperations

struct PIFCompiler: Compiler {
    let descriptionPackage: DescriptionPackage

    private let maxConcurrentSDKBuilds: UInt = 4

    private let fileSystem: any FileSystem
    private let executor: any Executor
    private let buildPipeline: PIFBuildPipeline
    private let buildOptionsMatrix: [String: BuildOptions]
    private let xcBuildClient: XCBuildClient

    init(
        descriptionPackage: DescriptionPackage,
        buildOptionsMatrix: [String: BuildOptions],
        fileSystem: any FileSystem = LocalFileSystem.default,
        executor: any Executor = ProcessExecutor()
    ) {
        self.descriptionPackage = descriptionPackage
        self.buildOptionsMatrix = buildOptionsMatrix
        self.fileSystem = fileSystem
        self.executor = executor
        self.buildPipeline = .init(
            descriptionPackage: descriptionPackage,
            buildOptionsMatrix: buildOptionsMatrix,
            fileSystem: fileSystem,
            executor: executor
        )
        self.xcBuildClient = .init(packageLocator: descriptionPackage)
    }

    func createXCFramework(
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        outputDirectory: URL,
        overwrite: Bool
    ) async throws {
        let sdks = buildOptions.sdks
        let sdkNames = sdks.map(\.displayName).joined(separator: ", ")
        let target = buildProduct.target

        // Build frameworks for each SDK
        logger.info("📦 Building \(target.name) for \(sdkNames)")

        for sdk in sdks {
            try await buildPipeline.executeBuildForSingleTarget(
                buildProduct: buildProduct,
                sdk: sdk,
                buildOptions: buildOptions,
                xcBuildClient: xcBuildClient
            )
        }

        try await buildPipeline.createXCFramework(
            buildProduct: buildProduct,
            buildOptions: buildOptions,
            sdks: Set(sdks),
            outputDirectory: outputDirectory,
            overwrite: overwrite,
            isParallelBuild: false,
            xcBuildClient: xcBuildClient
        )
    }

    func createXCFrameworks(
        parallelBuildGroups: Set<ParallelBuildGroup>,
        outputDirectory: URL,
        overwrite: Bool
    ) async -> TargetBuildResult {
        return await parallelBuildGroups.asyncReduce(
            TargetBuildResult.completed(builtTargets: [])
        ) { accumulated, parallelBuildGroup in
            let groupResult = await processBuildGroup(
                parallelBuildGroup,
                outputDirectory: outputDirectory,
                overwrite: overwrite
            )
            return accumulated.merge(with: groupResult)
        }
    }

    private func processBuildGroup(
        _ parallelBuildGroup: ParallelBuildGroup,
        outputDirectory: URL,
        overwrite: Bool
    ) async -> TargetBuildResult {
        do {
            let result = try await buildGroupWithRetry(parallelBuildGroup)

            guard let succeededGroup = result.succeededGroup else {
                return .interrupted(
                    builtTargets: [],
                    error: XCBuildError.partiallyFailed(targetNames: result.failedTargetNames)
                )
            }

            let buildResult = await createXCFrameworks(
                for: succeededGroup.allTargets(),
                buildOptions: succeededGroup.buildOptions,
                outputDirectory: outputDirectory,
                overwrite: overwrite
            )

            if result.failedTargetNames.isEmpty {
                return buildResult
            } else {
                let failure = TargetBuildResult.interrupted(
                    builtTargets: [],
                    error: XCBuildError.partiallyFailed(targetNames: result.failedTargetNames)
                )
                return buildResult.merge(with: failure)
            }
        } catch {
            return .interrupted(builtTargets: [], error: error)
        }
    }

    private func createXCFrameworks(
        for targets: Set<BuildProduct>,
        buildOptions: BuildOptions,
        outputDirectory: URL,
        overwrite: Bool
    ) async -> TargetBuildResult {
        await targets.asyncReduce(
            TargetBuildResult.completed(builtTargets: [])
        ) { accumulated, target in
            guard case .completed = accumulated else {
                return accumulated
            }

            do {
                try await buildPipeline.createXCFramework(
                    buildProduct: target,
                    buildOptions: buildOptions,
                    sdks: Set(buildOptions.sdks),
                    outputDirectory: outputDirectory,
                    overwrite: overwrite,
                    isParallelBuild: true,
                    xcBuildClient: xcBuildClient
                )
            } catch {
                return .interrupted(builtTargets: accumulated.builtTargets, error: error)
            }

            let cacheTarget = CacheSystem.CacheTarget(
                buildProduct: target,
                buildOptions: buildOptions
            )
            return .completed(builtTargets: accumulated.builtTargets.union([cacheTarget]))
        }
    }

    private func buildGroupWithRetry(
        _ parallelBuildGroup: ParallelBuildGroup,
        allFailedNames: Set<String> = []
    ) async throws -> BuildGroupResult {
        do {
            try await buildGroup(parallelBuildGroup)

            return allFailedNames.isEmpty ? 
                .success(parallelBuildGroup) : 
                .partial(succeeded: parallelBuildGroup, failedTargetNames: allFailedNames)
        } catch let error as XCBuildError {
            let failedNames = allFailedNames.union(error.failedTargetNames)

            logger.warning("⚠️ Build failed for target(s): \(error.failedTargetNames.sorted().joined(separator: ", ")). Retrying without them.")

            guard let remainingGroup = parallelBuildGroup.removingTargets(named: error.failedTargetNames) else {
                return .allFailed(failedTargetNames: failedNames)
            }

            return try await buildGroupWithRetry(
                remainingGroup,
                allFailedNames: failedNames
            )
        }
    }

    private func buildGroup(
        _ group: ParallelBuildGroup
    ) async throws {
        try await group.buildTargetsBySDK.asyncForEach(numberOfConcurrentTasks: maxConcurrentSDKBuilds) { (sdk, targets) in
            logger.info("📦 Building \(targets.map(\.target.name).joined(separator: ", ")) for \(sdk.displayName)")

            try await buildPipeline.executeBuildForMultipleTargets(
                buildProducts: targets,
                sdk: sdk,
                buildOptions: group.buildOptions,
                xcBuildClient: xcBuildClient
            )
        }
    }
}

/// Result of building a ``ParallelBuildGroup`` with retry.
///
/// When a parallel build fails, the failed targets are removed and the remaining targets are retried.
private enum BuildGroupResult {
    /// All targets built successfully.
    case success(ParallelBuildGroup)
    /// Some targets succeeded after removing failed ones.
    case partial(succeeded: ParallelBuildGroup, failedTargetNames: Set<String>)
    /// No targets could be built successfully.
    case allFailed(failedTargetNames: Set<String>)

    var succeededGroup: ParallelBuildGroup? {
        switch self {
        case .success(let group), .partial(let group, _):
            return group
        case .allFailed:
            return nil
        }
    }

    var failedTargetNames: Set<String> {
        switch self {
        case .success:
            return []
        case .partial(_, let names), .allFailed(let names):
            return names
        }
    }
}

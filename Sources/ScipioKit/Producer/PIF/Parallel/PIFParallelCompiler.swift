import Foundation

struct PIFParallelCompiler: ParallelCompiler {
    let descriptionPackage: DescriptionPackage
    private let fileSystem: any FileSystem
    let executor: any Executor
    private let buildOptionsMatrix: [String: BuildOptions]

    private let buildCoordinator: PIFBuildCoordinator

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
        self.buildCoordinator = .init(
            descriptionPackage: descriptionPackage,
            buildOptionsMatrix: buildOptionsMatrix,
            fileSystem: fileSystem,
            executor: executor
        )
    }

    func createXCFrameworks(
        parallelBuildGroups: Set<ParallelBuildGroup>,
        outputDirectory: URL,
        overwrite: Bool
    ) async -> TargetBuildResult {
        let xcBuildClient: XCParallelBuildClient = .init(
            packageLocator: descriptionPackage
        )

        var builtTargets = Set<CacheSystem.CacheTarget>()

        do {
            for parallelBuildGroup in parallelBuildGroups {
                // Build phase: compile all targets for each SDK
                try await parallelBuildGroup.buildTargetsBySDK.asyncForEach(numberOfConcurrentTasks: 4) { (sdk, targets) in
                    logger.info("📦 Building \(targets.map(\.target.name).joined(separator: ", ")) for \(sdk.displayName)")

                    try await buildCoordinator.executeBuildForMultipleTargets(
                        buildProducts: targets,
                        sdk: sdk,
                        buildOptions: parallelBuildGroup.buildOptions,
                        xcBuildClient: xcBuildClient
                    )
                }

                // XCFramework creation phase: create frameworks for successfully built targets
                for target in parallelBuildGroup.allTargets() {
                    try await buildCoordinator.createXCFramework(
                        buildProduct: target,
                        buildOptions: parallelBuildGroup.buildOptions,
                        sdks: Set(parallelBuildGroup.buildOptions.sdks),
                        outputDirectory: outputDirectory,
                        overwrite: overwrite,
                        xcBuildClient: xcBuildClient
                    )

                    // Add to builtTargets only after successful XCFramework creation
                    let cacheTarget = CacheSystem.CacheTarget(
                        buildProduct: target,
                        buildOptions: parallelBuildGroup.buildOptions
                    )
                    builtTargets.insert(cacheTarget)
                }
            }

            return .completed(builtTargets: builtTargets)
        } catch {
            return .interrupted(builtTargets: builtTargets, error: error)
        }
    }
}

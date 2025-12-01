import Foundation

struct PIFCompiler: Compiler {
    let descriptionPackage: DescriptionPackage
    private let buildOptions: BuildOptions
    private let fileSystem: any FileSystem
    let executor: any Executor
    private let buildOptionsMatrix: [String: BuildOptions]

    private let buildCoordinator: PIFBuildCoordinator

    init(
        descriptionPackage: DescriptionPackage,
        buildOptions: BuildOptions,
        buildOptionsMatrix: [String: BuildOptions],
        fileSystem: any FileSystem = LocalFileSystem.default,
        executor: any Executor = ProcessExecutor()
    ) {
        self.descriptionPackage = descriptionPackage
        self.buildOptions = buildOptions
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

    func createXCFramework(buildProduct: BuildProduct, outputDirectory: URL, overwrite: Bool) async throws {
        let sdks = buildOptions.sdks
        let sdkNames = sdks.map(\.displayName).joined(separator: ", ")
        let target = buildProduct.target

        // Build frameworks for each SDK
        logger.info("📦 Building \(target.name) for \(sdkNames)")

        let xcBuildClient: XCBuildClient = .init(
            buildProduct: buildProduct,
            buildOptions: buildOptions,
            configuration: buildOptions.buildConfiguration,
            packageLocator: descriptionPackage
        )

        for sdk in sdks {
            try await buildCoordinator.executeBuildForSingleTarget(
                buildProduct: buildProduct,
                sdk: sdk,
                buildOptions: buildOptions,
                xcBuildClient: xcBuildClient
            )
        }

        try await buildCoordinator.createXCFramework(
            buildProduct: buildProduct,
            buildOptions: buildOptions,
            sdks: Set(sdks),
            outputDirectory: outputDirectory,
            overwrite: overwrite,
            xcBuildClient: xcBuildClient
        )
    }
}

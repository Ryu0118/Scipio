import Foundation

struct PIFParallelCompiler: ParallelCompiler {
    let descriptionPackage: DescriptionPackage
    private let fileSystem: any FileSystem
    private let executor: any Executor
    private let buildOptionsMatrix: [String: BuildOptions]

    private let buildParametersGenerator: BuildParametersGenerator

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
        self.buildParametersGenerator = .init(fileSystem: fileSystem, executor: executor)
    }

    private func fetchDefaultToolchainBinPath() async throws -> URL {
        let result = try await executor.execute("/usr/bin/xcrun", "xcode-select", "-p")
        let rawString = try result.unwrapOutput().trimmingCharacters(in: .whitespacesAndNewlines)
        let developerDirPath = URL(filePath: rawString)
        return developerDirPath.appending(components: "Toolchains", "XcodeDefault.xctoolchain", "usr", "bin")
    }

    private func makeToolchain(for sdk: SDK) async throws -> UserToolchain {
        let toolchainDirPath = try await fetchDefaultToolchainBinPath()
        let toolchainGenerator = ToolchainGenerator(toolchainDirPath: toolchainDirPath)
        return try await toolchainGenerator.makeToolChain(sdk: sdk)
    }

    func createXCFrameworks(
        parallelBuildGroups: Set<ParallelBuildGroup>,
        outputDirectory: URL,
        overwrite: Bool
    ) async throws {
        let xcBuildClient: XCParallelBuildClient = .init(
            packageLocator: descriptionPackage
        )

        let debugSymbolStripper = DWARFSymbolStripper(executor: executor)

        for parallelBuildGroup in parallelBuildGroups {
            try await parallelBuildGroup.buildTargetsBySDK.asyncForEach(numberOfConcurrentTasks: 4) { (sdk, targets) in
                logger.info("📦 Building \(targets.map(\.target.name).joined(separator: ", ")) for \(sdk.displayName)")

                let toolchain = try await makeToolchain(for: sdk)
                let buildParameters = await buildParametersGenerator.generate(
                    from: parallelBuildGroup.buildOptions,
                    toolchain: toolchain
                )

                let generator = try PIFGenerator(
                    packageName: descriptionPackage.name,
                    packageLocator: descriptionPackage,
                    allModules: descriptionPackage.graph.allModules,
                    toolchainLibDirectory: buildParameters.toolchain.toolchainLibDir,
                    buildOptions: parallelBuildGroup.buildOptions,
                    buildOptionsMatrix: buildOptionsMatrix
                )

                let pifPath = try await generator.generateJSON(for: sdk)
                let buildParametersPath = try buildParametersGenerator.generate(
                    for: sdk,
                    buildParameters: buildParameters,
                    buildOptions: parallelBuildGroup.buildOptions,
                    destinationDir: descriptionPackage.workspaceDirectory
                )

                do {
                    let frameworkBundlePaths = try await xcBuildClient.buildFrameworks(
                        buildProducts: targets,
                        buildOptions: parallelBuildGroup.buildOptions,
                        sdk: sdk,
                        pifPath: pifPath,
                        buildParametersPath: buildParametersPath
                    )

                    if parallelBuildGroup.buildOptions.stripStaticDWARFSymbols && parallelBuildGroup.buildOptions.frameworkType == .static {
                        for (buildProduct, frameworkBundlePath) in frameworkBundlePaths {
                            logger.debug("🐛 Stripping debug symbols of \(buildProduct.target.name) (\(sdk.displayName))")
                            let binaryPath = frameworkBundlePath.appending(component: buildProduct.target.c99name)
                            try await debugSymbolStripper.stripDebugSymbol(binaryPath)
                        }
                    }

                } catch {
                    logger.error("Unable to build for \(sdk.displayName)", metadata: .color(.red))
                    logger.error(error)
                }
            }

            try await parallelBuildGroup.allTargets().asyncForEach { target in
                logger.info("🚀 Combining into XCFramework... (\(target.target.name))")

                let frameworkName = target.target.xcFrameworkName
                let outputXCFrameworkPath = URL(filePath: outputDirectory.path).appending(component: frameworkName)
                if fileSystem.exists(outputXCFrameworkPath) && overwrite {
                    logger.info("💥 Delete \(frameworkName)", metadata: .color(.red))
                    try fileSystem.removeFileTree(outputXCFrameworkPath)
                }

                let debugSymbolPaths: [SDK: [URL]]?
                if parallelBuildGroup.buildOptions.isDebugSymbolsEmbedded {
                    debugSymbolPaths = try await extractDebugSymbolPaths(
                        target: target.target,
                        buildConfiguration: parallelBuildGroup.buildOptions.buildConfiguration,
                        sdks: Set(parallelBuildGroup.buildOptions.sdks)
                    )
                } else {
                    debugSymbolPaths = nil
                }

                // Combine all frameworks into one XCFramework
                try await xcBuildClient.createXCFramework(
                    buildProduct: target,
                    buildOptions: parallelBuildGroup.buildOptions,
                    sdks: Set(parallelBuildGroup.buildOptions.sdks),
                    debugSymbols: debugSymbolPaths,
                    outputPath: outputXCFrameworkPath
                )
            }
        }
    }
}

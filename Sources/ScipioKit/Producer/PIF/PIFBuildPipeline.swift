import Foundation
import ScipioKitCore

struct PIFBuildPipeline {
    private let descriptionPackage: DescriptionPackage
    private let executor: any Executor
    private let fileSystem: any FileSystem
    private let buildParametersGenerator: BuildParametersGenerator
    private let buildOptionsMatrix: [String: BuildOptions]

    init(
        descriptionPackage: DescriptionPackage,
        buildOptionsMatrix: [String: BuildOptions],
        fileSystem: any FileSystem,
        executor: any Executor
    ) {
        self.descriptionPackage = descriptionPackage
        self.executor = executor
        self.fileSystem = fileSystem
        self.buildParametersGenerator = .init(fileSystem: fileSystem, executor: executor)
        self.buildOptionsMatrix = buildOptionsMatrix
    }

    // MARK: - Toolchain methods

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

    // MARK: - Build execution

    /// Execute complete build flow for single target
    func executeBuildForSingleTarget(
        buildProduct: BuildProduct,
        sdk: SDK,
        buildOptions: BuildOptions,
        xcBuildClient: XCBuildClient
    ) async throws {
        let toolchain = try await makeToolchain(for: sdk)
        let buildParameters = await buildParametersGenerator.generate(from: buildOptions, toolchain: toolchain)

        let generator = try PIFGenerator(
            packageName: descriptionPackage.name,
            packageLocator: descriptionPackage,
            allModules: descriptionPackage.graph.allModules,
            toolchainLibDirectory: buildParameters.toolchain.toolchainLibDir,
            buildOptions: buildOptions,
            buildOptionsMatrix: buildOptionsMatrix,
            isParallelBuild: false
        )
        let pifPath = try await generator.generateJSON(for: sdk)
        let buildParametersPath = try buildParametersGenerator.generate(
            for: sdk,
            buildParameters: buildParameters,
            buildOptions: buildOptions,
            destinationDir: descriptionPackage.workspaceDirectory
        )

        do {
            let frameworkPath = try await xcBuildClient.buildFramework(
                buildProduct: buildProduct,
                buildOptions: buildOptions,
                sdk: sdk,
                pifPath: pifPath,
                buildParametersPath: buildParametersPath
            )

            // Strip debug symbols if needed
            if buildOptions.stripStaticDWARFSymbols && buildOptions.frameworkType == .static {
                logger.debug("🐛 Stripping debug symbols of \(buildProduct.target.name) (\(sdk.displayName))")
                let binaryPath = frameworkPath.appending(component: buildProduct.target.c99name)
                let debugSymbolStripper = DWARFSymbolStripper(executor: executor)
                try await debugSymbolStripper.stripDebugSymbol(binaryPath)
            }
        } catch {
            logger.error("Unable to build for \(sdk.displayName)", metadata: .color(.red))
            logger.error(error)
            throw error
        }
    }

    /// Execute complete build flow for multiple targets in parallel
    func executeBuildForMultipleTargets(
        buildProducts: Set<BuildProduct>,
        sdk: SDK,
        buildOptions: BuildOptions,
        xcBuildClient: XCBuildClient
    ) async throws {
        let toolchain = try await makeToolchain(for: sdk)
        let buildParameters = await buildParametersGenerator.generate(from: buildOptions, toolchain: toolchain)

        let generator = try PIFGenerator(
            packageName: descriptionPackage.name,
            packageLocator: descriptionPackage,
            allModules: descriptionPackage.graph.allModules,
            toolchainLibDirectory: buildParameters.toolchain.toolchainLibDir,
            buildOptions: buildOptions,
            buildOptionsMatrix: buildOptionsMatrix,
            isParallelBuild: true
        )
        let pifPath = try await generator.generateJSON(for: sdk)
        let buildParametersPath = try buildParametersGenerator.generate(
            for: sdk,
            buildParameters: buildParameters,
            buildOptions: buildOptions,
            destinationDir: descriptionPackage.workspaceDirectory
        )

        do {
            let frameworkPaths = try await xcBuildClient.buildFrameworks(
                buildProducts: buildProducts,
                buildOptions: buildOptions,
                sdk: sdk,
                pifPath: pifPath,
                buildParametersPath: buildParametersPath
            )

            // Strip debug symbols if needed
            if buildOptions.stripStaticDWARFSymbols && buildOptions.frameworkType == .static {
                let debugSymbolStripper = DWARFSymbolStripper(executor: executor)
                for (buildProduct, frameworkPath) in frameworkPaths {
                    logger.debug("🐛 Stripping debug symbols of \(buildProduct.target.name) (\(sdk.displayName))")
                    let binaryPath = frameworkPath.appending(component: buildProduct.target.c99name)
                    try await debugSymbolStripper.stripDebugSymbol(binaryPath)
                }
            }
        } catch {
            logger.error("Unable to build for \(sdk.displayName)", metadata: .color(.red))
            logger.error(error)
            throw error
        }
    }

    // MARK: - XCFramework creation

    func createXCFramework(
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        sdks: Set<SDK>,
        outputDirectory: URL,
        overwrite: Bool,
        isParallelBuild: Bool,
        xcBuildClient: XCBuildClient
    ) async throws {
        logger.info("🚀 Combining into XCFramework... (\(buildProduct.target.name))")

        let frameworkName = buildProduct.target.xcFrameworkName
        let outputXCFrameworkPath = URL(filePath: outputDirectory.path).appending(component: frameworkName)
        try cleanupExistingXCFramework(at: outputXCFrameworkPath, overwrite: overwrite)

        let debugSymbolPaths = try await extractDebugSymbolsIfNeeded(
            for: buildProduct.target,
            buildOptions: buildOptions,
            sdks: sdks,
            isParallelBuild: isParallelBuild
        )

        try await xcBuildClient.createXCFramework(
            buildProduct: buildProduct,
            buildOptions: buildOptions,
            sdks: sdks,
            debugSymbols: debugSymbolPaths,
            outputPath: outputXCFrameworkPath
        )
    }

    // MARK: - Helper methods

    private func cleanupExistingXCFramework(at path: URL, overwrite: Bool) throws {
        if fileSystem.exists(path) && overwrite {
            let frameworkName = path.lastPathComponent
            logger.info("💥 Delete \(frameworkName)", metadata: .color(.red))
            try fileSystem.removeFileTree(path)
        }
    }

    private func extractDebugSymbolsIfNeeded(
        for target: ResolvedModule,
        buildOptions: BuildOptions,
        sdks: Set<SDK>,
        isParallelBuild: Bool
    ) async throws -> [SDK: [URL]]? {
        guard buildOptions.isDebugSymbolsEmbedded else {
            return nil
        }

        let extractor = DwarfExtractor()
        var result = [SDK: [URL]]()

        for sdk in sdks {
            let dsymPath = descriptionPackage.buildDebugSymbolPath(
                buildConfiguration: buildOptions.buildConfiguration,
                sdk: sdk,
                target: target,
                isParallelBuild: isParallelBuild
            )
            guard fileSystem.exists(dsymPath) else { continue }

            let dwarfPath = extractor.dwarfPath(for: target, dSYMPath: dsymPath)
            let dumpedDSYMsMaps = try await extractor.dump(dwarfPath: dwarfPath)
            let bcSymbolMapPaths: [URL] = dumpedDSYMsMaps.values.compactMap { uuid in
                let path = descriptionPackage.productsDirectory(
                    buildConfiguration: buildOptions.buildConfiguration,
                    sdk: sdk,
                    isParallelBuild: isParallelBuild
                )
                    .appending(component: "\(uuid.uuidString).bcsymbolmap")
                guard fileSystem.exists(path) else { return nil }
                return path
            }
            result[sdk] = [dsymPath] + bcSymbolMapPaths
        }
        return result
    }
}

private extension DescriptionPackage {
    func buildDebugSymbolPath(
        buildConfiguration: BuildConfiguration,
        sdk: SDK,
        target: ResolvedModule,
        isParallelBuild: Bool
    ) -> URL {
        productsDirectory(buildConfiguration: buildConfiguration, sdk: sdk, isParallelBuild: isParallelBuild)
            .appending(component: "\(target.name).framework.dSYM")
    }
}

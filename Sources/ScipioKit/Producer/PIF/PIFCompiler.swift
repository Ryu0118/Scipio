import Foundation
import AsyncOperations

struct PIFCompiler: Compiler {
    let descriptionPackage: DescriptionPackage
    private let buildOptions: BuildOptions
    private let fileSystem: any FileSystem
    private let executor: any Executor
    private let buildOptionsMatrix: [String: BuildOptions]

    private let buildParametersGenerator: BuildParametersGenerator
    
    private struct SDKBuildResult {
        let sdk: SDK
        let frameworkPath: URL?
        let error: Error?
        
        init(sdk: SDK, frameworkPath: URL) {
            self.sdk = sdk
            self.frameworkPath = frameworkPath
            self.error = nil
        }
        
        init(sdk: SDK, error: Error) {
            self.sdk = sdk
            self.frameworkPath = nil
            self.error = error
        }
    }

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
        self.buildParametersGenerator = .init(buildOptions: buildOptions, fileSystem: fileSystem, executor: executor)
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

    
    func createXCFramework(buildProduct: BuildProduct, outputDirectory: URL, overwrite: Bool) async throws {
        try await createXCFramework(buildProduct: buildProduct, outputDirectory: outputDirectory, overwrite: overwrite, customDerivedDataPath: nil)
    }
    
    func createXCFramework(buildProduct: BuildProduct, outputDirectory: URL, overwrite: Bool, customDerivedDataPath: URL? = nil, enablePlatformParallelBuild: Bool = true) async throws {
        let sdks = buildOptions.sdks
        let sdkNames = sdks.map(\.displayName).joined(separator: ", ")
        let target = buildProduct.target

        logger.info("📦 Building \(target.name) for \(sdkNames)\(enablePlatformParallelBuild ? " in parallel" : "")")

        let xcBuildClient: XCBuildClient = .init(
            buildProduct: buildProduct,
            buildOptions: buildOptions,
            configuration: buildOptions.buildConfiguration,
            packageLocator: descriptionPackage
        )

        let debugSymbolStripper = DWARFSymbolStripper(executor: executor)

        let frameworkBundlePaths: [SDK: URL]
        
        if enablePlatformParallelBuild && sdks.count > 1 {
            // Build frameworks for all SDKs in parallel
            let sdkBuildResults = await sdks.asyncMap(numberOfConcurrentTasks: UInt(sdks.count)) { sdk in
                do {
                    let result = try await buildFrameworkForSDK(
                        sdk: sdk,
                        target: target,
                        buildProduct: buildProduct,
                        xcBuildClient: xcBuildClient,
                        debugSymbolStripper: debugSymbolStripper,
                        customDerivedDataPath: customDerivedDataPath
                    )
                    return result
                } catch {
                    logger.error("Unable to build for \(sdk.displayName)", metadata: .color(.red))
                    logger.error(error)
                    return SDKBuildResult(sdk: sdk, error: error)
                }
            }
            
            // Check for errors and collect successful results
            var parallelFrameworkPaths: [SDK: URL] = [:]
            var buildErrors: [SDK: Error] = [:]
            
            for result in sdkBuildResults {
                if let error = result.error {
                    buildErrors[result.sdk] = error
                } else if let frameworkPath = result.frameworkPath {
                    parallelFrameworkPaths[result.sdk] = frameworkPath
                }
            }
            
            // If any builds failed, throw the first error
            if !buildErrors.isEmpty {
                let failedPlatforms = buildErrors.keys.map(\.displayName).joined(separator: ", ")
                logger.error("Failed to build for platforms: \(failedPlatforms)", metadata: .color(.red))
                throw buildErrors.values.first!
            }
            
            frameworkBundlePaths = parallelFrameworkPaths
        } else {
            // Build frameworks sequentially to avoid resource conflicts
            var sequentialFrameworkPaths: [SDK: URL] = [:]
            
            for sdk in sdks {
                let result = try await buildFrameworkForSDK(
                    sdk: sdk,
                    target: target,
                    buildProduct: buildProduct,
                    xcBuildClient: xcBuildClient,
                    debugSymbolStripper: debugSymbolStripper,
                    customDerivedDataPath: customDerivedDataPath
                )
                sequentialFrameworkPaths[result.sdk] = result.frameworkPath!
            }
            
            frameworkBundlePaths = sequentialFrameworkPaths
        }
        
        let successfulPlatforms = frameworkBundlePaths.keys.map(\.displayName).joined(separator: ", ")
        logger.info("✅ Successfully built \(target.name) for all platforms: \(successfulPlatforms)")

        logger.info("🚀 Combining into XCFramework...")

        let frameworkName = target.xcFrameworkName
        let outputXCFrameworkPath = URL(filePath: outputDirectory.path).appending(component: frameworkName)

        let debugSymbolPaths: [SDK: [URL]]?
        if buildOptions.isDebugSymbolsEmbedded {
            debugSymbolPaths = try await extractDebugSymbolPaths(target: target,
                                                                 buildConfiguration: buildOptions.buildConfiguration,
                                                                 sdks: Set(sdks))
        } else {
            debugSymbolPaths = nil
        }

        try await xcBuildClient.createXCFramework(
            frameworkPaths: frameworkBundlePaths,
            debugSymbols: debugSymbolPaths,
            outputPath: outputXCFrameworkPath,
            overwrite: overwrite
        )
    }
    
    private func buildFrameworkForSDK(
        sdk: SDK,
        target: ResolvedModule,
        buildProduct: BuildProduct,
        xcBuildClient: XCBuildClient,
        debugSymbolStripper: DWARFSymbolStripper,
        customDerivedDataPath: URL?
    ) async throws -> SDKBuildResult {
        let toolchain = try await makeToolchain(for: sdk)
        let buildParameters = await buildParametersGenerator.generate(from: buildOptions, toolchain: toolchain)

        let platformSpecificDerivedDataPath: URL?
        if let customDerivedDataPath = customDerivedDataPath {
            platformSpecificDerivedDataPath = customDerivedDataPath.appendingPathComponent("Platform_\(sdk.settingValue)")
            try fileSystem.createDirectory(platformSpecificDerivedDataPath!, recursive: true)
            logger.debug("🗂️ Created platform-specific DerivedData: \(platformSpecificDerivedDataPath!.path(percentEncoded: false))")
        } else {
            platformSpecificDerivedDataPath = nil
        }

        let generator = try PIFGenerator(
            packageName: descriptionPackage.name,
            packageLocator: descriptionPackage,
            allModules: descriptionPackage.graph.allModules,
            toolchainLibDirectory: buildParameters.toolchain.toolchainLibDir,
            buildOptions: buildOptions,
            buildOptionsMatrix: buildOptionsMatrix
        )
        
        let effectiveWorkspaceDirectory = platformSpecificDerivedDataPath ?? descriptionPackage.workspaceDirectory
        let pifPath = try await generator.generateJSON(for: sdk, customWorkspaceDirectory: platformSpecificDerivedDataPath)
        let buildParametersPath = try buildParametersGenerator.generate(
            for: sdk,
            buildParameters: buildParameters,
            destinationDir: effectiveWorkspaceDirectory
        )

        logger.debug("🔧 Building \(target.name) for \(sdk.displayName)")
        let frameworkBundlePath = try await xcBuildClient.buildFramework(
            sdk: sdk,
            pifPath: pifPath,
            buildParametersPath: buildParametersPath,
            customDerivedDataPath: platformSpecificDerivedDataPath
        )
        
        logger.debug("✅ Successfully built \(target.name) for \(sdk.displayName)")

        if buildOptions.stripStaticDWARFSymbols && buildOptions.frameworkType == .static {
            logger.debug("🐛 Stripping debug symbols of \(target.name) (\(sdk.displayName))")
            let binaryPath = frameworkBundlePath.appending(component: buildProduct.target.c99name)
            try await debugSymbolStripper.stripDebugSymbol(binaryPath)
        }
        
        return SDKBuildResult(sdk: sdk, frameworkPath: frameworkBundlePath)
    }
}

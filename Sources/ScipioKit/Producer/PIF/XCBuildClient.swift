import Foundation

/// Global coordinator for XCFramework creation synchronization
actor XCFrameworkCreationCoordinator {
    private var activeCreations: Set<String> = []
    
    /// Maximum wait time for XCFramework creation lock (10 minutes)
    private let maxWaitTime: UInt64 = 600_000_000_000 // 10 minutes in nanoseconds
    
    func waitForXCFrameworkCreation(_ frameworkName: String) async throws {
        let startTime = DispatchTime.now()
        let timeout = startTime + .nanoseconds(Int(maxWaitTime))
        
        while activeCreations.contains(frameworkName) {
            // Check for timeout
            if DispatchTime.now() >= timeout {
                logger.error("⚠️ Timeout waiting for XCFramework creation lock: \(frameworkName)")
                throw XCBuildClientError.xcframeworkCreationTimeout(frameworkName)
            }
            
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        activeCreations.insert(frameworkName)
    }
    
    func finishXCFrameworkCreation(_ frameworkName: String) {
        activeCreations.remove(frameworkName)
    }
}

enum XCBuildClientError: LocalizedError {
    case xcframeworkCreationTimeout(String)
    
    var errorDescription: String? {
        switch self {
        case .xcframeworkCreationTimeout(let frameworkName):
            return "Timeout waiting for XCFramework creation lock: \(frameworkName)"
        }
    }
}

struct XCBuildClient {
    enum Error: LocalizedError {
        case xcbuildNotFound

        var errorDescription: String? {
            switch self {
            case .xcbuildNotFound:
                return "xcbuild not found"

            }
        }
    }

    private let buildOptions: BuildOptions
    private let buildProduct: BuildProduct
    private let configuration: BuildConfiguration
    private let packageLocator: any PackageLocator
    private let fileSystem: any FileSystem
    private let executor: any Executor
    
    private static let xcframeworkCreationCoordinator = XCFrameworkCreationCoordinator()

    init(
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        configuration: BuildConfiguration,
        packageLocator: some PackageLocator,
        fileSystem: any FileSystem = LocalFileSystem.default,
        executor: some Executor = ProcessExecutor(errorDecoder: StandardOutputDecoder())
    ) {
        self.buildProduct = buildProduct
        self.buildOptions = buildOptions
        self.configuration = configuration
        self.packageLocator = packageLocator
        self.fileSystem = fileSystem
        self.executor = executor
    }

    private func fetchXCBuildPath() async throws -> URL {
        let developerDirPath = try await fetchDeveloperDirPath()

        let xcBuildPathCandidates = [
            "../SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild", // < Xcode 16.3
            "../SharedFrameworks/SwiftBuild.framework/Versions/A/Support/swbuild", // >= Xcode 16.3
        ]

        let foundXCBuildPath = xcBuildPathCandidates.map { relativePath in
            developerDirPath.appending(path: relativePath).standardizedFileURL
        }.first { [fileSystem] path in
            fileSystem.exists(path)
        }
        guard let foundXCBuildPath else {
            throw Error.xcbuildNotFound
        }

        return foundXCBuildPath
    }

    private func fetchDeveloperDirPath() async throws -> URL {
        let result = try await executor.execute(
            "/usr/bin/xcrun",
            "xcode-select",
            "-p"
        )
        let output = try result.unwrapOutput().trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(filePath: output)
    }

    private var productTargetName: String {
        let productName = buildProduct.target.name
        return "\(productName)_\(String(productName.hash, radix: 16, uppercase: true))_PackageProduct"
    }

    func buildFramework(
        sdk: SDK,
        pifPath: URL,
        buildParametersPath: URL,
        customDerivedDataPath: URL? = nil
    ) async throws -> URL {
        let xcbuildPath = try await fetchXCBuildPath()

        let executor = XCBuildExecutor(xcbuildPath: xcbuildPath)
        let derivedDataPath = customDerivedDataPath ?? packageLocator.derivedDataPath
        try await executor.build(
            pifPath: pifPath,
            configuration: configuration,
            derivedDataPath: derivedDataPath,
            buildParametersPath: buildParametersPath,
            target: buildProduct.target
        )

        let frameworkBundlePath = try assembleFramework(sdk: sdk, customDerivedDataPath: derivedDataPath)
        return frameworkBundlePath
    }

    /// Assemble framework from build artifacts
    /// - Parameter sdk: SDK
    /// - Parameter customDerivedDataPath: Custom DerivedData path to use instead of default
    /// - Returns: Path to assembled framework bundle
    private func assembleFramework(sdk: SDK, customDerivedDataPath: URL? = nil) throws -> URL {
        let effectivePackageLocator: any PackageLocator
        if let customDerivedDataPath = customDerivedDataPath {
            effectivePackageLocator = CustomDerivedDataPackageLocator(
                baseLocator: packageLocator,
                customDerivedDataPath: customDerivedDataPath
            )
        } else {
            effectivePackageLocator = packageLocator
        }
        
        let frameworkComponentsCollector = FrameworkComponentsCollector(
            buildProduct: buildProduct,
            sdk: sdk,
            buildOptions: buildOptions,
            packageLocator: effectivePackageLocator,
            fileSystem: fileSystem
        )

        let components = try frameworkComponentsCollector.collectComponents(sdk: sdk)

        let frameworkOutputDir = effectivePackageLocator.assembledFrameworksDirectory(
            buildConfiguration: buildOptions.buildConfiguration,
            sdk: sdk
        )

        let assembler = FrameworkBundleAssembler(
            frameworkComponents: components,
            keepPublicHeadersStructure: buildOptions.keepPublicHeadersStructure,
            outputDirectory: frameworkOutputDir,
            fileSystem: fileSystem
        )

        return try assembler.assemble()
    }

    private func assembledFrameworkPath(target: ResolvedModule, of sdk: SDK, customDerivedDataPath: URL? = nil) throws -> URL {
        let effectivePackageLocator: any PackageLocator
        if let customDerivedDataPath = customDerivedDataPath {
            effectivePackageLocator = CustomDerivedDataPackageLocator(
                baseLocator: packageLocator,
                customDerivedDataPath: customDerivedDataPath
            )
        } else {
            effectivePackageLocator = packageLocator
        }
        
        let assembledFrameworkDir = effectivePackageLocator.assembledFrameworksDirectory(
            buildConfiguration: buildOptions.buildConfiguration,
            sdk: sdk
        )
        return assembledFrameworkDir
            .appending(component: "\(buildProduct.target.c99name).framework")
    }

    
    func createXCFramework(
        frameworkPaths: [SDK: URL],
        debugSymbols: [SDK: [URL]]?,
        outputPath: URL,
        overwrite: Bool
    ) async throws {
        let frameworkName = outputPath.lastPathComponent
        var lockAcquired = false
        
        do {
            try await Self.xcframeworkCreationCoordinator.waitForXCFrameworkCreation(frameworkName)
            lockAcquired = true
            
            if fileSystem.exists(outputPath) && overwrite {
                logger.info("💥 Delete \(frameworkName)", metadata: .color(.red))
                try fileSystem.removeFileTree(outputPath)
            }
            
            let xcbuildPath = try await fetchXCBuildPath()

            let additionalArguments = try buildCreateXCFrameworkArguments(
                frameworkPaths: frameworkPaths,
                debugSymbols: debugSymbols,
                outputPath: outputPath
            )

            let arguments: [String] = [
                xcbuildPath.path(percentEncoded: false),
                "createXCFramework",
            ]
            + additionalArguments
            
            logger.debug("🔍 XCBuild command: \(arguments.joined(separator: " "))")
            do {
                try await executor.execute(arguments)
                logger.info("✅ Completed XCFramework creation: \(frameworkName)")
            } catch {
                logger.error("❌ XCFramework creation failed for \(frameworkName): \(error)")
                throw error
            }
            
            await Self.xcframeworkCreationCoordinator.finishXCFrameworkCreation(frameworkName)
            lockAcquired = false
            
        } catch {
            if lockAcquired {
                await Self.xcframeworkCreationCoordinator.finishXCFrameworkCreation(frameworkName)
            }
            throw error
        }
    }
    
    private func buildCreateXCFrameworkArguments(
        frameworkPaths: [SDK: URL],
        debugSymbols: [SDK: [URL]]?,
        outputPath: URL
    ) throws -> [String] {
        logger.debug("🔍 XCFramework paths being used:")
        for (sdk, path) in frameworkPaths {
            logger.debug("🔍   \(sdk.displayName): \(path.path(percentEncoded: false))")
        }
        
        let frameworksWithDebugSymbolArguments: [String] = frameworkPaths.keys.reduce([]) { arguments, sdk in
            guard let frameworkPath = frameworkPaths[sdk] else { return arguments }
            var result = arguments + ["-framework", frameworkPath.path(percentEncoded: false)]
            if let debugSymbols, let paths = debugSymbols[sdk] {
                paths.forEach { path in
                    result += ["-debug-symbols", path.path(percentEncoded: false)]
                }
            }
            return result
        }

        let outputPathArguments: [String] = ["-output", outputPath.path(percentEncoded: false)]

        let additionalFlags = buildOptions.enableLibraryEvolution ? [] : ["-allow-internal-distribution"]
        return frameworksWithDebugSymbolArguments + outputPathArguments + additionalFlags
    }
}

private struct CustomDerivedDataPackageLocator: PackageLocator {
    private let baseLocator: any PackageLocator
    private let customPath: URL
    
    var packageDirectory: URL { baseLocator.packageDirectory }
    var derivedDataPath: URL { customPath }
    var workspaceDirectory: URL { customPath.deletingLastPathComponent() }
    
    init(baseLocator: any PackageLocator, customDerivedDataPath: URL) {
        self.baseLocator = baseLocator
        self.customPath = customDerivedDataPath
    }
}

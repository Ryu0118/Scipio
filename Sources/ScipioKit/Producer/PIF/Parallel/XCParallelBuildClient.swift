import Foundation
import ScipioKitCore

struct XCParallelBuildClient {
    enum Error: LocalizedError {
        case xcbuildNotFound

        var errorDescription: String? {
            switch self {
            case .xcbuildNotFound:
                return "xcbuild not found"
            }
        }
    }

    private let packageLocator: any PackageLocator
    private let fileSystem: any FileSystem
    private let executor: any Executor

    init(
        packageLocator: some PackageLocator,
        fileSystem: any FileSystem = LocalFileSystem.default,
        executor: some Executor = ProcessExecutor(errorDecoder: StandardOutputDecoder())
    ) {
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

    func buildFrameworks(
        buildProducts: Set<BuildProduct>,
        buildOptions: BuildOptions,
        sdk: SDK,
        pifPath: URL,
        buildParametersPath: URL
    ) async throws -> [BuildProduct: URL] {
        let xcbuildPath = try await fetchXCBuildPath()

        let executor = XCBuildExecutor(xcbuildPath: xcbuildPath)
        try await executor.build(
            pifPath: pifPath,
            configuration: buildOptions.buildConfiguration,
            derivedDataPath: packageLocator.derivedDataPath(for: sdk),
            buildParametersPath: buildParametersPath,
            targets: Set(buildProducts.map(\.target))
        )

        let frameworkBundlePath = try assembleFrameworks(
            sdk: sdk,
            buildOptions: buildOptions,
            buildProducts: buildProducts
        )
        return frameworkBundlePath
    }

    /// Assemble framework from build artifacts
    /// - Parameter sdk: SDK
    /// - Returns: Path to assembled framework bundle
    private func assembleFrameworks(
        sdk: SDK,
        buildOptions: BuildOptions,
        buildProducts: Set<BuildProduct>
    ) throws -> [BuildProduct: URL] {
        try buildProducts.reduce(into: [BuildProduct: URL]()) { partialResult, buildProduct in
            let frameworkComponentsCollector = FrameworkComponentsCollector(
                buildProduct: buildProduct,
                sdk: sdk,
                buildOptions: buildOptions,
                packageLocator: packageLocator,
                fileSystem: fileSystem
            )

            let components = try frameworkComponentsCollector.collectComponents(sdk: sdk)

            let frameworkOutputDir = packageLocator.assembledFrameworksDirectory(
                buildConfiguration: buildOptions.buildConfiguration,
                sdk: sdk
            )

            let assembler = FrameworkBundleAssembler(
                frameworkComponents: components,
                keepPublicHeadersStructure: buildOptions.keepPublicHeadersStructure,
                outputDirectory: frameworkOutputDir,
                fileSystem: fileSystem
            )

            partialResult[buildProduct] = try assembler.assemble()
        }
    }

    private func assembledFrameworkPath(
        target: ResolvedModule,
        buildOptions: BuildOptions,
        of sdk: SDK
    ) throws -> URL {
        let assembledFrameworkDir = packageLocator.assembledFrameworksDirectory(
            buildConfiguration: buildOptions.buildConfiguration,
            sdk: sdk
        )
        return assembledFrameworkDir
            .appending(component: "\(target.c99name).framework")
    }

    func createXCFramework(
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        sdks: Set<SDK>,
        debugSymbols: [SDK: [URL]]?,
        outputPath: URL
    ) async throws {
        let xcbuildPath = try await fetchXCBuildPath()

        let additionalArguments = try buildCreateXCFrameworkArguments(
            buildProduct: buildProduct,
            buildOptions: buildOptions,
            sdks: sdks,
            debugSymbols: debugSymbols,
            outputPath: outputPath
        )

        let arguments: [String] = [
            xcbuildPath.path(percentEncoded: false),
            "createXCFramework",
        ]
        + additionalArguments
        try await executor.execute(arguments)
    }

    private func buildCreateXCFrameworkArguments(
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        sdks: Set<SDK>,
        debugSymbols: [SDK: [URL]]?,
        outputPath: URL
    ) throws -> [String] {
        let frameworksWithDebugSymbolArguments: [String] = try sdks.reduce([]) {
            arguments,
            sdk in
            let path = try assembledFrameworkPath(
                target: buildProduct.target,
                buildOptions: buildOptions,
                of: sdk
            )
            var result = arguments + ["-framework", path.path(percentEncoded: false)]
            if let debugSymbols,
               let paths = debugSymbols[sdk] {
                paths.forEach { path in
                    result += ["-debug-symbols", path.path(percentEncoded: false)]
                }
            }
            return result
        }

        let outputPathArguments: [String] = ["-output", outputPath.path(percentEncoded: false)]

        // Default behavior, this command requires swiftinterface. If they don't exist, `-allow-internal-distribution` must be required.
        let additionalFlags = buildOptions.enableLibraryEvolution ? [] : ["-allow-internal-distribution"]
        return frameworksWithDebugSymbolArguments + outputPathArguments + additionalFlags
    }
}

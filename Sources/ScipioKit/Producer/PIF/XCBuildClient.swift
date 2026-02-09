import Foundation
import ScipioKitCore

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

    private let packageLocator: any PackageLocator
    private let fileSystem: any FileSystem
    private let executor: any Executor
    private let frameworkAssembler: FrameworkAssembler

    init(
        packageLocator: some PackageLocator,
        fileSystem: any FileSystem = LocalFileSystem.default,
        executor: some Executor = ProcessExecutor(errorDecoder: StandardOutputDecoder())
    ) {
        self.packageLocator = packageLocator
        self.fileSystem = fileSystem
        self.executor = executor
        self.frameworkAssembler = FrameworkAssembler(packageLocator: packageLocator, fileSystem: fileSystem)
    }

    func buildFramework(
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        sdk: SDK,
        pifPath: URL,
        buildParametersPath: URL
    ) async throws -> URL {
        let xcbuildPath = try await fetchXCBuildPath()

        let executor = XCBuildExecutor(xcbuildPath: xcbuildPath)
        try await executor.build(
            pifPath: pifPath,
            configuration: buildOptions.buildConfiguration,
            derivedDataPath: packageLocator.derivedDataPath,
            buildParametersPath: buildParametersPath,
            target: buildProduct.target
        )

        return try assembleFramework(
            buildProduct: buildProduct,
            sdk: sdk,
            buildOptions: buildOptions,
            isParallelBuild: false
        )
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

        return try assembleFrameworks(
            buildProducts: buildProducts,
            sdk: sdk,
            buildOptions: buildOptions,
            isParallelBuild: true
        )
    }

    func createXCFramework(
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        sdks: Set<SDK>,
        debugSymbols: [SDK: [URL]]?,
        outputPath: URL
    ) async throws {
        let xcbuildPath = try await fetchXCBuildPath()

        let frameworkPaths = try sdks.reduce(into: [SDK: URL]()) { result, sdk in
            result[sdk] = try assembledFrameworkPath(
                target: buildProduct.target,
                buildOptions: buildOptions,
                of: sdk
            )
        }

        let additionalArguments = buildCreateXCFrameworkArguments(
            frameworkPaths: frameworkPaths,
            debugSymbols: debugSymbols,
            outputPath: outputPath,
            enableLibraryEvolution: buildOptions.enableLibraryEvolution
        )

        let arguments: [String] = [
            xcbuildPath.path(percentEncoded: false),
            "createXCFramework",
        ] + additionalArguments

        try await executor.execute(arguments)
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

    private func assembleFramework(
        buildProduct: BuildProduct,
        sdk: SDK,
        buildOptions: BuildOptions,
        isParallelBuild: Bool
    ) throws -> URL {
        try frameworkAssembler.assembleFramework(
            buildProduct: buildProduct,
            sdk: sdk,
            buildOptions: buildOptions,
            isParallelBuild: isParallelBuild
        )
    }

    private func assembleFrameworks(
        buildProducts: Set<BuildProduct>,
        sdk: SDK,
        buildOptions: BuildOptions,
        isParallelBuild: Bool
    ) throws -> [BuildProduct: URL] {
        try buildProducts.reduce(into: [BuildProduct: URL]()) { partialResult, buildProduct in
            partialResult[buildProduct] = try frameworkAssembler.assembleFramework(
                buildProduct: buildProduct,
                sdk: sdk,
                buildOptions: buildOptions,
                isParallelBuild: isParallelBuild
            )
        }
    }

    private func assembledFrameworkPath(
        target: ResolvedModule,
        buildOptions: BuildOptions,
        of sdk: SDK
    ) throws -> URL {
        frameworkAssembler.assembledFrameworkPath(
            target: target,
            buildOptions: buildOptions,
            sdk: sdk
        )
    }

    private func buildCreateXCFrameworkArguments(
        frameworkPaths: [SDK: URL],
        debugSymbols: [SDK: [URL]]?,
        outputPath: URL,
        enableLibraryEvolution: Bool
    ) -> [String] {
        let frameworksWithDebugSymbolArguments: [String] = frameworkPaths.reduce([]) { arguments, entry in
            let (sdk, path) = entry
            var result = arguments + ["-framework", path.path(percentEncoded: false)]
            if let debugSymbols, let paths = debugSymbols[sdk] {
                paths.forEach { path in
                    result += ["-debug-symbols", path.path(percentEncoded: false)]
                }
            }
            return result
        }

        let outputPathArguments: [String] = ["-output", outputPath.path(percentEncoded: false)]

        // Default behavior, this command requires swiftinterface. If they don't exist, `-allow-internal-distribution` must be required.
        let additionalFlags = enableLibraryEvolution ? [] : ["-allow-internal-distribution"]
        return frameworksWithDebugSymbolArguments + outputPathArguments + additionalFlags
    }
}

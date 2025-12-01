import Foundation
import ScipioKitCore

struct XCParallelBuildClient {
    private let packageLocator: any PackageLocator
    private let fileSystem: any FileSystem
    private let executor: any Executor
    private let pathLocator: XCBuildPathLocator
    private let frameworkBuilder: XCFrameworkBuilder
    private let frameworkAssembler: FrameworkAssembler

    init(
        packageLocator: some PackageLocator,
        fileSystem: any FileSystem = LocalFileSystem.default,
        executor: some Executor = ProcessExecutor(errorDecoder: StandardOutputDecoder())
    ) {
        self.packageLocator = packageLocator
        self.fileSystem = fileSystem
        self.executor = executor
        self.pathLocator = XCBuildPathLocator(fileSystem: fileSystem, executor: executor)
        self.frameworkBuilder = XCFrameworkBuilder(executor: executor)
        self.frameworkAssembler = FrameworkAssembler(packageLocator: packageLocator, fileSystem: fileSystem)
    }

    func buildFrameworks(
        buildProducts: Set<BuildProduct>,
        buildOptions: BuildOptions,
        sdk: SDK,
        pifPath: URL,
        buildParametersPath: URL
    ) async throws -> [BuildProduct: URL] {
        let xcbuildPath = try await pathLocator.fetchXCBuildPath()

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
            partialResult[buildProduct] = try frameworkAssembler.assembleFramework(
                buildProduct: buildProduct,
                sdk: sdk,
                buildOptions: buildOptions
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

    func createXCFramework(
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        sdks: Set<SDK>,
        debugSymbols: [SDK: [URL]]?,
        outputPath: URL
    ) async throws {
        let xcbuildPath = try await pathLocator.fetchXCBuildPath()

        let frameworkPaths = try sdks.reduce(into: [SDK: URL]()) { result, sdk in
            result[sdk] = try assembledFrameworkPath(
                target: buildProduct.target,
                buildOptions: buildOptions,
                of: sdk
            )
        }

        try await frameworkBuilder.createXCFramework(
            xcbuildPath: xcbuildPath,
            frameworkPaths: frameworkPaths,
            debugSymbols: debugSymbols,
            outputPath: outputPath,
            enableLibraryEvolution: buildOptions.enableLibraryEvolution
        )
    }
}

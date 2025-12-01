import Foundation
import ScipioKitCore

struct XCBuildClient {
    private let buildOptions: BuildOptions
    private let buildProduct: BuildProduct
    private let configuration: BuildConfiguration
    private let packageLocator: any PackageLocator
    private let fileSystem: any FileSystem
    private let executor: any Executor
    private let pathLocator: XCBuildPathLocator
    private let frameworkBuilder: XCFrameworkBuilder
    private let frameworkAssembler: FrameworkAssembler

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
        self.pathLocator = XCBuildPathLocator(fileSystem: fileSystem, executor: executor)
        self.frameworkBuilder = XCFrameworkBuilder(executor: executor)
        self.frameworkAssembler = FrameworkAssembler(packageLocator: packageLocator, fileSystem: fileSystem)
    }

    private var productTargetName: String {
        let productName = buildProduct.target.name
        return "\(productName)_\(String(productName.hash, radix: 16, uppercase: true))_PackageProduct"
    }

    func buildFramework(
        sdk: SDK,
        pifPath: URL,
        buildParametersPath: URL
    ) async throws -> URL {
        let xcbuildPath = try await pathLocator.fetchXCBuildPath()

        let executor = XCBuildExecutor(xcbuildPath: xcbuildPath)
        try await executor.build(
            pifPath: pifPath,
            configuration: configuration,
            derivedDataPath: packageLocator.derivedDataPath,
            buildParametersPath: buildParametersPath,
            target: buildProduct.target
        )

        let frameworkBundlePath = try assembleFramework(sdk: sdk)
        return frameworkBundlePath
    }

    /// Assemble framework from build artifacts
    /// - Parameter sdk: SDK
    /// - Returns: Path to assembled framework bundle
    private func assembleFramework(sdk: SDK) throws -> URL {
        try frameworkAssembler.assembleFramework(
            buildProduct: buildProduct,
            sdk: sdk,
            buildOptions: buildOptions
        )
    }

    private func assembledFrameworkPath(target: ResolvedModule, of sdk: SDK) throws -> URL {
        frameworkAssembler.assembledFrameworkPath(
            target: target,
            buildOptions: buildOptions,
            sdk: sdk
        )
    }

    func createXCFramework(
        sdks: Set<SDK>,
        debugSymbols: [SDK: [URL]]?,
        outputPath: URL
    ) async throws {
        let xcbuildPath = try await pathLocator.fetchXCBuildPath()

        let frameworkPaths = try sdks.reduce(into: [SDK: URL]()) { result, sdk in
            result[sdk] = try assembledFrameworkPath(target: buildProduct.target, of: sdk)
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

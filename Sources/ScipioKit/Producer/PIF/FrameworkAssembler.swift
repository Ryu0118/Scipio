import Foundation
import ScipioKitCore

struct FrameworkAssembler {
    private let packageLocator: any PackageLocator
    private let fileSystem: any FileSystem

    init(
        packageLocator: some PackageLocator,
        fileSystem: any FileSystem = LocalFileSystem.default
    ) {
        self.packageLocator = packageLocator
        self.fileSystem = fileSystem
    }

    func assembleFramework(
        buildProduct: BuildProduct,
        sdk: SDK,
        buildOptions: BuildOptions,
        isParallelBuild: Bool
    ) throws -> URL {
        let frameworkComponentsCollector = FrameworkComponentsCollector(
            buildProduct: buildProduct,
            sdk: sdk,
            buildOptions: buildOptions,
            packageLocator: packageLocator,
            isParallelBuild: isParallelBuild,
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

        return try assembler.assemble()
    }

    func assembledFrameworkPath(
        target: ResolvedModule,
        buildOptions: BuildOptions,
        sdk: SDK
    ) -> URL {
        let assembledFrameworkDir = packageLocator.assembledFrameworksDirectory(
            buildConfiguration: buildOptions.buildConfiguration,
            sdk: sdk
        )
        return assembledFrameworkDir
            .appending(component: "\(target.c99name).framework")
    }
}

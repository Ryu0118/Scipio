import Foundation
import Basics

struct MacroExecutableProducer {
    private let descriptionPackage: DescriptionPackage
    private let outputDir: URL
    private let buildConfiguration: BuildConfiguration
    private let toolchainEnvironment: ToolchainEnvironment?
    private let fileSystem: any FileSystem

    init(
        descriptionPackage: DescriptionPackage,
        outputDir: URL,
        buildConfiguration: BuildConfiguration,
        toolchainEnvironment: ToolchainEnvironment?,
        fileSystem: some FileSystem
    ) {
        self.descriptionPackage = descriptionPackage
        self.outputDir = outputDir
        self.buildConfiguration = buildConfiguration
        self.toolchainEnvironment = toolchainEnvironment
        self.fileSystem = fileSystem
    }

    func createMacroExecutable(
        _ target: CacheSystem.CacheTarget,
        overwrite: Bool
    ) async throws -> PluginExecutable {
        let compiler = PIFCompiler(
            descriptionPackage: descriptionPackage,
            buildOptions: BuildOptions(
                buildConfiguration: buildConfiguration,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                sdks: [.macOS],
                extraFlags: nil,
                extraBuildParameters: nil,
                enableLibraryEvolution: false,
                keepPublicHeadersStructure: false,
                customFrameworkModuleMapContents: nil,
                stripStaticDWARFSymbols: false
            ),
            buildOptionsMatrix: [:],
            toolchainEnvironment: toolchainEnvironment
        )

        logger.info("📦 Building macro target \(target.buildProduct.target.name)")

        let executablePath = try await compiler.createMacroExecutable(
            buildProduct: target.buildProduct,
            outputDirectory: outputDir,
            overwrite: overwrite
        )

        logger.info("⚙️ Please pass \(executablePath) to -load-plugin-executable in any module that uses this macro")

        return PluginExecutable(
            executablePath: executablePath,
            targetName: target.buildProduct.target.name
        )
    }
}

struct PluginExecutable: Hashable {
    let executablePath: TSCAbsolutePath
    let targetName: String

    var compilerOption: String {
        executablePath.pathString + "#" + targetName
    }
}

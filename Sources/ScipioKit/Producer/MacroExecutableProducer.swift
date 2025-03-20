import Foundation
import Basics
import TSCBasic

public struct MacroExecutableProducer {
    private let packageLocator: any PackageLocator
    private let executor: any Executor

    init(
        packageLocator: some PackageLocator,
        executor: some Executor = ProcessExecutor()
    ) {
        self.packageLocator = packageLocator
        self.executor = executor
    }

    func processAllTargets(buildProducts: Set<BuildProduct>) async throws -> Set<PluginExecutable> {
        var pluginExecutables = Set<PluginExecutable>()
        for buildProduct in buildProducts {
            logger.info("📦 Building macro target \(buildProduct.target.name)")
            let pluginExecutable = try await createMacroExecutable(buildProduct: buildProduct)

            pluginExecutables.insert(pluginExecutable)
        }
        return pluginExecutables
    }

    private func createMacroExecutable(
        buildProduct: BuildProduct
    ) async throws -> PluginExecutable {
        assert(buildProduct.target.type == .macro)

        try await executor.execute([
            "/usr/bin/xcrun",
            "swift",
            "build",
            "--package-path",
            buildProduct.package.path.pathString,
            "--build-path",
            packageLocator.workspaceDirectory.appending(component: "macro-build").pathString,
            "-c",
            "release",
            "--product",
            buildProduct.target.name
        ])

        let binPathString = try await executor.execute([
            "/usr/bin/xcrun",
            "swift",
            "build",
            "--package-path",
            buildProduct.package.path.pathString,
            "--build-path",
            packageLocator.workspaceDirectory.appending(component: "macro-build").pathString,
            "-c",
            "release",
            "--show-bin-path"
        ]).unwrapOutput().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")

        return PluginExecutable(binPath: URL(filePath: binPathString), targetName: buildProduct.target.name)
    }
}

struct PluginExecutable: Hashable {
    let binPath: URL
    let targetName: String

    var compilerOption: String {
        binPath.appending(path: "\(targetName)-tool").path(percentEncoded: false) + "#" + targetName
    }
}

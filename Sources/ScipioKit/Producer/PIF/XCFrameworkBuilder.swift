import Foundation
import ScipioKitCore

struct XCFrameworkBuilder {
    private let executor: any Executor

    init(executor: some Executor = ProcessExecutor(errorDecoder: StandardOutputDecoder())) {
        self.executor = executor
    }

    func createXCFramework(
        xcbuildPath: URL,
        frameworkPaths: [SDK: URL],
        debugSymbols: [SDK: [URL]]?,
        outputPath: URL,
        enableLibraryEvolution: Bool
    ) async throws {
        let additionalArguments = buildCreateXCFrameworkArguments(
            frameworkPaths: frameworkPaths,
            debugSymbols: debugSymbols,
            outputPath: outputPath,
            enableLibraryEvolution: enableLibraryEvolution
        )

        let arguments: [String] = [
            xcbuildPath.path(percentEncoded: false),
            "createXCFramework",
        ] + additionalArguments

        try await executor.execute(arguments)
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

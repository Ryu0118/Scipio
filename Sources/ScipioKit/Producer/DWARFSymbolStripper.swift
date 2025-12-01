import Foundation
import ScipioKitCore

/// Strip debug symbols from a binary.
struct DWARFSymbolStripper {
    private let executor: any Executor

    init(executor: some Executor) {
        self.executor = executor
    }

    func stripDebugSymbol(_ binaryPath: URL) async throws {
        try await executor.execute(
            "/usr/bin/xcrun",
            "strip",
            "-S",
            binaryPath.path(percentEncoded: false)
        )
    }

    /// Strip debug symbols from framework if needed based on build options
    func stripSymbolsIfNeeded(
        from frameworkPath: URL,
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        sdk: SDK
    ) async throws {
        guard buildOptions.stripStaticDWARFSymbols && buildOptions.frameworkType == .static else {
            return
        }

        logger.debug("🐛 Stripping debug symbols of \(buildProduct.target.name) (\(sdk.displayName))")
        let binaryPath = frameworkPath.appending(component: buildProduct.target.c99name)
        try await stripDebugSymbol(binaryPath)
    }

    /// Strip debug symbols from multiple frameworks
    func stripSymbolsIfNeeded(
        from frameworkPaths: [BuildProduct: URL],
        buildOptions: BuildOptions,
        sdk: SDK
    ) async throws {
        guard buildOptions.stripStaticDWARFSymbols && buildOptions.frameworkType == .static else {
            return
        }

        for (buildProduct, frameworkPath) in frameworkPaths {
            logger.debug("🐛 Stripping debug symbols of \(buildProduct.target.name) (\(sdk.displayName))")
            let binaryPath = frameworkPath.appending(component: buildProduct.target.c99name)
            try await stripDebugSymbol(binaryPath)
        }
    }
}

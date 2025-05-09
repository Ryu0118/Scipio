import Foundation
import PackageManifestKit
import OrderedCollections
import AsyncOperations
import Basics
import os

actor PackageResolver {
    private let dependencyPackagesByID: [DependencyPackage.ID: DependencyPackage]
    private let dependencyPackagesByName: [String: DependencyPackage]
    private let packageDirectory: URL
    private let rootManifest: Manifest
    private let pins: [PackageResolved.Pin.ID: PackageResolved.Pin]
    private let jsonDecoder = JSONDecoder()
    private let manifestLoader: ManifestLoader
    private let fileSystem: any FileSystem

    private var allPackages: [_ResolvedPackage.ID: _ResolvedPackage] = [:]
    private var allModules: Set<_ResolvedModule> = []
    private var cachedModuleType: [Target: ResolvedModuleType] = [:]
    private var cachedManifests: OSAllocatedUnfairLock<[DependencyPackage: Manifest]> = .init(initialState: [:])

    init(
        packageDirectory: URL,
        rootManifest: Manifest,
        fileSystem: some FileSystem,
        executor: some Executor = ProcessExecutor(decoder: StandardOutputDecoder())
    ) async throws {
        let packageResolved = try await PackageResolveExecutor(fileSystem: fileSystem, executor: executor).execute(packageDirectory: packageDirectory)
        let parseResult = try await ShowDependenciesParser(executor: executor).parse(packageDirectory: packageDirectory)

        self.packageDirectory = packageDirectory
        self.pins = Dictionary(uniqueKeysWithValues: packageResolved.pins.map { ($0.id, $0) })
        self.dependencyPackagesByID = parseResult.dependencyPackagesByID
        self.dependencyPackagesByName = parseResult.dependencyPackagesByName
        self.rootManifest = rootManifest
        self.manifestLoader = ManifestLoader(executor: executor)
        self.fileSystem = fileSystem
    }

    func resolve() async throws -> _ModulesGraph {
        let rootPackage = try await resolve(manifest: rootManifest)

        return _ModulesGraph(
            rootPackage: rootPackage,
            allPackages: allPackages,
            allModules: allModules
        )
    }

    private func resolve(manifest: Manifest) async throws -> _ResolvedPackage {
        let dependencyPackage = resolveDependencyPackage(for: manifest)
        let packageID = _ResolvedPackage.ID(packageKind: manifest.packageKind, packageIdentity: dependencyPackage.identity)

        if let resolvedPackage = allPackages[packageID] {
            return resolvedPackage
        } else {
            let resolvedPackage = _ResolvedPackage(
                manifest: manifest,
                packageIdentity: dependencyPackage.identity,
                pinState: pins[dependencyPackage.identity]?.state,
                path: dependencyPackage.path,
                targets: try await manifest.targets.asyncMap {
                    try await self.resolve(
                        target: $0,
                        in: manifest
                    )
                },
                products: try await manifest.products.asyncMap {
                    try await self.resolve(
                        product: $0,
                        in: manifest
                    )
                }
            )
            allPackages[resolvedPackage.id] = resolvedPackage
            return resolvedPackage
        }
    }

    private func resolve(
        byName: String,
        condition: PackageCondition?,
        dependencyPackage: DependencyPackage,
        in manifest: Manifest
    ) async throws -> _ResolvedModule.Dependency? {
        if let target = manifest.targets.first(where: { $0.name == byName }) {
            return try await .module(
                createResolvedModule(for: target, in: manifest, dependencyPackage: dependencyPackage),
                conditions: self.resolve(condition: condition)
            )
        } else {
            let packageName = manifest.dependencies.compactMap { packageDependency in
                switch packageDependency {
                case .fileSystem(let fileSystem):
                    fileSystem.nameForTargetDependencyResolutionOnly
                case .sourceControl(let sourceControl):
                    sourceControl.nameForTargetDependencyResolutionOnly
                case .registry(let registry):
                    registry.identity
                }
            }.first { $0 == byName }

            let resolvedProduct = try await self.resolve(
                productName: byName,
                packageName: packageName,
                in: manifest
            )

            guard let resolvedProduct else {
                return nil
            }

            return try await .product(resolvedProduct, conditions: self.resolve(condition: condition))
        }
    }

    private func resolve(
        dependencies: [PackageManifestKit.Target.Dependency],
        in manifest: Manifest
    ) async throws -> [_ResolvedModule.Dependency] {
        let dependencyPackage = resolveDependencyPackage(for: manifest)

        return try await dependencies.asyncCompactMap { dependency -> _ResolvedModule.Dependency? in
            switch dependency {
            case .target(let name, let condition):
                guard let target = manifest.targets.first(where: { $0.name == name }) else {
                    return nil
                }

                return try await .module(
                    self.createResolvedModule(for: target, in: manifest, dependencyPackage: dependencyPackage),
                    conditions: self.resolve(condition: condition)
                )

            case .byName(let name, let condition):
                return try await self.resolve(
                    byName: name,
                    condition: condition,
                    dependencyPackage: dependencyPackage,
                    in: manifest
                )

            case .product(let name, let package, _, let condition):
                let resolvedProduct = try await self.resolve(
                    productName: name,
                    packageName: package,
                    in: manifest
                )

                guard let resolvedProduct else {
                    return nil
                }

                return try await .product(resolvedProduct, conditions: self.resolve(condition: condition))
            }
        }
    }

    private func resolve(
        productName: String,
        packageName: String?,
        in manifest: Manifest
    ) async throws -> _ResolvedProduct? {
        let packageName = packageName ?? productName
        // packageName can be different between `show-dependencies` and `dump-package`, so we try all possible cases
        let dependencyPackage: DependencyPackage? =
            if let dependencyPackage = dependencyPackagesByName[packageName] {
                dependencyPackage
            } else if let dependencyPackage = dependencyPackagesByID[packageName] {
                dependencyPackage
            } else if let dependencyPackage = dependencyPackagesByID[packageName.lowercased()] {
                dependencyPackage
            } else if let dependencyPackage = dependencyPackagesByName[productName] {
                dependencyPackage
            } else {
                nil
            }

        guard let dependencyPackage else {
            return nil
        }

        let manifest = try await {
            if let cachedManifest = await self.cachedManifests.withLock { $0[dependencyPackage] } {
                return cachedManifest
            } else {
                let manifest = try await self.manifestLoader.loadManifest(for: dependencyPackage)
                await self.cachedManifests.withLock {
                    $0[dependencyPackage] = manifest
                }
                return manifest
            }
        }()

        let resolvedPackage = try await self.resolve(manifest: manifest)

        guard let resolvedProduct = resolvedPackage.products.first(where: { $0.name == productName }) else {
            return nil
        }

        return resolvedProduct
    }

    private func resolve(
        product: Product,
        in manifest: PackageManifestKit.Manifest
    ) async throws -> _ResolvedProduct {
        let packageIdentity = resolveDependencyPackage(for: manifest).identity

        return _ResolvedProduct(
            underlying: product,
            modules: try await product.targets
                .compactMap { targetName in manifest.targets.first(where: { $0.name == targetName }) }
                .asyncMap { try await self.resolve(target: $0, in: manifest) },
            type: product.type,
            packageID: _ResolvedPackage.ID(packageKind: manifest.packageKind, packageIdentity: packageIdentity)
        )
    }

    private func resolve(
        target: Target,
        in manifest: PackageManifestKit.Manifest
    ) async throws -> _ResolvedModule {
        let dependencyPackage = resolveDependencyPackage(for: manifest)

        return try await createResolvedModule(
            for: target,
            in: manifest,
            dependencyPackage: dependencyPackage
        )
    }

    private func resolve(
        condition: PackageCondition?
    ) -> [PackageCondition] {
        if let condition {
            [condition]
        } else {
            []
        }
    }

    private func resolveModuleType(
        of target: Target,
        dependencyPackage: DependencyPackage
    ) -> ResolvedModuleType {
        if let cachedModuleType = cachedModuleType[target] {
            return cachedModuleType
        }

        let resolvedModuleType = ModuleTypeResolver(
            target: target,
            dependencyPackage: dependencyPackage
        ).resolve()

        cachedModuleType[target] = resolvedModuleType

        return resolvedModuleType
    }

    private func createResolvedModule(
        for target: Target,
        in manifest: Manifest,
        dependencyPackage: DependencyPackage
    ) async throws -> _ResolvedModule {
        let module = try await _ResolvedModule(
            underlying: target,
            dependencies: resolve(dependencies: target.dependencies, in: manifest),
            localPackageURL: manifest.packageKind.localFileURL!,
            packageID: _ResolvedPackage.ID(packageKind: manifest.packageKind, packageIdentity: dependencyPackage.identity),
            resolvedModuleType: resolveModuleType(of: target, dependencyPackage: dependencyPackage)
        )
        allModules.insert(module)
        return module
    }

    private func resolveDependencyPackage(for manifest: Manifest) -> DependencyPackage {
        guard let dependencyPackage = dependencyPackagesByName[manifest.name] else {
            fatalError("Manifest \(manifest.name) refers to unknown package")
        }
        return dependencyPackage
    }
}

private struct ModuleTypeResolver {
    let target: Target
    let dependencyPackage: DependencyPackage

    let clangFileTypes = ["c", "m", "mm", "cc", "cpp", "cxx"]
    let asmFileTypes = ["s", "S"]
    let swiftFileType = "swift"

    func resolve() -> ResolvedModuleType {
        switch target.type {
        case .binary:
            resolveModuleTypeForBinary()
        default:
            resolveModuleTypeForLibrary()
        }
    }

    private func resolveModuleTypeForBinary() -> ResolvedModuleType {
        precondition(target.type == .binary)

        let artifactType: ResolvedModuleType.BinaryArtifactLocation =
        if target.url != nil {
            .remote(packageIdentity: dependencyPackage.identity, name: target.name)
        }
        else {
            .local(resolveTargetFullPath(target: target))
        }
        return .binary(artifactType)
    }

    private func resolveModuleTypeForLibrary() -> ResolvedModuleType {
        precondition(target.type != .binary)

        let moduleFullPath = resolveTargetFullPath(target: target)
        let moduleSourcesFullPaths = target.sources?.map { moduleFullPath.appending(component: $0) } ?? [moduleFullPath]
        let moduleExcludeFullPaths = target.exclude.map { moduleFullPath.appending(component: $0) }
        let publicHeadersPath = target.publicHeadersPath ?? "include"
        let includeDir = moduleFullPath.appendingPathComponent(publicHeadersPath)

        let sources: [URL] = moduleSourcesFullPaths.flatMap { source in
            FileManager.default
                .enumerator(at: source, includingPropertiesForKeys: nil)?
                .lazy
                .compactMap { $0 as? URL }
                .filter { url in
                    moduleExcludeFullPaths.allSatisfy { !url.path.hasPrefix($0.path) }
                } ?? []
        }

        let hasSwiftSources = sources.contains { $0.pathExtension == swiftFileType } ?? false
        let hasClangSources = sources.contains { (clangFileTypes + asmFileTypes).contains($0.pathExtension) }

        // In SwiftPM, the module type (ClangModule or SwiftModule) is determined by checking the file extensions inside the module.
        return if hasSwiftSources && hasClangSources {
            // TODO: Update when SwiftPM supports mixed-language targets.
            // Currently SwiftPM cannot mix Swift and C/Assembly in one target.
            // ref: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0403-swiftpm-mixed-language-targets.md
            fatalError("Mixed-language target are not supported.")
        } else if hasSwiftSources {
            .swift
        } else {
            .clang(includeDir: includeDir)
        }
    }

    private func resolveTargetFullPath(target: Target) -> URL {
        let packagePath = dependencyPackage.path
        // In SwiftPM, if target does not specify a path,
        // it is assumed to be located at 'Sources/<target name>' by default.
        let relativePath = target.path ?? "Sources/\(target.name)"
        return URL(fileURLWithPath: packagePath).appending(component: relativePath)
    }
}

private struct ManifestLoader: @unchecked Sendable {
    private let executor: any Executor
    private let jsonDecoder = JSONDecoder()

    init(executor: some Executor) {
        self.executor = executor
    }

    func loadManifest(for dependency: DependencyPackage) async throws -> Manifest {
        let commands = [
            "/usr/bin/xcrun",
            "swift",
            "package",
            "dump-package",
            "--package-path",
            dependency.path
        ]
        let manifestString = try await executor.execute(commands).unwrapOutput()
        let manifest = try jsonDecoder.decode(Manifest.self, from: manifestString)
        return manifest
    }
}

private struct PackageResolveExecutor: @unchecked Sendable {
    private let executor: any Executor
    private let fileSystem: any FileSystem
    private let jsonDecoder = JSONDecoder()

    init(fileSystem: some FileSystem, executor: some Executor) {
        self.fileSystem = fileSystem
        self.executor = executor
    }

    func execute(packageDirectory: URL) async throws -> PackageResolved {
        let commands = [
            "/usr/bin/xcrun",
            "swift",
            "package",
            "resolve",
            "--package-path",
            packageDirectory.path(percentEncoded: false)
        ]

        try await executor.execute(commands)

        guard let packageResolvedString = try fileSystem.readFileContents(packageDirectory.appending(component: "Package.resolved").spmAbsolutePath).validDescription else {
            throw Error.cannotReadPackageResolved
        }

        let packageResolved = try jsonDecoder.decode(PackageResolved.self, from: packageResolvedString)

        return packageResolved
    }

    enum Error: Swift.Error {
        case cannotReadPackageResolved
    }
}

private struct ShowDependenciesParser: @unchecked Sendable {
    private struct Response: Decodable {
        var identity: String
        var name: String
        var url: String
        var version: String
        var path: String
        var dependencies: [Response]?
    }

    struct ParseResult {
        var dependencyPackagesByID: [DependencyPackage.ID: DependencyPackage]
        var dependencyPackagesByName: [String: DependencyPackage]
    }

    let executor: any Executor
    let jsonDecoder = JSONDecoder()

    init(executor: some Executor) {
        self.executor = executor
    }

    func parse(packageDirectory: URL) async throws -> ParseResult {
        let commands = [
            "/usr/bin/xcrun",
            "swift",
            "package",
            "show-dependencies",
            "--package-path",
            packageDirectory.path,
            "--format",
            "json"
        ]

        let dependencyString = try await executor.execute(commands).unwrapOutput()
        let dependency = try jsonDecoder.decode(Response.self, from: dependencyString)
        return flattenPackages(dependency)
    }

    private func flattenPackages(_ package: Response) -> ParseResult {
        var dependencyPackagesByID: [DependencyPackage.ID: DependencyPackage] = [:]
        var dependencyPackagesByName: [String: DependencyPackage] = [:]

        func traverse(_ package: Response) {
            let info = DependencyPackage(
                identity: package.identity,
                name: package.name,
                url: package.url,
                version: package.version,
                path: package.path
            )
            dependencyPackagesByID[info.id] = info
            dependencyPackagesByName[info.name] = info
            package.dependencies?.forEach { traverse($0) }
        }

        traverse(package)

        return ParseResult(
            dependencyPackagesByID: dependencyPackagesByID,
            dependencyPackagesByName: dependencyPackagesByName
        )
    }
}

private struct DependencyPackage: Codable, Identifiable, Hashable {
    var id: String {
        identity
    }

    var identity: String
    var name: String
    var url: String
    var version: String
    var path: String
}

fileprivate extension PackageKind {
    var localFileURL: URL? {
        switch self {
        case .root(let url), .fileSystem(let url), .localSourceControl(let url):
            url
        default: nil
        }
    }
}

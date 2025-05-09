import Foundation
import PackageManifestKit
import OrderedCollections
import AsyncOperations
import Basics
import os

actor PackageResolver {
    private let dependencyPackagesByID: [DependencyPackageInfo.ID: DependencyPackageInfo]
    private let dependencyPackagesByName: [String: DependencyPackageInfo]
    private let packageDirectory: URL
    private let rootManifest: Manifest
    private let pins: [PackageResolved.Pin.ID: PackageResolved.Pin]
    private let jsonDecoder = JSONDecoder()
    private let manifestLoader: ManifestLoader
    private let fileSystem: any FileSystem

    private var allPackages: [_ResolvedPackage.ID: _ResolvedPackage] = [:]
    private var allModules: Set<_ResolvedModule> = []

    private var cachedManifests: OSAllocatedUnfairLock<[DependencyPackageInfo: Manifest]> = .init(initialState: [:])

    init(
        packageDirectory: URL,
        rootManifest: Manifest,
        fileSystem: some FileSystem,
        executor: some Executor = ProcessExecutor(decoder: StandardOutputDecoder())
    ) async throws {
        let packageResolved = try await PackageResolveExecutor(fileSystem: fileSystem, executor: executor).execute(packageDirectory: packageDirectory)
        let parseResult = try await ShowDependenciesParser(executor: executor).parse(packageDirectory: packageDirectory)

        self.packageDirectory = packageDirectory
        self.pins = packageResolved.pinsByID
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
        guard let dependencyPackage = dependencyPackagesByName[manifest.name] else {
            fatalError()
        }

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
        dependencyPackage: DependencyPackageInfo,
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
        guard let dependencyPackage = dependencyPackagesByName[manifest.name] else {
            fatalError()
        }

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
        // show-dependenciesとdump-packageでpackageNameが異なるため、全てのパターンを試している
        let dependencyPackage: DependencyPackageInfo? =
            if let dependencyPackage = self.dependencyPackagesByName[packageName] {
                dependencyPackage
            } else if let dependencyPackage = self.dependencyPackagesByID[packageName] {
                dependencyPackage
            } else if let dependencyPackage = self.dependencyPackagesByID[packageName.lowercased()] {
                dependencyPackage
            } else if let dependencyPackage = self.dependencyPackagesByName[productName] {
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
        guard let packageIdentity = dependencyPackagesByName[manifest.name]?.identity else {
            fatalError()
        }

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
        guard let dependencyPackage = dependencyPackagesByName[manifest.name] else {
            fatalError()
        }

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

    func resolveModuleType(
        of target: Target,
        dependencyPackage: DependencyPackageInfo
    ) -> ResolvedModuleType {
        func resolveTargetFullPath(target: Target) -> URL {
            let packagePath = dependencyPackage.path
            let relativePath = target.path ?? "Sources/\(target.name)"
            return URL(fileURLWithPath: packagePath).appending(component: relativePath)
        }

        switch target.type {
        case .binary:
            let artifactType: ResolvedModuleType.BinaryArtifactLocation =
                if target.url != nil {
                    .remote(packageIdentity: dependencyPackage.identity, name: target.name)
                }
                else {
                    .local(resolveTargetFullPath(target: target))
                }
            return .binary(artifactType)
        default:
            let moduleFullPath = resolveTargetFullPath(target: target)
            let moduleExcludeFullPath = target.exclude.map { moduleFullPath.appending(component: $0) }
            let publicHeadersPath = target.publicHeadersPath ?? "include"
            let includeDir = moduleFullPath.appendingPathComponent(publicHeadersPath)
            let hasSwiftSources = hasSwiftSources(in: moduleFullPath, excludeFullPaths: moduleExcludeFullPath)

            return if hasSwiftSources {
                .swift
            } else {
                .clang(includeDir: includeDir)
            }
        }
    }

    func createResolvedModule(
        for target: Target,
        in manifest: Manifest,
        dependencyPackage: DependencyPackageInfo
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

    private func hasSwiftSources(in moduleFullPath: URL, excludeFullPaths: [URL]) -> Bool {
        FileManager.default
            .enumerator(at: moduleFullPath, includingPropertiesForKeys: nil)?
            .lazy
            .compactMap { $0 as? URL }
            .filter { url in
                excludeFullPaths.allSatisfy { !url.path.hasPrefix($0.path) }
            }
            .contains { $0.pathExtension == "swift" } ?? false
    }
}

func topologicalSort<T: Identifiable>(
    _ nodes: [T], successors: (T) throws -> [T]
) throws -> [T] {
    // Implements a topological sort via recursion and reverse postorder DFS.
    func visit(_ node: T,
               _ stack: inout OrderedSet<T.ID>, _ visited: inout Set<T.ID>, _ result: inout [T],
               _ successors: (T) throws -> [T]) throws {
        // Mark this node as visited -- we are done if it already was.
        if !visited.insert(node.id).inserted {
            return
        }

        // Otherwise, visit each adjacent node.
        for succ in try successors(node) {
            guard stack.append(succ.id).inserted else {
                // If the successor is already in this current stack, we have found a cycle.
                //
                // FIXME: We could easily include information on the cycle we found here.
                throw GraphError.unexpectedCycle
            }
            try visit(succ, &stack, &visited, &result, successors)
            let popped = stack.removeLast()
            assert(popped == succ.id)
        }

        // Add to the result.
        result.append(node)
    }

    // FIXME: This should use a stack not recursion.
    var visited = Set<T.ID>()
    var result = [T]()
    var stack = OrderedSet<T.ID>()
    for node in nodes {
        precondition(stack.isEmpty)
        stack.append(node.id)
        try visit(node, &stack, &visited, &result, successors)
        let popped = stack.removeLast()
        assert(popped == node.id)
    }

    return result.reversed()
}

enum GraphError: Error {
    /// A cycle was detected in the input.
    case unexpectedCycle
}

private struct ManifestLoader: @unchecked Sendable {
    private let executor: any Executor
    private let jsonDecoder = JSONDecoder()

    init(executor: some Executor) {
        self.executor = executor
    }

    func loadManifest(for dependency: DependencyPackageInfo) async throws -> Manifest {
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
            packageDirectory.path()
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
    struct ParseResult {
        var dependencyPackagesByID: [DependencyPackageInfo.ID: DependencyPackageInfo]
        var dependencyPackagesByName: [String: DependencyPackageInfo]
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
        let dependency = try jsonDecoder.decode(DependencyPackage.self, from: dependencyString)
        return flattenPackages(dependency)
    }

    private func flattenPackages(_ package: DependencyPackage) -> ParseResult {
        var dependencyPackagesByID: [DependencyPackageInfo.ID: DependencyPackageInfo] = [:]
        var dependencyPackagesByName: [String: DependencyPackageInfo] = [:]

        func traverse(_ package: DependencyPackage) {
            let info = DependencyPackageInfo(
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

private struct DependencyPackage: Decodable {
    var identity: String
    var name: String
    var url: String
    var version: String
    var path: String
    var dependencies: [DependencyPackage]?
}

struct DependencyPackageInfo: Codable, Identifiable, Hashable {
    var id: String {
        identity
    }

    var identity: String
    var name: String
    var url: String
    var version: String
    var path: String
}

struct PackageResolved: Decodable {
    let pins: [Pin]
    let version: Int

    struct Pin: Decodable, Identifiable, Hashable {
        var id: String {
            identity
        }

        let identity: String
        let kind: String
        let location: String
        let state: State

        struct State: Decodable, Hashable {
            let revision: String
            let version: String?
            let branch: String?
        }
    }
}

extension PackageResolved {
    var pinsByID: [Pin.ID: Pin] {
        Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0) })
    }
}

extension PackageKind {
    var localFileURL: URL? {
        switch self {
        case .root(let url), .fileSystem(let url), .localSourceControl(let url):
            url
        default: nil
        }
    }
}

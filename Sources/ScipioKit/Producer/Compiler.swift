import Foundation
import Collections
import PIFKit
import ScipioKitCore

protocol Compiler {
    var descriptionPackage: DescriptionPackage { get }

    func createXCFramework(buildProduct: BuildProduct,
                           outputDirectory: URL,
                           overwrite: Bool) async throws
}

enum TargetBuildResult {
    case interrupted(builtTargets: Set<CacheSystem.CacheTarget>, error: any Error)
    case completed(builtTargets: Set<CacheSystem.CacheTarget>)

    var builtTargets: Set<CacheSystem.CacheTarget> {
        switch self {
        case .completed(let targets), .interrupted(let targets, _):
            return targets
        }
    }

    var orderedBuiltTargets: OrderedCollections.OrderedSet<CacheSystem.CacheTarget> {
        OrderedCollections.OrderedSet(builtTargets)
    }

    func merge(with other: TargetBuildResult) -> TargetBuildResult {
        let allBuiltTargets = builtTargets.union(other.builtTargets)

        // If either has an error, return interrupted with the first error encountered
        if case .interrupted(_, let error) = self {
            return .interrupted(builtTargets: allBuiltTargets, error: error)
        }
        if case .interrupted(_, let error) = other {
            return .interrupted(builtTargets: allBuiltTargets, error: error)
        }

        return .completed(builtTargets: allBuiltTargets)
    }
}

protocol ParallelCompiler {
    var descriptionPackage: DescriptionPackage { get }

    func createXCFrameworks(
        parallelBuildGroups: Set<ParallelBuildGroup>,
        outputDirectory: URL,
        overwrite: Bool
    ) async -> TargetBuildResult
}

extension ParallelCompiler {
    func extractDebugSymbolPaths(
        target: ResolvedModule,
        buildConfiguration: BuildConfiguration,
        sdks: Set<SDK>,
        fileSystem: some FileSystem = LocalFileSystem.default
    ) async throws -> [SDK: [URL]] {
        let extractor = DwarfExtractor()

        var result = [SDK: [URL]]()

        for sdk in sdks {
            let dsymPath = descriptionPackage.buildDebugSymbolPath(
                buildConfiguration: buildConfiguration,
                sdk: sdk,
                target: target
            )
            guard fileSystem.exists(dsymPath) else { continue }

            let dwarfPath = extractor.dwarfPath(for: target, dSYMPath: dsymPath)
            let dumpedDSYMsMaps = try await extractor.dump(dwarfPath: dwarfPath)
            let bcSymbolMapPaths: [URL] = dumpedDSYMsMaps.values.compactMap { [descriptionPackage] uuid in
                let path = descriptionPackage.productsDirectory(
                    buildConfiguration: buildConfiguration,
                    sdk: sdk
                )
                    .appending(component: "\(uuid.uuidString).bcsymbolmap")
                guard fileSystem.exists(path) else { return nil }
                return path
            }
            result[sdk] = [dsymPath] + bcSymbolMapPaths
        }
        return result
    }
}

extension Compiler {
    func extractDebugSymbolPaths(
        target: ResolvedModule,
        buildConfiguration: BuildConfiguration,
        sdks: Set<SDK>,
        fileSystem: some FileSystem = LocalFileSystem.default
    ) async throws -> [SDK: [URL]] {
        let extractor = DwarfExtractor()

        var result = [SDK: [URL]]()

        for sdk in sdks {
            let dsymPath = descriptionPackage.buildDebugSymbolPath(
                buildConfiguration: buildConfiguration,
                sdk: sdk,
                target: target
            )
            guard fileSystem.exists(dsymPath) else { continue }

            let dwarfPath = extractor.dwarfPath(for: target, dSYMPath: dsymPath)
            let dumpedDSYMsMaps = try await extractor.dump(dwarfPath: dwarfPath)
            let bcSymbolMapPaths: [URL] = dumpedDSYMsMaps.values.compactMap { [descriptionPackage] uuid in
                let path = descriptionPackage.productsDirectory(
                    buildConfiguration: buildConfiguration,
                    sdk: sdk
                )
                    .appending(component: "\(uuid.uuidString).bcsymbolmap")
                guard fileSystem.exists(path) else { return nil }
                return path
            }
            result[sdk] = [dsymPath] + bcSymbolMapPaths
        }
        return result
    }
}

extension DescriptionPackage {
    fileprivate func buildDebugSymbolPath(
        buildConfiguration: BuildConfiguration,
        sdk: SDK,
        target: ResolvedModule
    ) -> URL {
        productsDirectory(buildConfiguration: buildConfiguration, sdk: sdk)
            .appending(component: "\(target.name).framework.dSYM")
    }
}

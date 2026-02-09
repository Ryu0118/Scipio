import Foundation
import Collections
import PIFKit
import ScipioKitCore

protocol Compiler {
    var descriptionPackage: DescriptionPackage { get }

    func createXCFramework(buildProduct: BuildProduct,
                           buildOptions: BuildOptions,
                           outputDirectory: URL,
                           overwrite: Bool) async throws

    func createXCFrameworks(
        parallelBuildGroups: Set<ParallelBuildGroup>,
        outputDirectory: URL,
        overwrite: Bool
    ) async -> TargetBuildResult
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

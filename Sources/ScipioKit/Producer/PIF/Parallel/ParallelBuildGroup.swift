import Foundation

struct ParallelBuildGroup: Hashable {
    let buildTargetsBySDK: [SDK: Set<BuildProduct>]
    let buildOptions: BuildOptions

    func allTargets() -> Set<BuildProduct> {
        buildTargetsBySDK.values.reduce(into: Set<BuildProduct>()) { partialResult, targets in
            partialResult.formUnion(targets)
        }
    }
}

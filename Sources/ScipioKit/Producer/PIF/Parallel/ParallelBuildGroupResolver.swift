import Foundation

actor ParallelBuildGroupResolver {
    /// Groups cache targets into ``ParallelBuildGroup``s for parallel building.
    ///
    /// Targets with the same ``BuildOptions`` can be built together in a single xcbuild/swbuild invocation.
    /// This method groups targets by their ``BuildOptions``, then further organizes them by SDK
    /// so that each group can be dispatched to xcbuild/swbuild per SDK.
    func resolve(_ cacheTargets: Set<CacheSystem.CacheTarget>) -> Set<ParallelBuildGroup> {
        let targetsByBuildOptions = cacheTargets.reduce(
            into: [BuildOptions: Set<CacheSystem.CacheTarget>]()
        ) { dict, target in
            dict[target.buildOptions, default: []].insert(target)
        }

        return targetsByBuildOptions.reduce(into: Set<ParallelBuildGroup>()) { buildGroups, targetsByBuildOptions in
            let (buildOptions, targets) = targetsByBuildOptions
            let buildTargets = targets.reduce(into: [SDK: Set<BuildProduct>]()) { dict, target in
                for sdk in target.buildOptions.sdks {
                    dict[sdk, default: []].insert(target.buildProduct)
                }
            }
            buildGroups.insert(
                ParallelBuildGroup(
                    buildTargetsBySDK: buildTargets,
                    buildOptions: buildOptions
                )
            )
        }
    }
}

import Foundation

actor ParallelBuildGroupResolver {
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

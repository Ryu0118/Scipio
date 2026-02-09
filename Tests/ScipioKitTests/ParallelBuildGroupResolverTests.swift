import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit
@testable import ScipioKitCore

struct ParallelBuildGroupResolverTests {
    @Test("resolve groups cache targets by build options", arguments: TestCase.allCases)
    func resolve(testCase: TestCase) async {
        let resolver = ParallelBuildGroupResolver()
        let groups = await resolver.resolve(testCase.cacheTargets)

        #expect(groups.count == testCase.expectedTargetNamesByGroup.count)

        let actualTargetNamesByGroup = groups.map { group in
            Set(group.allTargets().map(\.target.name))
        }

        for expectedNames in testCase.expectedTargetNamesByGroup {
            #expect(
                actualTargetNamesByGroup.contains(expectedNames),
                "Expected group with targets \(expectedNames.sorted()) not found in \(actualTargetNamesByGroup)"
            )
        }
    }

    struct TestCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let cacheTargets: Set<CacheSystem.CacheTarget>
        let expectedTargetNamesByGroup: [Set<String>]

        var description: String { testDescription }

        static let allCases: [TestCase] = {
            let iOSStaticOptions = makeStubBuildOptions(frameworkType: .static, sdks: [.iOS])
            let iOSDynamicOptions = makeStubBuildOptions(frameworkType: .dynamic, sdks: [.iOS])
            let multiSDKOptions = makeStubBuildOptions(frameworkType: .static, sdks: [.iOS, .macOS])
            let debugOptions = makeStubBuildOptions(
                frameworkType: .static,
                sdks: [.iOS],
                buildConfiguration: .debug
            )

            return [
                TestCase(
                    testDescription: "empty input returns empty groups",
                    cacheTargets: [],
                    expectedTargetNamesByGroup: []
                ),
                TestCase(
                    testDescription: "single target produces single group",
                    cacheTargets: [
                        makeStubCacheTarget(targetName: "A", buildOptions: iOSStaticOptions),
                    ],
                    expectedTargetNamesByGroup: [["A"]]
                ),
                TestCase(
                    testDescription: "targets with same build options are grouped together",
                    cacheTargets: [
                        makeStubCacheTarget(targetName: "A", buildOptions: iOSStaticOptions),
                        makeStubCacheTarget(targetName: "B", buildOptions: iOSStaticOptions),
                        makeStubCacheTarget(targetName: "C", buildOptions: iOSStaticOptions),
                    ],
                    expectedTargetNamesByGroup: [["A", "B", "C"]]
                ),
                TestCase(
                    testDescription: "targets with different framework types produce separate groups",
                    cacheTargets: [
                        makeStubCacheTarget(targetName: "A", buildOptions: iOSStaticOptions),
                        makeStubCacheTarget(targetName: "B", buildOptions: iOSDynamicOptions),
                    ],
                    expectedTargetNamesByGroup: [["A"], ["B"]]
                ),
                TestCase(
                    testDescription: "targets with different build configurations produce separate groups",
                    cacheTargets: [
                        makeStubCacheTarget(targetName: "A", buildOptions: iOSStaticOptions),
                        makeStubCacheTarget(targetName: "B", buildOptions: debugOptions),
                    ],
                    expectedTargetNamesByGroup: [["A"], ["B"]]
                ),
                TestCase(
                    testDescription: "multi SDK targets are organized by SDK within group",
                    cacheTargets: [
                        makeStubCacheTarget(targetName: "A", buildOptions: multiSDKOptions),
                        makeStubCacheTarget(targetName: "B", buildOptions: multiSDKOptions),
                    ],
                    expectedTargetNamesByGroup: [["A", "B"]]
                ),
                TestCase(
                    testDescription: "mixed build options produce correct grouping",
                    cacheTargets: [
                        makeStubCacheTarget(targetName: "A", buildOptions: iOSStaticOptions),
                        makeStubCacheTarget(targetName: "B", buildOptions: iOSStaticOptions),
                        makeStubCacheTarget(targetName: "C", buildOptions: iOSDynamicOptions),
                        makeStubCacheTarget(targetName: "D", buildOptions: multiSDKOptions),
                    ],
                    expectedTargetNamesByGroup: [["A", "B"], ["C"], ["D"]]
                ),
            ]
        }()
    }
}

import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit
@testable import ScipioKitCore

struct ParallelBuildGroupTests {
    @Test("removingTargets removes specified targets from all SDKs", arguments: TestCase.allCases)
    func removingTargets(testCase: TestCase) throws {
        let result = testCase.group.removingTargets(named: testCase.targetNamesToRemove)

        guard let expectedTargetNames = testCase.expectedRemainingTargetNames else {
            #expect(result == nil)
            return
        }

        let remaining = try #require(result)
        let actualNames = Set(remaining.allTargets().map(\.target.name))

        #expect(actualNames == expectedTargetNames)
        #expect(remaining.buildOptions == testCase.group.buildOptions)
    }

    struct TestCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let group: ParallelBuildGroup
        let targetNamesToRemove: Set<String>
        let expectedRemainingTargetNames: Set<String>?

        var description: String { testDescription }

        static let allCases: [TestCase] = {
            let options = makeStubBuildOptions()
            let multiSDKOptions = makeStubBuildOptions(sdks: [.iOS, .macOS])

            let groupABC = ParallelBuildGroup(
                buildTargetsBySDK: [
                    .iOS: [makeStubBuildProduct(targetName: "A"), makeStubBuildProduct(targetName: "B"), makeStubBuildProduct(targetName: "C")],
                ],
                buildOptions: options
            )

            let multiSDKGroup = ParallelBuildGroup(
                buildTargetsBySDK: [
                    .iOS: [makeStubBuildProduct(targetName: "A"), makeStubBuildProduct(targetName: "B")],
                    .macOS: [makeStubBuildProduct(targetName: "A"), makeStubBuildProduct(targetName: "B")],
                ],
                buildOptions: multiSDKOptions
            )

            return [
                TestCase(
                    testDescription: "removing one target leaves the rest",
                    group: groupABC,
                    targetNamesToRemove: ["A"],
                    expectedRemainingTargetNames: ["B", "C"]
                ),
                TestCase(
                    testDescription: "removing all targets returns nil",
                    group: groupABC,
                    targetNamesToRemove: ["A", "B", "C"],
                    expectedRemainingTargetNames: nil
                ),
                TestCase(
                    testDescription: "removing nonexistent target returns original",
                    group: groupABC,
                    targetNamesToRemove: ["Z"],
                    expectedRemainingTargetNames: ["A", "B", "C"]
                ),
                TestCase(
                    testDescription: "removing target from multi SDK group removes from all SDKs",
                    group: multiSDKGroup,
                    targetNamesToRemove: ["A"],
                    expectedRemainingTargetNames: ["B"]
                ),
                TestCase(
                    testDescription: "removing empty set returns original",
                    group: groupABC,
                    targetNamesToRemove: [],
                    expectedRemainingTargetNames: ["A", "B", "C"]
                ),
            ]
        }()
    }
}

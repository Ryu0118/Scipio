import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit

private let fixturePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

@Suite(.serialized)
struct PartialCacheTests {
    private let fileManager: FileManager = .default
    private let tempDir: URL
    private let frameworkOutputDir: URL

    init() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        frameworkOutputDir = tempDir.appendingPathComponent("XCFrameworks")
        try fileManager.createDirectory(at: frameworkOutputDir, withIntermediateDirectories: true)
    }

    @Test
    func dependencyRelationship() async throws {
        let testingPackagePath = fixturePath.appendingPathComponent("PartialCacheTestPackage")

        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: false),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        do {
            try await runner.run(
                packageDirectory: testingPackagePath,
                frameworkOutputDir: .custom(frameworkOutputDir)
            )
            Issue.record("The runner must raise an error.")
        } catch {
            guard case let .compilerError(details) = error as? Runner.Error,
                  let xcBuildError = details as? XCBuildError else {
                Issue.record("Unexpected error occurred.")
                return
            }
            #expect(xcBuildError.failedTargetNames.contains("Bad"))

            let baseLibraryPath = frameworkOutputDir.appendingPathComponent("Base.xcframework")
            #expect(fileManager.fileExists(atPath: baseLibraryPath.path))

            let goodLibraryPath = frameworkOutputDir.appendingPathComponent("Good.xcframework")
            #expect(fileManager.fileExists(atPath: goodLibraryPath.path))

            let badLibraryPath = frameworkOutputDir.appendingPathComponent("Bad.xcframework")
            #expect(!fileManager.fileExists(atPath: badLibraryPath.path))
        }
    }
}

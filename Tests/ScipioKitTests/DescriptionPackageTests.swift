import Foundation
@testable import ScipioKit
import XCTest

private let fixturePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

final class DescriptionPackageTests: XCTestCase {
    func testDescriptionPackage() async throws {
        let rootPath = fixturePath.appendingPathComponent("TestingPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath.absolutePath,
            mode: .prepareDependencies,
            onlyUseVersionsFromResolvedFile: false
        )
        XCTAssertEqual(package.name, "TestingPackage")

        let packageNames = package.graph.packages.map(\.manifest.displayName)
        XCTAssertEqual(packageNames.sorted(), ["TestingPackage", "swift-log"].sorted())

        XCTAssertEqual(
            package.workspaceDirectory.pathString,
            rootPath.appendingPathComponent(".build/scipio").path
        )

        XCTAssertEqual(
            package.derivedDataPath.pathString,
            rootPath.appendingPathComponent(".build/scipio/DerivedData").path
        )
    }

    func testBuildProductsInPrepareMode() async throws {
        let rootPath = fixturePath.appendingPathComponent("IntegrationTestPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath.absolutePath,
            mode: .prepareDependencies,
            onlyUseVersionsFromResolvedFile: false
        )
        XCTAssertEqual(package.name, "IntegrationTestPackage")

        XCTAssertEqual(
            try package.resolveBuildProducts().map(\.target.name).sorted(),
            [
                "Atomics",
                "CNIOAtomics",
                "CNIODarwin",
                "CNIOLinux",
                "CNIOWindows",
                "DequeModule",
                "Logging",
                "NIO",
                "NIOConcurrencyHelpers",
                "NIOCore",
                "NIOEmbedded",
                "NIOPosix",
                "OrderedCollections",
                "SDWebImage",
                "SDWebImageMapKit",
                "_AtomicsShims",
                "_NIODataStructures",
            ]
        )
    }

    func testBuildProductsInCreateMode() async throws {
        let rootPath = fixturePath.appendingPathComponent("TestingPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath.absolutePath,
            mode: .createPackage,
            onlyUseVersionsFromResolvedFile: false
        )
        XCTAssertEqual(package.name, "TestingPackage")

        XCTAssertEqual(
            try package.resolveBuildProducts().map(\.target.name),
            [
                "Logging",
                "MyTarget",
                "ExecutableTarget",
                "MyPlugin",
            ],
            "Order of the resolved products should be correct"
        )
    }

    func testBinaryBuildProductsInCreateMode() async throws {
        let rootPath = fixturePath.appendingPathComponent("BinaryPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath.absolutePath,
            mode: .createPackage,
            onlyUseVersionsFromResolvedFile: false
        )
        XCTAssertEqual(package.name, "BinaryPackage")
        XCTAssertEqual(
            Set(try package.resolveBuildProducts().map(\.target.name)),
            ["SomeBinary"]
        )
    }
}

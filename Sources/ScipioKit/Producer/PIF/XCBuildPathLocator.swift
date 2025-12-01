import Foundation
import ScipioKitCore

struct XCBuildPathLocator {
    enum Error: LocalizedError {
        case xcbuildNotFound

        var errorDescription: String? {
            switch self {
            case .xcbuildNotFound:
                return "xcbuild not found"
            }
        }
    }

    private let fileSystem: any FileSystem
    private let executor: any Executor

    init(
        fileSystem: any FileSystem = LocalFileSystem.default,
        executor: some Executor = ProcessExecutor(errorDecoder: StandardOutputDecoder())
    ) {
        self.fileSystem = fileSystem
        self.executor = executor
    }

    func fetchXCBuildPath() async throws -> URL {
        let developerDirPath = try await fetchDeveloperDirPath()

        let xcBuildPathCandidates = [
            "../SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild", // < Xcode 16.3
            "../SharedFrameworks/SwiftBuild.framework/Versions/A/Support/swbuild", // >= Xcode 16.3
        ]

        let foundXCBuildPath = xcBuildPathCandidates.map { relativePath in
            developerDirPath.appending(path: relativePath).standardizedFileURL
        }.first { [fileSystem] path in
            fileSystem.exists(path)
        }
        guard let foundXCBuildPath else {
            throw Error.xcbuildNotFound
        }

        return foundXCBuildPath
    }

    private func fetchDeveloperDirPath() async throws -> URL {
        let result = try await executor.execute(
            "/usr/bin/xcrun",
            "xcode-select",
            "-p"
        )
        let output = try result.unwrapOutput().trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(filePath: output)
    }
}

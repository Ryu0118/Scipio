import Foundation
import PackageGraph
import PackageModel
import Basics

struct BinaryExtractor {
    var descriptionPackage: DescriptionPackage
    var outputDirectory: URL
    var fileSystem: any FileSystem

    @discardableResult
    func extract(of binaryTarget: _ResolvedModule, overwrite: Bool) throws -> URL {
        guard case let .binary(binaryLocation) = binaryTarget.resolvedModuleType else {
            preconditionFailure("\(#function) must be called with a binary target")
        }

        let artifactURL = binaryLocation.localArtifactURL(rootPackageDirectory: descriptionPackage.packageDirectory.asURL)

        let frameworkName = "\(binaryTarget.c99name).xcframework"
        let fileName = artifactURL.spmAbsolutePath.basename
        let destinationPath = outputDirectory.appendingPathComponent(fileName)
        if fileSystem.exists(destinationPath.absolutePath) && overwrite {
            logger.info("🗑️ Delete \(frameworkName)", metadata: .color(.red))
            try fileSystem.removeFileTree(destinationPath.absolutePath)
        }
        do {
            try fileSystem.copy(
                from: artifactURL.spmAbsolutePath,
                to: destinationPath.spmAbsolutePath
            )
        } catch {
            throw error
        }

        return destinationPath
    }
}

import Foundation

extension PackageResolver {
    /// An object that handles caching and restoring ResolvedPackages locally.
    struct LocalCacheSystem {
        private let jsonDecoder = JSONDecoder()
        private let jsonEncoder = JSONEncoder()
        private let packageLocator: any PackageLocator
        private let fileSystem: any FileSystem
        private let originHash: String

        private var cacheFileURL: URL {
            packageLocator.resolvedPackagesDirectory.appendingPathComponent("ResolvedPackages_\(originHash)", conformingTo: .json)
        }

        init(
            packageLocator: some PackageLocator,
            fileSystem: some FileSystem,
            originHash: String
        ) {
            self.packageLocator = packageLocator
            self.fileSystem = fileSystem
            self.originHash = originHash
        }

        /// Cache resolved packages to local disk
        /// - Parameter resolvedPackages: The set of ResolvedPackage entries derived from Package.resolved after resolving targets
        func cache(_ resolvedPackages: [ResolvedPackage]) async throws {
            let data = try jsonEncoder.encode(resolvedPackages)
            try fileSystem.writeFileContents(cacheFileURL, data: data)
        }

        /// Restore cached packages for the current origin hash
        /// - Returns: Restored packages and modules if successful; otherwise nil
        func restore() throws -> (
            allPackages: [PackageID: ResolvedPackage],
            allModules: Set<ResolvedModule>
        )? {
            guard fileSystem.exists(cacheFileURL) else {
                // If the originHash differs between the current Package.resolved and the cached one, delete it
                try? fileSystem.removeFileTree(packageLocator.resolvedPackagesDirectory)
                return nil
            }

            let data = try fileSystem.readFileContents(cacheFileURL)
            let packages = try jsonDecoder.decode([ResolvedPackage].self, from: data)
            let allPackages = packages.reduce(into: [PackageID: ResolvedPackage]()) { partialResult, element in
                partialResult[element.id] = element
            }
            let allModules = try Set(allPackages.flatMap(\.value.targets).flatMap { try $0.recursiveModuleDependencies() })

            return (
                allPackages: allPackages,
                allModules: allModules
            )
        }
    }

}

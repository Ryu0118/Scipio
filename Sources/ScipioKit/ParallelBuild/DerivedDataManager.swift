import Foundation
import AsyncOperations

/// Manages DerivedData directories for parallel build clusters
struct DerivedDataManager {
    private let fileSystem: any FileSystem
    private let baseWorkspaceDirectory: URL
    
    init(fileSystem: any FileSystem = LocalFileSystem.default, baseWorkspaceDirectory: URL) {
        self.fileSystem = fileSystem
        self.baseWorkspaceDirectory = baseWorkspaceDirectory
    }
    
    /// Creates isolated DerivedData directories for each leaf dependency
    /// - Parameter leafDependencies: Array of leaf dependencies that need separate DerivedData
    /// - Returns: Dictionary mapping leaf dependency names to their DerivedData paths
    func createIsolatedDerivedDataDirectories(for leafDependencies: [BuildProduct]) throws -> [String: URL] {
        return try leafDependencies
            .reduce(into: [String: URL]()) { result, leafDep in
                let leafDerivedDataPath = derivedDataPath(for: leafDep)
                try fileSystem.createDirectory(leafDerivedDataPath, recursive: true)
                result[leafDep.target.name] = leafDerivedDataPath
            }
    }
    
    /// Copies build artifacts from a completed leaf dependency to target clusters that need it
    /// - Parameters:
    ///   - leafDependency: The completed leaf dependency
    ///   - sourceDerivedDataPath: Source DerivedData directory containing the built leaf dependency
    ///   - targetPaths: Target DerivedData paths for clusters that depend on this leaf
    func copyLeafArtifacts(
        leafDependency: BuildProduct,
        from sourceDerivedDataPath: URL,
        to targetPaths: [String: URL]
    ) async throws {
        let copyTasks = targetPaths.compactMap { targetName, targetPath in
            (targetName, targetPath)
        }
        
        try await copyTasks.asyncForEach { targetName, targetPath in
            try await copyBuildArtifacts(
                from: sourceDerivedDataPath,
                to: targetPath,
                for: Set([leafDependency]),
                fileSystem: fileSystem
            )
        }
    }
    
    /// Copies build artifacts for ALL transitive dependencies to a cluster's DerivedData
    /// This ensures that targets have access to their complete dependency chain
    /// - Parameters:
    ///   - transitiveDependencies: All transitive dependencies that need to be available
    ///   - clusterDerivedDataPath: Target DerivedData directory for the cluster
    func copyTransitiveDependencyArtifacts(
        transitiveDependencies: Set<BuildProduct>,
        to clusterDerivedDataPath: URL
    ) async throws {
        // Copy artifacts from each transitive dependency's isolated DerivedData
        try await transitiveDependencies.asyncForEach { dependency in
            let dependencyDerivedDataPath = derivedDataPath(for: dependency)
            
            // Only copy if the dependency's DerivedData exists (it was built in Phase 1)
            if fileSystem.exists(dependencyDerivedDataPath) {
                try await copyBuildArtifacts(
                    from: dependencyDerivedDataPath,
                    to: clusterDerivedDataPath,
                    for: Set([dependency]),
                    fileSystem: fileSystem
                )
            }
        }
    }
    
    /// Cleanup isolated DerivedData directories after build completion
    /// - Parameter leafPaths: Dictionary of leaf dependency DerivedData paths to clean up
    func cleanupIsolatedDirectories(_ leafPaths: [String: URL]) throws {
        try leafPaths.values.forEach { path in
            if fileSystem.exists(path) {
                try fileSystem.removeFileTree(path)
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func derivedDataPath(for leafDependency: BuildProduct) -> URL {
        baseWorkspaceDirectory
            .appendingPathComponent("DerivedData_\(leafDependency.target.name)")
    }
    
    private func copyBuildArtifacts(
        from sourcePath: URL,
        to targetPath: URL,
        for targets: Set<BuildProduct>,
        fileSystem: any FileSystem
    ) async throws {
        let sourceProductsPath = sourcePath.appendingPathComponent("Products")
        let targetProductsPath = targetPath.appendingPathComponent("Products")
        
        // Create target Products directory if it doesn't exist
        try fileSystem.createDirectory(targetProductsPath, recursive: true)
        
        // Copy each target's build artifacts
        try targets.forEach { target in
            try copyTargetArtifacts(
                target: target,
                from: sourceProductsPath,
                to: targetProductsPath,
                fileSystem: fileSystem
            )
        }
        
        // Copy ModuleCache and other shared build directories
        try await copySharedBuildDirectories(
            from: sourcePath,
            to: targetPath,
            fileSystem: fileSystem
        )
    }
    
    private func copyTargetArtifacts(
        target: BuildProduct,
        from sourceProductsPath: URL,
        to targetProductsPath: URL,
        fileSystem: any FileSystem
    ) throws {
        // Find all configuration-platform combinations
        let productDirectories = try findProductDirectories(
            in: sourceProductsPath,
            fileSystem: fileSystem
        )
        
        try productDirectories.forEach { configPlatformDir in
            let sourceTargetPath = sourceProductsPath
                .appendingPathComponent(configPlatformDir)
            let targetTargetPath = targetProductsPath
                .appendingPathComponent(configPlatformDir)
            
            // Copy target-specific artifacts if they exist
            let targetSpecificPaths = [
                "\(target.target.name).build",
                "lib\(target.target.name).a",
                "\(target.target.name).swiftmodule",
                "\(target.target.name).swiftdoc"
            ]
            
            try targetSpecificPaths.forEach { artifactName in
                let sourcePath = sourceTargetPath.appendingPathComponent(artifactName)
                let targetPath = targetTargetPath.appendingPathComponent(artifactName)
                
                if fileSystem.exists(sourcePath) {
                    try fileSystem.createDirectory(targetPath.deletingLastPathComponent(), recursive: true)
                    try fileSystem.copy(from: sourcePath, to: targetPath)
                }
            }
        }
    }
    
    private func copySharedBuildDirectories(
        from sourcePath: URL,
        to targetPath: URL,
        fileSystem: any FileSystem
    ) async throws {
        let sharedDirectories = [
            "ModuleCache",
            "info.plist",
            "Build"
        ]
        
        try sharedDirectories.forEach { dirName in
            let sourceDirPath = sourcePath.appendingPathComponent(dirName)
            let targetDirPath = targetPath.appendingPathComponent(dirName)
            
            if fileSystem.exists(sourceDirPath) {
                try fileSystem.copy(from: sourceDirPath, to: targetDirPath)
            }
        }
    }
    
    private func findProductDirectories(
        in productsPath: URL,
        fileSystem: any FileSystem
    ) throws -> [String] {
        guard fileSystem.exists(productsPath) else {
            return []
        }
        
        let contents = try fileSystem.getDirectoryContents(productsPath)
        return contents.filter { filename in
            let fullPath = productsPath.appendingPathComponent(filename)
            return fileSystem.exists(fullPath)
        }
    }
}


import Foundation
import AsyncOperations

/// Manages isolated DerivedData directories for parallel builds
/// Uses actor pattern to ensure thread-safe access to isolated paths
actor IsolatedDerivedDataManager {
    private let baseWorkspaceDirectory: URL
    private let fileSystem: any FileSystem
    private var isolatedPaths: [String: URL] = [:]
    private let isolatedDerivedDataRoot: URL
    
    init(baseWorkspaceDirectory: URL, fileSystem: any FileSystem = LocalFileSystem.default) {
        self.baseWorkspaceDirectory = baseWorkspaceDirectory
        self.fileSystem = fileSystem
        // Ensure absolute path for IsolatedDerivedData root
        self.isolatedDerivedDataRoot = baseWorkspaceDirectory
            .appendingPathComponent(".build/scipio/IsolatedDerivedData")
            .standardized
    }
    
    /// Creates and returns an isolated DerivedData directory for the specified target
    /// - Parameter targetName: Name of the target requiring isolated DerivedData
    /// - Returns: URL of the isolated DerivedData directory
    /// - Throws: If directory creation fails
    func createIsolatedDerivedData(for targetName: String) throws -> URL {
        // Check if already created
        if let existingPath = isolatedPaths[targetName] {
            return existingPath
        }
        
        // Create new isolated path with absolute path
        let isolatedPath = isolatedDerivedDataRoot.appendingPathComponent(targetName).standardized
        
        // Create complete directory structure for XCBuild compatibility
        try createDerivedDataStructure(at: isolatedPath)
        
        // Store the path for future reference
        isolatedPaths[targetName] = isolatedPath
        
        return isolatedPath
    }
    
    /// Creates the complete DerivedData directory structure
    /// - Parameter derivedDataPath: Root path for the DerivedData structure
    private func createDerivedDataStructure(at derivedDataPath: URL) throws {
        // Create root directory
        try fileSystem.createDirectory(derivedDataPath, recursive: true)
        
        // Create Build directory structure
        let buildDir = derivedDataPath.appendingPathComponent("Build")
        try fileSystem.createDirectory(buildDir, recursive: true)
        
        let productsDir = buildDir.appendingPathComponent("Products")
        try fileSystem.createDirectory(productsDir, recursive: true)
        
        // Create Intermediates directory
        let intermediatesDir = derivedDataPath.appendingPathComponent("Intermediates.noindex")
        try fileSystem.createDirectory(intermediatesDir, recursive: true)
        
        // Create XCBuildData directory
        let xcbuildDataDir = intermediatesDir.appendingPathComponent("XCBuildData")
        try fileSystem.createDirectory(xcbuildDataDir, recursive: true)
    }
    
    /// Returns the isolated DerivedData path for a target if it exists
    /// - Parameter targetName: Name of the target
    /// - Returns: URL of the isolated DerivedData directory, or nil if not created
    func getIsolatedDerivedData(for targetName: String) -> URL? {
        return isolatedPaths[targetName]
    }
    
    /// Returns all currently managed isolated paths
    /// - Returns: Dictionary mapping target names to their isolated DerivedData paths
    func getAllIsolatedPaths() -> [String: URL] {
        return isolatedPaths
    }
    
    /// Cleans up the isolated DerivedData directory for a specific target
    /// - Parameter targetName: Name of the target to clean up
    /// - Throws: If cleanup fails
    func cleanupIsolatedDerivedData(for targetName: String) throws {
        guard let isolatedPath = isolatedPaths[targetName] else {
            return // Nothing to clean up
        }
        
        if fileSystem.exists(isolatedPath) {
            try fileSystem.removeFileTree(isolatedPath)
            logger.debug("🧹 Cleaned up isolated DerivedData for \(targetName)")
        }
        
        isolatedPaths.removeValue(forKey: targetName)
    }
    
    /// Cleans up all isolated DerivedData directories
    /// - Throws: If cleanup fails
    func cleanupAllIsolatedDerivedData() async throws {
        let targetNames = Array(isolatedPaths.keys)
        
        try await targetNames.asyncForEach { [self] targetName in
            try await self.cleanupIsolatedDerivedData(for: targetName)
        }
        
        // Remove root isolated directory if it exists and is empty
        if fileSystem.exists(isolatedDerivedDataRoot) {
            let contents = try fileSystem.getDirectoryContents(isolatedDerivedDataRoot)
            if contents.isEmpty {
                try fileSystem.removeFileTree(isolatedDerivedDataRoot)
                logger.debug("🧹 Removed isolated DerivedData root directory")
            }
        }
    }
    
    /// Returns the Products directory path for a specific target's isolated DerivedData
    /// - Parameter targetName: Name of the target
    /// - Returns: URL of the Products directory within the isolated DerivedData
    /// - Throws: If the isolated DerivedData doesn't exist for the target
    func getProductsDirectory(for targetName: String) throws -> URL {
        guard let isolatedPath = isolatedPaths[targetName] else {
            throw IsolatedDerivedDataError.targetNotFound(targetName)
        }
        
        return isolatedPath.appendingPathComponent("Build/Products")
    }
    
    /// Ensures the Products directory exists for a specific target
    /// - Parameter targetName: Name of the target
    /// - Throws: If directory creation fails or target doesn't exist
    func ensureProductsDirectory(for targetName: String) throws {
        let productsDir = try getProductsDirectory(for: targetName)
        try fileSystem.createDirectory(productsDir, recursive: true)
    }
    
    /// Returns the root isolated DerivedData directory
    /// - Returns: URL of the root isolated DerivedData directory
    func getIsolatedDerivedDataRoot() -> URL {
        return isolatedDerivedDataRoot
    }
}

/// Errors that can occur during isolated DerivedData management
enum IsolatedDerivedDataError: LocalizedError {
    case targetNotFound(String)
    case directoryCreationFailed(String, Error)
    case cleanupFailed(String, Error)
    
    var errorDescription: String? {
        switch self {
        case .targetNotFound(let targetName):
            return "Isolated DerivedData not found for target: \(targetName)"
        case .directoryCreationFailed(let targetName, let error):
            return "Failed to create isolated DerivedData for target \(targetName): \(error.localizedDescription)"
        case .cleanupFailed(let targetName, let error):
            return "Failed to cleanup isolated DerivedData for target \(targetName): \(error.localizedDescription)"
        }
    }
}
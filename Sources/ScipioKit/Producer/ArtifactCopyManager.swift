import Foundation
import AsyncOperations

/// Manages atomic copying of build artifacts between isolated DerivedData directories
/// Uses actor pattern to ensure thread-safe copy operations
actor ArtifactCopyManager {
    private let fileSystem: any FileSystem
    private var activeOperations: Set<String> = []
    
    init(fileSystem: any FileSystem = LocalFileSystem.default) {
        self.fileSystem = fileSystem
    }
    
    /// Copies build artifacts from a completed target to its dependent targets
    /// - Parameters:
    ///   - sourceTarget: Name of the source target (completed build)
    ///   - dependentTargets: Names of targets that depend on the source target
    ///   - derivedDataManager: Manager for isolated DerivedData directories
    /// - Throws: If copy operations fail
    func copyArtifacts(
        from sourceTarget: String,
        to dependentTargets: [String],
        using derivedDataManager: IsolatedDerivedDataManager
    ) async throws {
        // Skip if no dependent targets
        guard !dependentTargets.isEmpty else { return }
        
        // Prevent concurrent copy operations for the same source target
        let operationKey = "copy-\(sourceTarget)"
        guard !activeOperations.contains(operationKey) else {
            logger.warning("⚠️ Copy operation already in progress for \(sourceTarget)")
            return
        }
        
        activeOperations.insert(operationKey)
        defer { activeOperations.remove(operationKey) }
        
        // Get source Products directory
        let sourceProductsDir = try await derivedDataManager.getProductsDirectory(for: sourceTarget)
        
        guard fileSystem.exists(sourceProductsDir) else {
            logger.warning("⚠️ Source products directory not found for \(sourceTarget): \(sourceProductsDir.path)")
            return
        }
        
        logger.debug("📦 Copying artifacts from \(sourceTarget) to \(dependentTargets.count) dependent target(s)")
        
        // Copy artifacts to all dependent targets in parallel
        try await dependentTargets.asyncForEach { [self] dependentTarget in
            try await self.copyArtifactsToTarget(
                sourceProductsDir: sourceProductsDir,
                sourceTargetName: sourceTarget,
                dependentTargetName: dependentTarget,
                derivedDataManager: derivedDataManager
            )
        }
        
        logger.debug("✅ Completed artifact copying from \(sourceTarget)")
    }
    
    /// Copies artifacts to a single dependent target
    private func copyArtifactsToTarget(
        sourceProductsDir: URL,
        sourceTargetName: String,
        dependentTargetName: String,
        derivedDataManager: IsolatedDerivedDataManager
    ) async throws {
        // Ensure dependent target's isolated DerivedData exists before getting Products directory
        _ = try await derivedDataManager.createIsolatedDerivedData(for: dependentTargetName)
        
        // Get destination Products directory
        let destinationProductsDir = try await derivedDataManager.getProductsDirectory(for: dependentTargetName)
        
        // Ensure destination directory exists
        try await derivedDataManager.ensureProductsDirectory(for: dependentTargetName)
        
        // Get list of artifacts to copy
        let artifactsToCopy = try getArtifactsToCopy(from: sourceProductsDir, targetName: sourceTargetName)
        
        guard !artifactsToCopy.isEmpty else {
            logger.debug("ℹ️ No artifacts found to copy from \(sourceTargetName)")
            return
        }
        
        // Copy each artifact atomically
        for artifact in artifactsToCopy {
            try await copyArtifactAtomically(
                from: artifact.source,
                to: destinationProductsDir.appendingPathComponent(artifact.relativePath),
                artifactName: artifact.name
            )
        }
        
        logger.debug("📋 Copied \(artifactsToCopy.count) artifacts from \(sourceTargetName) to \(dependentTargetName)")
    }
    
    /// Gets list of artifacts that need to be copied
    private func getArtifactsToCopy(from sourceProductsDir: URL, targetName: String) throws -> [ArtifactInfo] {
        var artifacts: [ArtifactInfo] = []
        let contents = try fileSystem.getDirectoryContents(sourceProductsDir)
        
        for item in contents {
            let itemPath = sourceProductsDir.appendingPathComponent(item)
            
            if fileSystem.isDirectory(itemPath) {
                // Check if it's a framework or bundle
                if item.hasSuffix(".framework") || item.hasSuffix(".bundle") || item.hasSuffix(".xcframework") {
                    artifacts.append(ArtifactInfo(
                        name: item,
                        source: itemPath,
                        relativePath: item
                    ))
                }
            } else if fileSystem.isFile(itemPath) {
                // Check for other build artifacts (libraries, etc.)
                if item.hasPrefix("lib") || item.hasSuffix(".dylib") || item.hasSuffix(".a") {
                    artifacts.append(ArtifactInfo(
                        name: item,
                        source: itemPath,
                        relativePath: item
                    ))
                }
            }
        }
        
        return artifacts
    }
    
    /// Copies a single artifact atomically using temporary location and move
    private func copyArtifactAtomically(
        from source: URL,
        to destination: URL,
        artifactName: String
    ) async throws {
        // Create temporary destination path for atomic operation
        let tempDestination = destination.appendingPathExtension("tmp-\(UUID().uuidString)")
        
        do {
            // Copy to temporary location first
            if fileSystem.isDirectory(source) {
                try copyDirectoryRecursively(from: source, to: tempDestination)
            } else {
                try fileSystem.copy(from: source, to: tempDestination)
            }
            
            // Remove existing destination if it exists
            if fileSystem.exists(destination) {
                try fileSystem.removeFileTree(destination)
            }
            
            // Atomic move from temporary to final location
            try fileSystem.move(from: tempDestination, to: destination)
            
            logger.debug("🔄 Copied artifact: \(artifactName)")
        } catch {
            // Clean up temporary file if operation failed
            if fileSystem.exists(tempDestination) {
                try? fileSystem.removeFileTree(tempDestination)
            }
            throw ArtifactCopyError.copyFailed(artifactName, error)
        }
    }
    
    /// Recursively copies a directory
    private func copyDirectoryRecursively(from source: URL, to destination: URL) throws {
        try fileSystem.createDirectory(destination, recursive: true)
        
        let contents = try fileSystem.getDirectoryContents(source)
        for item in contents {
            let sourcePath = source.appendingPathComponent(item)
            let destPath = destination.appendingPathComponent(item)
            
            if fileSystem.isDirectory(sourcePath) {
                try copyDirectoryRecursively(from: sourcePath, to: destPath)
            } else {
                try fileSystem.copy(from: sourcePath, to: destPath)
            }
        }
    }
    
    /// Cleans up any temporary files that might have been left behind
    func cleanupTemporaryFiles(in directory: URL) async throws {
        guard fileSystem.exists(directory) else { return }
        
        let contents = try fileSystem.getDirectoryContents(directory)
        let tempFiles = contents.filter { $0.contains(".tmp-") }
        
        for tempFile in tempFiles {
            let tempPath = directory.appendingPathComponent(tempFile)
            try fileSystem.removeFileTree(tempPath)
            logger.debug("🧹 Cleaned up temporary file: \(tempFile)")
        }
    }
}

/// Information about a build artifact to be copied
private struct ArtifactInfo {
    let name: String
    let source: URL
    let relativePath: String
}

/// Errors that can occur during artifact copying
enum ArtifactCopyError: LocalizedError {
    case copyFailed(String, Error)
    case sourceNotFound(String)
    case destinationCreationFailed(String, Error)
    
    var errorDescription: String? {
        switch self {
        case .copyFailed(let artifactName, let error):
            return "Failed to copy artifact '\(artifactName)': \(error.localizedDescription)"
        case .sourceNotFound(let artifactName):
            return "Source artifact not found: \(artifactName)"
        case .destinationCreationFailed(let path, let error):
            return "Failed to create destination directory '\(path)': \(error.localizedDescription)"
        }
    }
}
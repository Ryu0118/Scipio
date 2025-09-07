import Foundation
import AsyncOperations

/// Target state in the dynamic build process  
enum TargetState: Sendable {
    case waiting(dependencies: Set<String>)
    case ready
    case building
    case completed
    
    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
    
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
    
    var isBuilding: Bool {
        if case .building = self { return true }
        return false
    }
}

/// Coordinates build events and manages execution state in a thread-safe manner
/// Uses actor pattern to ensure safe concurrent access to build state
actor BuildEventCoordinator {
    /// The build plan manifest being executed
    private let buildPlan: BuildPlan
    
    /// Set of currently building targets to prevent duplicate builds
    private var currentlyBuilding: Set<String> = []
    
    /// Current state of each target (for parallel builds)
    private var targetStates: [String: TargetState]
    
    init(buildPlan: BuildPlan) {
        self.buildPlan = buildPlan
        
        // Initialize target states based on strategy
        switch buildPlan {
        case .serial:
            self.targetStates = [:]
        case .parallel(_, let dependencyMap, _):
            // Initialize target states based on dependencies
            self.targetStates = dependencyMap.mapValues { dependencies in
                dependencies.isEmpty ? .ready : .waiting(dependencies: dependencies)
            }
        }
    }
    
    /// Returns targets that are ready to build, respecting parallelism limits
    /// Computes ready targets from build plan manifest and execution state
    /// - Returns: Array of targets ready for immediate build execution
    func getNextReadyTargets() -> [CacheSystem.CacheTarget] {
        let availableSlots = BuildPlan.maxParallelism - currentlyBuilding.count
        guard availableSlots > 0 else { return [] }
        
        let readyTargets = computeReadyTargets()
        
        return readyTargets
            .filter { !currentlyBuilding.contains($0.buildProduct.target.name) }
            .prefix(availableSlots)
            .map { target in
                let targetName = target.buildProduct.target.name
                currentlyBuilding.insert(targetName)
                targetStates[targetName] = .building
                return target
            }
    }
    
    /// Computes targets that are ready to build based on current execution state
    private func computeReadyTargets() -> [CacheSystem.CacheTarget] {
        switch buildPlan {
        case .serial:
            // Serial: return first stage targets that haven't been completed
            // This is handled by SerialBuildExecutor in BuildOperations
            return []
            
        case .parallel(let targets, _, _):
            // Parallel: return targets with no pending dependencies
            return targetStates.compactMap { (targetName, state) in
                if state.isReady, let target = targets[targetName] {
                    return target
                }
                return nil
            }
        }
    }
    
    /// Marks a target as completed and releases its build slot for dependency resolution
    /// Updates execution state and triggers dependency resolution for waiting targets
    /// - Parameter target: The target that has completed building
    func markTargetCompleted(_ target: CacheSystem.CacheTarget) {
        let targetName = target.buildProduct.target.name
        
        targetStates[targetName] = .completed
        currentlyBuilding.remove(targetName)
        
        // Update dependent states for parallel builds
        if case .parallel = buildPlan {
            updateDependentStates(for: targetName)
        }
        
        logger.debug("✅ Target \(targetName) completed. Running builds: \(currentlyBuilding.count)/\(BuildPlan.maxParallelism)")
    }
    
    /// Updates states of targets that depend on the completed target
    private func updateDependentStates(for completedTarget: String) {
        guard case .parallel(_, _, let dependentMap) = buildPlan,
              let dependents = dependentMap[completedTarget] else { return }
        
        for dependent in dependents {
            if case .waiting(var dependencies) = targetStates[dependent] {
                dependencies.remove(completedTarget)
                
                if dependencies.isEmpty {
                    targetStates[dependent] = .ready
                } else {
                    targetStates[dependent] = .waiting(dependencies: dependencies)
                }
            }
        }
    }
    
    /// Returns true if all targets in the build plan are completed
    /// - Returns: Boolean indicating whether all targets have finished building
    var isComplete: Bool {
        switch buildPlan {
        case .serial:
            // Serial completion is managed by SerialBuildExecutor in BuildOperations
            return false
        case .parallel:
            return targetStates.values.allSatisfy { $0.isCompleted }
        }
    }
    
    /// Returns current build progress information for status reporting
    /// - Returns: BuildProgress struct with completion counts and currently building targets
    var buildProgress: BuildProgress {
        let completedCount = switch buildPlan {
        case .serial:
            // For serial, we don't track individual completion in coordinator
            0
        case .parallel:
            targetStates.values.filter { $0.isCompleted }.count
        }
        
        return BuildProgress(
            completed: completedCount,
            total: buildPlan.totalTargetCount,
            currentlyBuilding: Array(currentlyBuilding)
        )
    }
    
    /// Returns current state of a specific target for dependency checking
    /// - Parameter targetName: Name of the target to query
    /// - Returns: Optional TargetState indicating current build status
    func getTargetState(_ targetName: String) -> TargetState? {
        return targetStates[targetName]
    }
    
    /// Returns diagnostic information about current build state for monitoring
    /// - Returns: BuildDiagnostics struct with detailed build state information
    var diagnosticInfo: BuildDiagnostics {
        let readyCount = computeReadyTargets().count
        let buildingCount = currentlyBuilding.count
        let completedCount = switch buildPlan {
        case .serial:
            0 // Managed by SerialBuildExecutor
        case .parallel:
            targetStates.values.filter { $0.isCompleted }.count
        }
        let totalCount = buildPlan.totalTargetCount
        
        return BuildDiagnostics(
            readyTargets: readyCount,
            buildingTargets: buildingCount,
            completedTargets: completedCount,
            totalTargets: totalCount,
            availableSlots: BuildPlan.maxParallelism - buildingCount
        )
    }
}

// MARK: - Supporting Types

/// Represents the current progress of a dynamic parallel build
struct BuildProgress: Sendable {
    /// Number of targets that have completed building
    let completed: Int
    /// Total number of targets in the build plan
    let total: Int
    /// Names of targets currently being built
    let currentlyBuilding: [String]
    
    /// Calculates completion percentage for progress reporting
    /// - Returns: Completion percentage as Double (0.0 to 100.0)
    var percentage: Double {
        guard total > 0 else { return 0.0 }
        return Double(completed) / Double(total) * 100.0
    }
}

/// Diagnostic information about current build state for monitoring and debugging
struct BuildDiagnostics: Sendable {
    /// Number of targets ready to build (dependencies satisfied)
    let readyTargets: Int
    /// Number of targets currently building
    let buildingTargets: Int
    /// Number of targets that have completed
    let completedTargets: Int
    /// Total number of targets in the build plan
    let totalTargets: Int
    /// Number of available build slots (maxParallelism - buildingTargets)
    let availableSlots: Int
}


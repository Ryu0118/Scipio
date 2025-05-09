import Foundation
import ScipioStorage
import Basics
import struct TSCUtility.Version
import Algorithms
// We may drop this annotation in SwiftPM's future release
@preconcurrency import PackageGraph
import PackageModel
import SourceControl

private let jsonEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}()

private let jsonDecoder = {
    let decoder = JSONDecoder()
    return decoder
}()

struct ClangChecker<E: Executor> {
    private let executor: E

    init(executor: E = ProcessExecutor()) {
        self.executor = executor
    }

    func fetchClangVersion() async throws -> String? {
        let result = try await executor.execute("/usr/bin/xcrun", "clang", "--version")
        let rawString = try result.unwrapOutput()
        return parseClangVersion(from: rawString)
    }

    private func parseClangVersion(from outputString: String) -> String? {
        let regex = /Apple clang version .+ \((?<version>.+)\)/
        guard let result = try? regex.firstMatch(in: outputString) else {
            return nil
        }
        return String(result.output.version)
    }
}

extension PinsStore.PinState: Codable {
    enum Key: CodingKey {
        case revision
        case branch
        case version
    }

    public func encode(to encoder: Encoder) throws {
        var versionContainer = encoder.container(keyedBy: Key.self)
        switch self {
        case .version(let version, let revision):
            try versionContainer.encode(version.description, forKey: .version)
            try versionContainer.encode(revision, forKey: .revision)
        case .revision(let revision):
            try versionContainer.encode(revision, forKey: .revision)
        case .branch(let branchName, let revision):
            try versionContainer.encode(branchName, forKey: .branch)
            try versionContainer.encode(revision, forKey: .revision)
        }
    }

    public init(from decoder: Decoder) throws {
        let decoder = try decoder.container(keyedBy: Key.self)
        if decoder.contains(.branch) {
            let branchName = try decoder.decode(String.self, forKey: .branch)
            let revision = try decoder.decode(String.self, forKey: .revision)
            self = .branch(name: branchName, revision: revision)
        } else if decoder.contains(.version) {
            let version = try decoder.decode(Version.self, forKey: .version)
            let revision = try decoder.decode(String?.self, forKey: .revision)
            self = .version(version, revision: revision)
        } else {
            let revision = try decoder.decode(String.self, forKey: .revision)
            self = .revision(revision)
        }
    }
}

extension PinsStore.PinState: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .revision(let revision):
            hasher.combine(revision)
        case .version(let version, let revision):
            hasher.combine(version)
            hasher.combine(revision)
        case .branch(let branchName, let revision):
            hasher.combine(branchName)
            hasher.combine(revision)
        }
    }
}

public struct SwiftPMCacheKey: CacheKey {
    /// The canonical repository URL the manifest was loaded from, for local packages only.
    public var localPackageCanonicalLocation: String?
    public var pin: PinsStore.PinState
    public var targetName: String
    var buildOptions: BuildOptions
    public var clangVersion: String
    public var xcodeVersion: XcodeVersion
    public var scipioVersion: String?
}

struct CacheSystem: Sendable {
    static let defaultParalellNumber = 8
    private let pinsStore: PinsStore
    private let outputDirectory: URL
    private let fileSystem: any FileSystem

    struct CacheTarget: Hashable, Sendable {
        var buildProduct: BuildProduct
        var buildOptions: BuildOptions
    }

    enum Error: LocalizedError {
        case revisionNotDetected(String)
        case compilerVersionNotDetected
        case xcodeVersionNotDetected
        case couldNotReadVersionFile(URL)

        var errorDescription: String? {
            switch self {
            case .revisionNotDetected(let packageName):
                return "Repository version is not detected for \(packageName)."
            case .compilerVersionNotDetected:
                return "Compiler version not detected. Please check your environment"
            case .xcodeVersionNotDetected:
                return "Xcode version not detected. Please check your environment"
            case .couldNotReadVersionFile(let path):
                return "Could not read VersionFile \(path.path)"
            }
        }
    }

    init(
        pinsStore: PinsStore,
        outputDirectory: URL,
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.pinsStore = pinsStore
        self.outputDirectory = outputDirectory
        self.fileSystem = fileSystem
    }

    func cacheFrameworks(_ targets: Set<CacheTarget>, to storages: [any CacheStorage]) async {
        for storage in storages {
            await cacheFrameworks(targets, to: storage)
        }
    }

    private func cacheFrameworks(_ targets: Set<CacheTarget>, to storage: some CacheStorage) async {
        let chunked = targets.chunks(ofCount: storage.parallelNumber ?? CacheSystem.defaultParalellNumber)

        let storageName = storage.displayName
        for chunk in chunked {
            await withTaskGroup(of: Void.self) { group in
                for target in chunk {
                    let frameworkName = target.buildProduct.frameworkName
                    group.addTask {
                        let frameworkPath = outputDirectory.appendingPathComponent(frameworkName)
                        do {
                            logger.info(
                                "🚀 Cache \(frameworkName) to cache storage: \(storageName)",
                                metadata: .color(.green)
                            )
                            try await cacheFramework(target, at: frameworkPath, to: storage)
                        } catch {
                            logger.warning("⚠️ Can't create caches for \(frameworkPath.path)")
                        }
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func cacheFramework(_ target: CacheTarget, at frameworkPath: URL, to storage: any CacheStorage) async throws {
        let cacheKey = try await calculateCacheKey(of: target)

        try await storage.cacheFramework(frameworkPath, for: cacheKey)
    }

    func generateVersionFile(for target: CacheTarget) async throws {
        let cacheKey = try await calculateCacheKey(of: target)

        let data = try jsonEncoder.encode(cacheKey)
        let versionFilePath = outputDirectory.appendingPathComponent(versionFileName(for: target.buildProduct.target.name))
        try fileSystem.writeFileContents(
            versionFilePath.absolutePath.spmAbsolutePath,
            data: data
        )
    }

    func existsValidCache(cacheKey: SwiftPMCacheKey) async -> Bool {
        do {
            let versionFilePath = versionFilePath(for: cacheKey.targetName)
            guard fileSystem.exists(versionFilePath.absolutePath) else { return false }
            let decoder = JSONDecoder()
            guard let contents = try? fileSystem.readFileContents(versionFilePath.absolutePath).contents else {
                throw Error.couldNotReadVersionFile(versionFilePath)
            }
            let versionFileKey = try decoder.decode(SwiftPMCacheKey.self, from: Data(contents))
            return versionFileKey == cacheKey
        } catch {
            return false
        }
    }

    enum RestoreResult {
        case succeeded
        case failed(LocalizedError?)
        case noCache
    }

    func restoreCacheIfPossible(target: CacheTarget, storage: some CacheStorage) async -> RestoreResult {
        do {
            let cacheKey = try await calculateCacheKey(of: target)
            if try await storage.existsValidCache(for: cacheKey) {
                try await storage.fetchArtifacts(for: cacheKey, to: outputDirectory)
                return .succeeded
            } else {
                return .noCache
            }
        } catch {
            return .failed(error as? LocalizedError)
        }
    }

    func calculateCacheKey(of target: CacheTarget) async throws -> SwiftPMCacheKey {
        let package = target.buildProduct.package

        let localPackageCanonicalLocation: String? = switch package.manifest.packageKind {
        case .fileSystem, .localSourceControl:
            package.canonicalPackageLocation.description
        case .root, .remoteSourceControl, .registry:
            nil
        }

        let pin = try retrievePinState(package: package)

        let targetName = target.buildProduct.target.name
        let buildOptions = target.buildOptions
        guard let clangVersion = try await ClangChecker().fetchClangVersion() else {
            throw Error.compilerVersionNotDetected
        } // TODO DI
        guard let xcodeVersion = try await XcodeVersionFetcher().fetchXcodeVersion() else {
            throw Error.xcodeVersionNotDetected
        }
        return SwiftPMCacheKey(
            localPackageCanonicalLocation: localPackageCanonicalLocation,
            pin: pin,
            targetName: targetName,
            buildOptions: buildOptions,
            clangVersion: clangVersion,
            xcodeVersion: xcodeVersion,
            scipioVersion: currentScipioVersion
        )
    }

    private func retrievePinState(package: _ResolvedPackage) throws -> PinsStore.PinState {
        guard let pin = package.pinState else {
            throw Error.revisionNotDetected(package.manifest.name)
        }
        let pinState: PinsStore.PinState =
            if let version = pin.version {
                .version(Version(stringLiteral: version), revision: pin.revision)
            }
            else if let branch = pin.branch {
                .branch(name: branch, revision: pin.revision)
            }
            else {
                .revision(pin.revision)
            }
        return pinState
    }

    private func versionFilePath(for targetName: String) -> URL {
        outputDirectory.appendingPathComponent(versionFileName(for: targetName))
    }

    private func versionFileName(for targetName: String) -> String {
        ".\(targetName).version"
    }
}

public struct VersionFileDecoder {
    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem = localFileSystem) {
        self.fileSystem = fileSystem
    }

    public func decode(versionFile: URL) throws -> SwiftPMCacheKey {
        try jsonDecoder.decode(
            path: versionFile.absolutePath.spmAbsolutePath,
            fileSystem: fileSystem,
            as: SwiftPMCacheKey.self
        )
    }
}

extension ResolvedPackage {
    fileprivate func makePinFromRevision() -> PinsStore.Pin? {
        let repository = GitRepository(path: path)

        guard let tag = repository.getCurrentTag(), let version = Version(tag: tag) else {
            return nil
        }

        // TODO: Even though the version requirement already covers the vast majority of cases,
        // supporting `branch` and `revision` requirements should, in theory, also be possible.
        return PinsStore.Pin(
            packageRef: PackageReference(
                identity: identity,
                kind: manifest.packageKind
            ),
            state: .version(
                version,
                revision: try? repository.getCurrentRevision().identifier
            )
        )
    }
}

public struct CanonicalPackageLocation: Equatable, CustomStringConvertible {
    /// A textual representation of this instance.
    public let description: String

    /// Instantiates an instance of the conforming type from a string representation.
    public init(_ string: String) {
        self.description = computeCanonicalLocation(string).description
    }
}

/// Similar to `CanonicalPackageLocation` but differentiates based on the scheme.
public struct CanonicalPackageURL: Equatable, CustomStringConvertible {
    public let description: String
    public let scheme: String?

    public init(_ string: String) {
        let location = computeCanonicalLocation(string)
        self.description = location.description
        self.scheme = location.scheme
    }
}

private func computeCanonicalLocation(_ string: String) -> (description: String, scheme: String?) {
    var description = string.precomposedStringWithCanonicalMapping.lowercased()

    // Remove the scheme component, if present.
    let detectedScheme = description.dropSchemeComponentPrefixIfPresent()
    var scheme = detectedScheme

    // Remove the userinfo subcomponent (user / password), if present.
    if case (let user, _)? = description.dropUserinfoSubcomponentPrefixIfPresent() {
        // If a user was provided, perform tilde expansion, if applicable.
        description.replaceFirstOccurrenceIfPresent(of: "/~/", with: "/~\(user)/")

        if user == "git", scheme == nil {
            scheme = "ssh"
        }
    }

    // Remove the port subcomponent, if present.
    description.removePortComponentIfPresent()

    // Remove the fragment component, if present.
    description.removeFragmentComponentIfPresent()

    // Remove the query component, if present.
    description.removeQueryComponentIfPresent()

    // Accommodate "`scp`-style" SSH URLs
    if detectedScheme == nil || detectedScheme == "ssh" {
        description.replaceFirstOccurrenceIfPresent(of: ":", before: description.firstIndex(of: "/"), with: "/")
    }

    // Split the remaining string into path components,
    // filtering out empty path components and removing valid percent encodings.
    var components = description.split(omittingEmptySubsequences: true, whereSeparator: isSeparator)
        .compactMap { $0.removingPercentEncoding ?? String($0) }

    // Remove the `.git` suffix from the last path component.
    var lastPathComponent = components.popLast() ?? ""
    lastPathComponent.removeSuffixIfPresent(".git")
    components.append(lastPathComponent)

    description = components.joined(separator: "/")

    // Prepend a leading slash for file URLs and paths
    if detectedScheme == "file" || string.first.flatMap(isSeparator) ?? false {
        scheme = "file"
        description.insert("/", at: description.startIndex)
    }

    return (description, scheme)
}

nonisolated(unsafe) fileprivate let isSeparator: (Character) -> Bool = { $0 == "/" }

extension Character {
    fileprivate var isDigit: Bool {
        switch self {
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            return true
        default:
            return false
        }
    }

    fileprivate var isAllowedInURLScheme: Bool {
        isLetter || self.isDigit || self == "+" || self == "-" || self == "."
    }
}

extension String {
    @discardableResult
    private mutating func removePrefixIfPresent<T: StringProtocol>(_ prefix: T) -> Bool {
        guard hasPrefix(prefix) else { return false }
        removeFirst(prefix.count)
        return true
    }

    @discardableResult
    fileprivate mutating func removeSuffixIfPresent<T: StringProtocol>(_ suffix: T) -> Bool {
        guard hasSuffix(suffix) else { return false }
        removeLast(suffix.count)
        return true
    }

    @discardableResult
    fileprivate mutating func dropSchemeComponentPrefixIfPresent() -> String? {
        if let rangeOfDelimiter = range(of: "://"),
           self[startIndex].isLetter,
           self[..<rangeOfDelimiter.lowerBound].allSatisfy(\.isAllowedInURLScheme)
        {
            defer { self.removeSubrange(..<rangeOfDelimiter.upperBound) }

            return String(self[..<rangeOfDelimiter.lowerBound])
        }

        return nil
    }

    @discardableResult
    fileprivate mutating func dropUserinfoSubcomponentPrefixIfPresent() -> (user: String, password: String?)? {
        if let indexOfAtSign = firstIndex(of: "@"),
           let indexOfFirstPathComponent = firstIndex(where: isSeparator),
           indexOfAtSign < indexOfFirstPathComponent
        {
            defer { self.removeSubrange(...indexOfAtSign) }

            let userinfo = self[..<indexOfAtSign]
            var components = userinfo.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard components.count > 0 else { return nil }
            let user = String(components.removeFirst())
            let password = components.last.map(String.init)

            return (user, password)
        }

        return nil
    }

    @discardableResult
    fileprivate mutating func removePortComponentIfPresent() -> Bool {
        if let indexOfFirstPathComponent = firstIndex(where: isSeparator),
           let startIndexOfPort = firstIndex(of: ":"),
           startIndexOfPort < endIndex,
           let endIndexOfPort = self[index(after: startIndexOfPort)...].lastIndex(where: { $0.isDigit }),
           endIndexOfPort <= indexOfFirstPathComponent
        {
            self.removeSubrange(startIndexOfPort ... endIndexOfPort)
            return true
        }

        return false
    }

    @discardableResult
    fileprivate mutating func removeFragmentComponentIfPresent() -> Bool {
        if let index = firstIndex(of: "#") {
            self.removeSubrange(index...)
        }

        return false
    }

    @discardableResult
    fileprivate mutating func removeQueryComponentIfPresent() -> Bool {
        if let index = firstIndex(of: "?") {
            self.removeSubrange(index...)
        }

        return false
    }

    @discardableResult
    fileprivate mutating func replaceFirstOccurrenceIfPresent<T: StringProtocol, U: StringProtocol>(
        of string: T,
        before index: Index? = nil,
        with replacement: U
    ) -> Bool {
        guard let range = range(of: string) else { return false }

        if let index, range.lowerBound >= index {
            return false
        }

        self.replaceSubrange(range, with: replacement)
        return true
    }
}

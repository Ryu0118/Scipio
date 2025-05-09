import Foundation
import Basics
import PackageGraph
import PackageModel

// A generator to generate modulemaps which are distributed in the XCFramework
struct FrameworkModuleMapGenerator {
    private struct Context {
        var resolvedTarget: _ResolvedModule
        var sdk: SDK
        var keepPublicHeadersStructure: Bool
    }

    private var packageLocator: any PackageLocator
    private var fileSystem: any FileSystem

    enum Error: LocalizedError {
        case unableToLoadCustomModuleMap(TSCAbsolutePath)

        var errorDescription: String? {
            switch self {
            case .unableToLoadCustomModuleMap(let customModuleMapPath):
                return "Something went wrong to load \(customModuleMapPath.pathString)"
            }
        }
    }

    init(packageLocator: some PackageLocator, fileSystem: some FileSystem) {
        self.packageLocator = packageLocator
        self.fileSystem = fileSystem
    }

    func generate(
        resolvedTarget: _ResolvedModule,
        sdk: SDK,
        keepPublicHeadersStructure: Bool
    ) throws -> TSCAbsolutePath? {
        let context = Context(
            resolvedTarget: resolvedTarget,
            sdk: sdk,
            keepPublicHeadersStructure: keepPublicHeadersStructure
        )

        if case let .clang(includeDir) = resolvedTarget.resolvedModuleType {
            let moduleMapGenerator = ModuleMapGenerator(
                targetName: resolvedTarget.name,
                moduleName: resolvedTarget.c99name,
                publicHeadersDir: includeDir,
                fileSystem: fileSystem
            )
            let moduleMapType = moduleMapGenerator.determineModuleMapType()

            switch moduleMapType {
            case .custom, .umbrellaHeader, .umbrellaDirectory:
                let path = try constructGeneratedModuleMapPath(context: context)
                try generateModuleMapFile(context: context, moduleMapType: moduleMapType, outputPath: path)
                return path
            case .none:
                return nil
            }
        } else {
            let path = try constructGeneratedModuleMapPath(context: context)
            try generateModuleMapFile(context: context, moduleMapType: nil, outputPath: path)
            return path
        }
    }

    private func generateModuleMapContents(context: Context, moduleMapType: ModuleMapType?) throws -> String {
        if let moduleMapType {
            switch moduleMapType {
            case .custom(let customModuleMap):
                return try convertCustomModuleMapForFramework(customModuleMap)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            case .umbrellaHeader(let headerPath):
                return ([
                    "framework module \(context.resolvedTarget.c99name) {",
                    "    umbrella header \"\(headerPath.spmAbsolutePath.basename)\"",
                    "    export *",
                ]
                + generateLinkSection(context: context)
                + ["}"])
                .joined()
            case .umbrellaDirectory(let directoryPath):
                let headers = try walkDirectoryContents(of: directoryPath.absolutePath)
                let declarations = headers.map { header in
                    generateHeaderEntry(
                        for: header,
                        of: directoryPath.absolutePath,
                        keepPublicHeadersStructure: context.keepPublicHeadersStructure
                    )
                }

                return ([
                    "framework module \(context.resolvedTarget.c99name) {",
                ]
                + Array(declarations).sorted()
                + ["    export *"]
                + generateLinkSection(context: context)
                + ["}"])
                .joined()
            case .none:
                fatalError("Unsupported moduleMapType")
            }
        } else {
            let bridgingHeaderName = "\(context.resolvedTarget.name)-Swift.h"
            return ([
                "framework module \(context.resolvedTarget.c99name) {",
                "    header \"\(bridgingHeaderName)\"",
                "    export *",
                ]
                + generateLinkSection(context: context)
                + ["}"])
                .joined()
        }
    }

    private func walkDirectoryContents(of directoryPath: TSCAbsolutePath) throws -> Set<TSCAbsolutePath> {
        try fileSystem.getDirectoryContents(directoryPath).reduce(into: Set()) { headers, file in
            let path = directoryPath.appending(component: file)
            if fileSystem.isDirectory(path) {
                headers.formUnion(try walkDirectoryContents(of: path))
            } else if file.hasSuffix(".h") {
                headers.insert(path)
            }
        }
    }

    private func generateHeaderEntry(
        for header: TSCAbsolutePath,
        of directoryPath: TSCAbsolutePath,
        keepPublicHeadersStructure: Bool
    ) -> String {
        if keepPublicHeadersStructure {
            let subdirectoryComponents: [String] = if header.dirname.hasPrefix(directoryPath.pathString) {
                header.dirname.dropFirst(directoryPath.pathString.count)
                    .split(separator: "/")
                    .map(String.init)
            } else {
                []
            }

            let path = (subdirectoryComponents + [header.basename]).joined(separator: "/")
            return "    header \"\(path)\""
        } else {
            return "    header \"\(header.basename)\""
        }
    }

    private func generateLinkSection(context: Context) -> [String] {
        context.resolvedTarget.dependencies
            .compactMap(\.module?.c99name)
            .map { "    link framework \"\($0)\"" }
    }

    private func generateModuleMapFile(context: Context, moduleMapType: ModuleMapType?, outputPath: TSCAbsolutePath) throws {
        let dirPath = outputPath.parentDirectory
        try fileSystem.createDirectory(dirPath, recursive: true)

        let contents = try generateModuleMapContents(context: context, moduleMapType: moduleMapType)
        try fileSystem.writeFileContents(outputPath.spmAbsolutePath, string: contents)
    }

    private func constructGeneratedModuleMapPath(context: Context) throws -> TSCAbsolutePath {
        let generatedModuleMapPath = try packageLocator.generatedModuleMapPath(of: context.resolvedTarget, sdk: context.sdk)
        return generatedModuleMapPath
    }

    private func convertCustomModuleMapForFramework(_ customModuleMap: URL) throws -> String {
        // Sometimes, targets have their custom modulemaps.
        // However, these are not for frameworks
        // This process converts them to modulemaps for frameworks
        // like `module MyModule` to `framework module MyModule`
        let rawData = try fileSystem.readFileContents(customModuleMap.absolutePath).contents
        guard let contents = String(bytes: rawData, encoding: .utf8) else {
            throw Error.unableToLoadCustomModuleMap(customModuleMap.absolutePath)
        }
        // TODO: Use modern regex
        let regex = try NSRegularExpression(pattern: "^module", options: [])
        let replaced = regex.stringByReplacingMatches(in: contents,
                                                      range: NSRange(location: 0, length: contents.utf16.count),
                                                      withTemplate: "framework module")
        return replaced
    }
}

extension [String] {
    fileprivate func joined() -> String {
        joined(separator: "\n")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Name of the module map file recognized by the Clang and Swift compilers.

extension URL {
  fileprivate var moduleEscapedPathString: String {
      absoluteString.replacingOccurrences(of: "\\", with: "\\\\")
  }
}

public struct ModuleMapGenerator {
    private let moduleMapFilename = "module.modulemap"
    /// The name of the Clang target (for diagnostics).
    private let targetName: String

    /// The module name of the target.
    private let moduleName: String

    /// The target's public-headers directory.
    private let publicHeadersDir: URL

    /// The file system to be used.
    private let fileSystem: any FileSystem

    public init(targetName: String, moduleName: String, publicHeadersDir: URL, fileSystem: some FileSystem) {
        self.targetName = targetName
        self.moduleName = moduleName
        self.publicHeadersDir = publicHeadersDir
        self.fileSystem = fileSystem
    }

    /// Inspects the file system at the public-headers directory with which the module map generator was instantiated, and returns the type of module map that applies to that directory.  This function contains all of the heuristics that implement module map policy for package targets; other functions just use the results of this determination.
    public func determineModuleMapType() -> ModuleMapType {
        // First check for a custom module map.
        let customModuleMapFile = publicHeadersDir.appending(component: moduleMapFilename)
        if fileSystem.isFile(customModuleMapFile.absolutePath) {
            return .custom(customModuleMapFile)
        }

        // Warn if the public-headers directory is missing.  For backward compatibility reasons, this is not an error, we just won't generate a module map in that case.
        guard fileSystem.exists(publicHeadersDir.absolutePath) else {
            return .none
        }

        // Next try to get the entries in the public-headers directory.
        let entries: Set<AbsolutePath>
        do {
            let array = try fileSystem.getDirectoryContents(publicHeadersDir.absolutePath).map({ publicHeadersDir.appending(component: $0).spmAbsolutePath })
            entries = Set(array)
        }
        catch {
            // This might fail because of a file system error, etc.
            return .none
        }

        // Filter out headers and directories at the top level of the public-headers directory.
        // FIXME: What about .hh files, or .hpp, etc?  We should centralize the detection of file types based on names (and ideally share with SwiftDriver).
        let headers = entries.filter({ fileSystem.isFile($0) && $0.suffix == ".h" })
        let directories = entries.filter({ fileSystem.isDirectory($0) })

        // If 'PublicHeadersDir/ModuleName.h' exists, then use it as the umbrella header.
        let umbrellaHeader = publicHeadersDir.appending(component: moduleName + ".h")
        if fileSystem.isFile(umbrellaHeader.absolutePath) {
            // In this case, 'PublicHeadersDir' is expected to contain no subdirectories.
            if directories.count != 0 {
                return .none
            }
            return .umbrellaHeader(umbrellaHeader)
        }

        /// Check for the common mistake of naming the umbrella header 'TargetName.h' instead of 'ModuleName.h'.
        let misnamedUmbrellaHeader = publicHeadersDir.appending(component: targetName + ".h")

        // If 'PublicHeadersDir/ModuleName/ModuleName.h' exists, then use it as the umbrella header.
        let nestedUmbrellaHeader = publicHeadersDir.appending(components: moduleName, moduleName + ".h")
        if fileSystem.isFile(nestedUmbrellaHeader.absolutePath) {
            // In this case, 'PublicHeadersDir' is expected to contain no subdirectories other than 'ModuleName'.
            if directories.count != 1 {
                return .none
            }
            // In this case, 'PublicHeadersDir' is also expected to contain no header files.
            if headers.count != 0 {
                return .none
            }
            return .umbrellaHeader(nestedUmbrellaHeader)
        }

        /// Check for the common mistake of naming the nested umbrella header 'TargetName.h' instead of 'ModuleName.h'.
        let misnamedNestedUmbrellaHeader = publicHeadersDir.appending(components: moduleName, targetName + ".h")

        // Otherwise, if 'PublicHeadersDir' contains only header files and no subdirectories, use it as the umbrella directory.
        if headers.count == entries.count {
            return .umbrellaDirectory(publicHeadersDir)
        }

        // Otherwise, the module's public headers are considered to be incompatible with modules.  Per the original design, though, an umbrella directory is still created for them.  This will lead to build failures if those headers are included and they are not compatible with modules.  A future evolution proposal should revisit these semantics, especially to make it easier to existing wrap C source bases that are incompatible with modules.
        return .umbrellaDirectory(publicHeadersDir)
    }

    /// Generates a module map based of the specified type, throwing an error if anything goes wrong.  Any diagnostics are added to the receiver's diagnostics engine.
    public func generateModuleMap(type: GeneratedModuleMapType, at path: AbsolutePath) throws {
        var moduleMap = "module \(moduleName) {\n"
        switch type {
        case .umbrellaHeader(let hdr):
            moduleMap.append("    umbrella header \"\(hdr.moduleEscapedPathString)\"\n")
        case .umbrellaDirectory(let dir):
            moduleMap.append("    umbrella \"\(dir.moduleEscapedPathString)\"\n")
        }
        moduleMap.append(
            """
                export *
            }

            """
        )

        // FIXME: This doesn't belong here.
        try fileSystem.createDirectory(path.parentDirectory, recursive: true)

        // If the file exists with the identical contents, we don't need to rewrite it.
        // Otherwise, compiler will recompile even if nothing else has changed.
        if let contents = try? fileSystem.readFileContents(path).validDescription, contents == moduleMap {
            return
        }
        try fileSystem.writeFileContents(path, string: moduleMap)
    }
}


/// A type of module map to generate.
public enum GeneratedModuleMapType {
    case umbrellaHeader(URL)
    case umbrellaDirectory(URL)
}

public extension ModuleMapType {
    /// Returns the type of module map to generate for this kind of module map, or nil to not generate one at all.
    var generatedModuleMapType: GeneratedModuleMapType? {
        switch self {
        case .umbrellaHeader(let path): return .umbrellaHeader(path)
        case .umbrellaDirectory(let path): return .umbrellaDirectory(path)
        case .none, .custom(_): return nil
        }
    }
}

public enum ModuleMapType: Equatable {
    /// No module map file.
    case none
    /// A custom module map file.
    case custom(URL)
    /// An umbrella header included by a generated module map file.
    case umbrellaHeader(URL)
    /// An umbrella directory included by a generated module map file.
    case umbrellaDirectory(URL)
}

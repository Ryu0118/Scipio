import Foundation
import PackageManifestKit

struct _ModulesGraph {
    var rootPackage: _ResolvedPackage
    var allPackages: [_ResolvedPackage.ID: _ResolvedPackage]
    var allModules: Set<_ResolvedModule>

    func package(for module: _ResolvedModule) -> _ResolvedPackage? {
        allPackages[module.packageID]
    }
}

struct _ResolvedPackage: Identifiable {
    struct ID: Hashable {
        var description: String
        var packageIdentity: String

        init(
            packageKind: PackageKind,
            packageIdentity: String
        ) {
            self.packageIdentity = packageIdentity
            switch packageKind {
            case .root(let url), .fileSystem(let url), .localSourceControl(let url):
                description = url.absoluteString
            case .remoteSourceControl(let string):
                description = string
            case .registry(let string):
                description = string
            }
        }
    }

    var id: ID
    var manifest: Manifest
    var path: String
    var targets: [_ResolvedModule]
    var products: [_ResolvedProduct]
    var pinState: PackageResolved.Pin.State?

    var name: String {
        manifest.name
    }

    init(
        manifest: Manifest,
        packageIdentity: String,
        pinState: PackageResolved.Pin.State?,
        path: String,
        targets: [_ResolvedModule],
        products: [_ResolvedProduct]
    ) {
        self.id = ID(packageKind: manifest.packageKind, packageIdentity: packageIdentity)
        self.manifest = manifest
        self.pinState = pinState
        self.path = path
        self.targets = targets
        self.products = products
    }
}

extension _ResolvedPackage {
    var canonicalPackageLocation: CanonicalPackageLocation {
        CanonicalPackageLocation(self.path)
    }
}

struct _ResolvedModule: Hashable, Sendable {
    enum Dependency: Hashable, Identifiable {
        var id: String {
            switch self {
            case .module(let module, _):
                module.name
            case .product(let product, _):
                product.name + product.modules.map(\.name).joined()
            }
        }

        case module(_ResolvedModule, conditions: [PackageCondition])
        case product(_ResolvedProduct, conditions: [PackageCondition])

        var dependencies: [Dependency] {
            switch self {
            case .module(let module, _):
                return module.dependencies
            case .product(let product, _):
                return product.modules.map { .module($0, conditions: []) }
            }
        }

        var module: _ResolvedModule? {
            switch self {
            case .module(let module, _): return module
            case .product: return nil
            }
        }

        var product: _ResolvedProduct? {
            switch self {
            case .module: return nil
            case .product(let product, _): return product
            }
        }

        var moduleNames: [String] {
            let moduleNames = switch self {
            case .module(let module, _): [module.name]
            case .product(let product, _): product.modules.map(\.name)
            }
            return moduleNames
        }
    }

    var underlying: PackageManifestKit.Target
    var dependencies: [Dependency]
    var localPackageURL: URL
    var packageID: _ResolvedPackage.ID
    var resolvedModuleType: ResolvedModuleType

    var name: String {
        underlying.name
    }

    var c99name: String {
        name.spm_mangledToC99ExtendedIdentifier()
    }

    var xcFrameworkName: String {
        "\(c99name.packageNamed()).xcframework"
    }

    var modulemapName: String {
        "\(c99name.packageNamed()).modulemap"
    }

    func recursiveModuleDependencies() throws -> [_ResolvedModule] {
        try topologicalSort(self.dependencies) { $0.dependencies }.compactMap { $0.module }
    }

    public func recursiveDependencies() throws -> [Dependency] {
        try topologicalSort(self.dependencies) { $0.dependencies }
    }
}

enum ResolvedModuleType: Hashable {
    case clang(includeDir: URL)
    case binary(BinaryArtifactLocation)
    case swift

    var includeDir: URL? {
        switch self {
        case .clang(let includeDir):
            includeDir
        default: nil
        }
    }

    enum BinaryArtifactLocation: Hashable {
        case local(URL)
        case remote(packageIdentity: String, name: String)

        func localArtifactURL(rootPackageDirectory: URL) -> URL {
            switch self {
            case .local(let url):
                return url
            case .remote(let packageIdentity, let name):
//                let name = name.spm_mangledToC99ExtendedIdentifier()
                return rootPackageDirectory
                    .appending(components: ".build", "artifacts", packageIdentity, name, name)
                    .appendingPathExtension("xcframework")
            }
        }
    }
}

struct _ResolvedProduct: Hashable {
    var underlying: PackageManifestKit.Product
    var modules: [_ResolvedModule]
    var type: ProductType
    var packageID: _ResolvedPackage.ID

    var name: String {
        underlying.name
    }
}

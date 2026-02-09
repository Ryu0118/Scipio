import Foundation
@testable @_spi(Internals) import ScipioKit
@testable import ScipioKitCore
@testable import PackageManifestKit

func makeStubBuildProduct(targetName: String) -> BuildProduct {
    let packageURL = URL(filePath: "/tmp/foo-package")
    let packageKind = PackageKind.root(packageURL)
    let manifest = Manifest(
        name: "Foo",
        toolsVersion: .v6_0,
        pkgConfig: nil,
        providers: nil,
        cLanguageStandard: nil,
        cxxLanguageStandard: nil,
        swiftLanguageVersions: nil,
        dependencies: [],
        products: [],
        targets: [],
        traits: nil,
        platforms: nil,
        packageKind: packageKind,
        revision: nil,
        defaultLocalization: nil
    )
    let packageID = PackageID(
        packageKind: packageKind,
        packageIdentity: "foo-package"
    )
    let target = Target(
        name: targetName,
        packageAccess: false,
        path: nil,
        url: nil,
        sources: nil,
        resources: [],
        exclude: [],
        dependencies: [],
        publicHeadersPath: nil,
        type: .regular,
        pkgConfig: nil,
        providers: nil,
        pluginCapability: nil,
        settings: [],
        checksum: nil,
        pluginUsages: nil
    )
    let resolvedModule = ResolvedModule(
        underlying: target,
        dependencies: [],
        localPackageURL: packageURL,
        packageID: packageID,
        resolvedModuleType: .swift
    )
    let resolvedPackage = ResolvedPackage(
        manifest: manifest,
        resolvedPackageKind: packageKind,
        packageIdentity: "foo-package",
        pinState: nil,
        path: packageURL.path,
        targets: [resolvedModule],
        products: []
    )
    return BuildProduct(package: resolvedPackage, target: resolvedModule)
}

func makeStubBuildOptions(
    frameworkType: FrameworkType = .static,
    sdks: Set<SDK> = [.iOS],
    buildConfiguration: BuildConfiguration = .release
) -> BuildOptions {
    BuildOptions(
        buildConfiguration: buildConfiguration,
        isDebugSymbolsEmbedded: false,
        frameworkType: frameworkType,
        sdks: sdks,
        extraFlags: nil,
        extraBuildParameters: nil,
        enableLibraryEvolution: false,
        keepPublicHeadersStructure: false,
        customFrameworkModuleMapContents: nil,
        stripStaticDWARFSymbols: false
    )
}

func makeStubCacheTarget(
    targetName: String,
    buildOptions: BuildOptions
) -> CacheSystem.CacheTarget {
    CacheSystem.CacheTarget(
        buildProduct: makeStubBuildProduct(targetName: targetName),
        buildOptions: buildOptions
    )
}

import Foundation
import Testing
@testable import PIFKit

@Suite
struct TargetTests {
    @Test
    func canParseTarget() throws {
        let jsonData = try FixtureLoader.load(named: "Target.json")
        let target = try JSONDecoder().decode(Target.self, from: jsonData)

        #expect(target.name == "MyFrameworkTests_2713FB4B18606497_PackageProduct")
        #expect(target.buildConfigurations.count == 2)
        #expect(target.productType == .unitTest)
    }
}

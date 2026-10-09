// Created by Василий Маслов on 09.10.2026.
import Foundation
import Testing
@testable import MimicCore

struct BuildWorkflowTests {
    let project = ProjectContext(path: "/private/tmp/Fixture", branch: "main", commit: "a", developerDirectory: "/fixture/Developer", appleTarget: .init(path: "Fixture.xcodeproj"))
    var parameters: BuildParameters { .init(scheme: "Fixture", destinationID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA") }

    @Test func enumerationIsExplicitAndSelectedTestsAreExact() throws {
        var value = parameters; value.intent = .catalogue
        let command = try value.command(project: project, derivedDataPath: "/private/tmp/own", enumerationPath: "/private/tmp/tests.json")
        #expect(command.arguments.contains("-enumerate-tests")); #expect(command.arguments.contains("test"))
        #expect(!command.arguments.contains(where: { $0.hasPrefix("-only-testing:") }))
        value.intent = nil; value.operation = .test; value.testIdentifiers = ["FixtureTests/Checkout/testOne()", "FixtureTests/Checkout/testTwo()"]
        let tests = try value.command(project: project).arguments.filter { $0.hasPrefix("-only-testing:") }
        #expect(tests == value.testIdentifiers.map { "-only-testing:" + $0 })
        value.testIdentifiers = []; #expect(throws: BuildError.testsRequired) { try value.validate() }
    }
    @Test func hierarchicalEnumerationGroupsAndRejectsErrorPayloads() throws {
        let data = Data(#"{"values":[{"name":"Plan","children":[{"name":"FixtureTests","children":[{"name":"Checkout","children":[{"name":"testOne()"},{"name":"testTwo()"},{"name":"testOne()"}]}]}]}],"errors":[]}"#.utf8)
        let tests = try BuildTestCatalogue.parse(data)
        #expect(tests.map(\.id) == ["FixtureTests/Checkout/testOne()", "FixtureTests/Checkout/testTwo()"])
        #expect(tests.allSatisfy { $0.target == "FixtureTests" && $0.className == "Checkout" })
        #expect(throws: BuildError.catalogueResponse) { try BuildTestCatalogue.parse(Data(#"{"errors":["failure"],"values":[]}"#.utf8)) }
        #expect(throws: BuildError.catalogueResponse) { try BuildTestCatalogue.parse(Data(#"{"unrelated":[]}"#.utf8)) }
        #expect(try BuildTestCatalogue.parse(Data(#"{"values":[]}"#.utf8)).isEmpty)
    }
    @Test func catalogueIdentityIncludesRevisionToolchainSchemeDeviceAndConfiguration() {
        let catalogue = BuildTestCatalogue(project: project, developerDirectory: "/fixture/Developer", parameters: parameters, tests: [])
        #expect(catalogue.matches(project: project, parameters: parameters, developer: "/fixture/Developer"))
        var next = project; next.commit = "b"; #expect(!catalogue.matches(project: next, parameters: parameters, developer: "/fixture/Developer"))
        for changed in ["scheme", "device", "configuration"] {
            var value = parameters
            if changed == "scheme" { value.scheme = "Other" }; if changed == "device" { value.destinationID = UUID().uuidString }; if changed == "configuration" { value.configuration = "Release" }
            #expect(!catalogue.matches(project: project, parameters: value, developer: "/fixture/Developer"))
        }
        #expect(!catalogue.matches(project: project, parameters: parameters, developer: "/other/Developer"))
    }
    @Test func productsMustBelongToThisBuildAndSimulator() throws {
        let data = Data(#"[{"target":"App","buildSettings":{"WRAPPER_EXTENSION":"app","TARGET_BUILD_DIR":"/private/tmp/own/Build/Products/Debug-iphonesimulator","FULL_PRODUCT_NAME":"App.app","PRODUCT_BUNDLE_IDENTIFIER":"fixture.app","PLATFORM_NAME":"iphonesimulator"}},{"target":"Foreign","buildSettings":{"WRAPPER_EXTENSION":"app","TARGET_BUILD_DIR":"/private/tmp/foreign","FULL_PRODUCT_NAME":"Foreign.app","PRODUCT_BUNDLE_IDENTIFIER":"foreign.app","PLATFORM_NAME":"iphonesimulator"}}]"#.utf8)
        let products = try BuildProduct.parse(settings: data, derivedData: URL(fileURLWithPath: "/private/tmp/own"), exists: { _ in true })
        #expect(products.count == 1); #expect(products[0].bundleIdentifier == "fixture.app")
        #expect(throws: BuildError.configuration) { try BuildProduct.parse(settings: data, derivedData: URL(fileURLWithPath: "/private/tmp/different"), exists: { _ in true }) }
    }
    @Test func oldHistoryAndPublicRequestsStayCompatible() throws {
        let record = BuildActivity(project: project, parameters: parameters, source: "fixture")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        for field in ["stage", "products", "completedStages", "completedTestCount", "testCatalogue", "selectedProductID", "destinationName"] { json[field] = nil }
        let restored = try JSONDecoder().decode(BuildActivity.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.parameters.intent == nil); #expect(restored.status == .queued)
        #expect(!BuildBridge.tools.contains("panel_build_control")); #expect(PanelBridge.appTools.contains("panel_build_control"))
    }
    @Test func progressUsesOnlyObservedUniqueSelectedCompletions() {
        var progress = BuildTestProgress()
        let ids = ["FixtureTests/Checkout/testOne()", "FixtureTests/Checkout/testTwo()"]
        #expect(progress.append("Test Case '-[FixtureTests.Checkout testOne]' pas", selected: ids) == 0)
        #expect(progress.append("sed (0.1 seconds).\nTest Case '-[FixtureTests.Checkout testOne]' passed\n", selected: ids) == 1)
        #expect(progress.append("Test Case '-[FixtureTests.Checkout testUnknown]' passed\n", selected: ids) == 1)
        #expect(progress.append("Test Case '-[FixtureTests.Checkout testTwo]' failed\n", selected: ids) == 2)
        var record = BuildActivity(project: project, parameters: parameters, source: "fixture"); record.status = .running
        #expect(record.progressFraction == nil)
    }
}

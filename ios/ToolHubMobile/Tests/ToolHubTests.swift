import XCTest
@testable import ToolHub

final class ToolHubTests: XCTestCase {
    func testJSONPathHandlesNestedObjectsAndArrayIndices() throws {
        let value = try JSONDecoder().decode(JSON.self, from: Data(#"{"data":{"items":[{"name":"新工具"}],"ready":true}}"#.utf8))
        XCTAssertEqual(value.value(at: "$.data.items.0.name").text, "新工具")
        XCTAssertEqual(value.value(at: "$.data.items[0].name").text, "新工具")
        XCTAssertEqual(value.value(at: "$.data.items.100.name"), .null)
        XCTAssertTrue(value.value(at: "$.data.ready").bool)
    }
    func testInlineFieldsRenderAsUserFacingText() {
        let value: JSON = .object(["size": .number(100), "used": .number(25)])
        XCTAssertEqual(value.render("共 $.size 字节 · 已用 $.used 字节"), "共 100 字节 · 已用 25 字节")
        XCTAssertEqual(value.render("$.missing"), "—")
    }
    func testEmptyPostStillSendsJSONForProtectedAPIs() throws {
        let api = HubAPI(connection: Connection(server: "https://example.com", token: ""))
        let request = try api.request("/proxy/ddns/api/v1/update", method: "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-DDNS-Request"), "1")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
    }
    func testJSONRoundTripPreservesFormsAndComponents() throws {
        let source = Data(#"{"type":"form","fields":[{"name":"title","default":"hello"}],"count":42,"enabled":false}"#.utf8)
        let value = try JSONDecoder().decode(JSON.self, from: source)
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(value)), value)
    }
    func testGatewayURLKeepsPrefixAndRemovesQueryCredential() throws {
        let api = HubAPI(connection: Connection(server: "https://example.com/mobile", token: "local-test-only"))
        let url = try api.url("/files/photo.jpg?token=old&size=small")
        XCTAssertEqual(url.absoluteString, "https://example.com/mobile/files/photo.jpg?size=small")
        let request = try api.request("/api/v1/native/manifest")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-ToolHub-Token"), "local-test-only")
    }
    func testGatewayRejectsExternalOrTraversalEndpoints() {
        let api = HubAPI(connection: Connection(server: "https://example.com", token: ""))
        for path in ["https://evil.example/api", "//evil.example/api", "/proxy/../admin", "/proxy/%2e%2e/admin", "/proxy\\evil"] {
            XCTAssertThrowsError(try api.url(path), path)
        }
    }
    func testManifestAcceptsNewServerDefinedPluginWithoutCompiledID() throws {
        let source = Data(#"{"schemaVersion":2,"version":"next","plugins":[{"id":"never-compiled-before","name":"新增插件","subtitle":"","category":"工具","symbol":"sparkles","kind":"embedded","controllable":false,"configured":true,"pages":[{"title":"新页面","layout":[{"type":"stats","endpoint":"/proxy/new/api/state","items":[]}]}],"warnings":[]}]}"#.utf8)
        let catalog = try JSONDecoder().decode(Catalog.self, from: source)
        XCTAssertEqual(catalog.plugins.first?.id, "never-compiled-before")
        XCTAssertEqual(catalog.plugins.first?.pages.first?.layout.first?["type"].text, "stats")
    }
}

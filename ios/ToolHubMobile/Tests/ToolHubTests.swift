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
    func testBindingsPreserveTypesAndEncodePathParameters() {
        let row: JSON = .object(["id": .string("a/b&c"), "count": .number(4)])
        XCTAssertEqual(NativeBinding.endpoint("/proxy/test/{{id}}", row: row, fields: [:]), "/proxy/test/a%2Fb%26c")
        let value = NativeBinding.value(.object(["enabled": .string("$field.enabled"), "count": .string("$row.count")]), row: row, fields: ["enabled": .bool(true)])
        XCTAssertEqual(value["enabled"], .bool(true))
        XCTAssertEqual(value["count"], .number(4))
        XCTAssertEqual(NativeBinding.value(.string("$field.input"), row: row, fields: [:]), .string("$field.input"))
    }
    func testFormDefaultsAndValidationAvoidEmptyOrInvalidRequests() {
        let field: JSON = .object(["name": .string("watts"), "label": .string("功耗"), "type": .string("integer"), "required": .bool(true), "from": .string("$.missing"), "default": .number(150), "min": .number(50), "max": .number(250)])
        XCTAssertEqual(NativeBinding.fieldValue(field, row: .null, values: [:]), .number(150))
        XCTAssertNil(NativeBinding.validation(field, value: .number(150)))
        XCTAssertNotNil(NativeBinding.validation(field, value: .number(999)))
        XCTAssertNotNil(NativeBinding.validation(field, value: .number(150.5)))
        XCTAssertNotNil(NativeBinding.validation(field, value: .string("")))
    }
    func testHumanReadableStatusDoesNotDumpObjects() {
        XCTAssertEqual(NativeDisplay.text(.string("running"), field: .object(["format": .string("status")])), "运行中")
        XCTAssertEqual(NativeDisplay.text(.null, field: .null), "暂无数据")
    }
    func testResultAssetsKeepOriginalDownloadSeparateFromPreview() throws {
        let row = try JSONDecoder().decode(JSON.self, from: Data(#"{"id":"photo","title":"照片","url":"/api/preview/photo","download":"/api/original/photo","filename":"Photo.heic","kind":"image"}"#.utf8))
        let asset = try XCTUnwrap(NativeAsset.parse(row))
        XCTAssertEqual(asset.preview, "/api/preview/photo")
        XCTAssertEqual(asset.download, "/api/original/photo")
        XCTAssertEqual(asset.filename, "Photo.heic")
        XCTAssertNil(NativeAsset.parse(.object(["url": .string("https://other.example/photo")])) )
    }
    func testSearchResultsBuildPhotoAndVideoDownloadTemplates() throws {
        let spec: JSON = .object(["urlTemplate": .string("/api/v1/native/photos/{{id}}/preview"), "downloadTemplate": .string("/api/v1/native/photos/{{id}}/original"), "titlePath": .string("$.name")])
        let row: JSON = .object(["id": .string("abc"), "name": .string("Video.mp4"), "type": .string("VIDEO")])
        let asset = try XCTUnwrap(NativeAsset.parse(row, spec: spec))
        XCTAssertEqual(asset.download, "/api/v1/native/photos/abc/original")
        XCTAssertEqual(asset.kind, "video")
        XCTAssertEqual(asset.filename, "Video.mp4")
    }
    func testDynamicMultiSelectionSubmitsFileNamesInsteadOfEntireRecords() {
        let field: JSON = .object(["valuePath": .string("$.filename")])
        let option: JSON = .object(["filename": .string("scan-second.jpg"), "title": .string("第二页"), "url": .string("/files/scan-second.jpg")])
        XCTAssertEqual(NativeBinding.selectionValue(option, field: field), .string("scan-second.jpg"))
        XCTAssertEqual(NativeBinding.selectionValue(.object(["value": .string("device")]), field: .null), .string("device"))
    }

}

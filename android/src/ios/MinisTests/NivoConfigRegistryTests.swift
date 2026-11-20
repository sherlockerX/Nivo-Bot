import XCTest
@testable import Minis

/// 使用独立注册表和内存字段检查真实路径解析，不读取共享设置或凭据。
@MainActor
final class NivoConfigRegistryTests: XCTestCase {
    func testEveryAdvertisedDottedModelFieldCanBeResolvedAndRead() throws {
        let registry = ConfigRegistry()
        registry.register(ModelFixture())
        let advertised = registry.fields(forTopic: "models")
        XCTAssertFalse(advertised.isEmpty)
        for metadata in advertised {
            let field = try XCTUnwrap(registry.resolveField(path: metadata.path), metadata.path)
            XCTAssertEqual(try field.read(), .int(128_000))
        }
    }

    func testDottedWritablePathUpdatesExactlyTheAddressedField() throws {
        let registry = ConfigRegistry()
        let fixture = ModelFixture()
        registry.register(fixture)
        let path = "models.provider/deepseek-v4.1-flash.contextWindowOverride"
        let field = try XCTUnwrap(registry.resolveField(path: path))
        try field.write(.int(64_000))
        XCTAssertEqual(fixture.value, .int(64_000))
        XCTAssertNil(registry.resolveField(path: "models.provider/deepseek-v4.contextWindowOverride"))
        XCTAssertNil(registry.resolveField(path: "models.provider/deepseek-v4.1-flash.unknown"))
    }

    /// 模拟动态模型集合，只提供已注册身份及其准确字段路径。
    @MainActor private final class ModelFixture: ConfigCollection {
        let basePath = "models"
        let displayName = "Models"
        let description = "测试模型集合"
        let addPayloadSchema: ConfigValueSchema = .json
        var value = ConfigValue.int(128_000)

        func childIds() -> [String] { ["provider/deepseek-v4.1-flash"] }

        func fields(for id: String) -> [ConfigField] {
            guard childIds().contains(id) else { return [] }
            return [ClosureField(path: "models.\(id).contextWindowOverride",
                displayName: "Context window", description: "测试字段", valueSchema: .int(),
                risk: .normal, revertable: true, reader: { self.value }, writer: { self.value = $0 })]
        }

        func add(_ payload: ConfigValue) throws -> String { throw ConfigError.invalidValue("测试不允许新增") }
        func remove(id: String) throws { throw ConfigError.invalidValue("测试不允许删除") }
    }
}

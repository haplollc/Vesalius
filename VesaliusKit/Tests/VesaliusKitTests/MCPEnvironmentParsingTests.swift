import Testing
import VesaliusMCP

/// `MCPProfile` and `AlwaysLoadOverride` parse the two MCP environment variables. These cover the edge
/// cases: case and surrounding whitespace in the profile name, unknown and missing profiles, and the
/// always-load comma list (including `none`, unset/empty, and stray spaces or a trailing separator).
@Suite("MCP environment parsing")
struct MCPEnvironmentParsingTests {
    // MARK: - MCPProfile (VESALIUS_MCP_PROFILE)

    @Test("An unknown profile falls back to default and reports it through warn")
    func unknownProfileWarnsAndDefaults() {
        var warnings: [String] = []
        let profile = MCPProfile.from(
            environment: [MCPProfile.environmentKey: "yolo"],
            warn: { warnings.append($0) }
        )
        #expect(profile == .default)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("VESALIUS_MCP_PROFILE") == true)
        #expect(warnings.first?.contains("yolo") == true)
    }

    @Test("The profile name is trimmed and matched case-insensitively")
    func profileIgnoresWhitespaceAndCase() {
        var warnings: [String] = []
        let profile = MCPProfile.from(
            environment: [MCPProfile.environmentKey: " Lean "],
            warn: { warnings.append($0) }
        )
        #expect(profile == .lean)
        #expect(warnings.isEmpty)
    }

    @Test("A missing or empty profile is default, without warning")
    func missingOrEmptyProfileDefaultsSilently() {
        let environments: [[String: String]] = [
            [:],
            [MCPProfile.environmentKey: ""],
            [MCPProfile.environmentKey: "   "],
        ]
        for environment in environments {
            var warnings: [String] = []
            let profile = MCPProfile.from(environment: environment, warn: { warnings.append($0) })
            #expect(profile == .default)
            #expect(warnings.isEmpty)
        }
    }

    // MARK: - AlwaysLoadOverride (VESALIUS_MCP_ALWAYS_LOAD)

    @Test("`none` is an empty, non-nil override")
    func noneIsEmptySet() throws {
        let result = try #require(
            AlwaysLoadOverride.from(environment: [AlwaysLoadOverride.environmentKey: "none"])
        )
        #expect(result.isEmpty)
    }

    @Test("An unset or empty override leaves the gates in charge (nil)")
    func unsetOrEmptyIsNil() {
        #expect(AlwaysLoadOverride.from(environment: [:]) == nil)
        #expect(AlwaysLoadOverride.from(environment: [AlwaysLoadOverride.environmentKey: ""]) == nil)
        #expect(AlwaysLoadOverride.from(environment: [AlwaysLoadOverride.environmentKey: "   "]) == nil)
    }

    @Test("A comma list trims surrounding spaces and drops empty items")
    func commaListTrimsAndDropsEmpties() throws {
        let result = try #require(
            AlwaysLoadOverride.from(
                environment: [AlwaysLoadOverride.environmentKey: " usages, feature_map, "]
            )
        )
        #expect(result == ["usages", "feature_map"])
        #expect(!result.contains(""))
    }
}

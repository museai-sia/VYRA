import XCTest
@testable import VYRA

/// On-device PO token provider (pot_ondevice.py) plumbing tests.
///
/// What these prove, offline, in the simulator:
///  - registration: 'vyra:ondevice' is in yt-dlp's POT provider
///    registry (the in-process import registers it), and the
///    provider's is_available() is gated by its settings exactly
///    like the framework expects (off = inert, on = available).
///  - the full mint flow against a FAKE BotGuard VM (network steps
///    stubbed by the bridge fixture hook): the token that comes back
///    is minted for exactly the content binding yt-dlp computed
///    (the request's visitor data) — session binding is not invented
///    by the provider.
///  - the REAL BotGuard VM machinery in both JS environments the
///    app provides (persistent JavaScriptCore context and the
///    WKWebView page): a captured real challenge loads and produces
///    a snapshot response.
///
/// What these do NOT prove: Google's acceptance of a snapshot from
/// this environment (GenerateIT issuing a real integrity token).
/// CI IPs are bot-flagged and the acceptance environment is the
/// owner's device on his own line — the same split as extraction.
final class PotOnDeviceTests: XCTestCase {

    private static func fixtureURL(named name: String) -> URL? {
        let bundle = Bundle(for: PotOnDeviceTests.self)
        guard let enumerator = FileManager.default.enumerator(
            at: bundle.bundleURL, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    func testPotProbeRegistrationAndSettingsGating() async throws {
        try XCTSkipUnless(YtDlpRuntime.resourcesPresent, "Python resources not bundled in this build")
        _ = try await EmbeddedYtDlpEngine.shared.versions()
        let response = try YtDlpRuntime.shared.call(function: "pot_probe", arguments: [:])
        XCTAssertEqual(response.potOndeviceRegistered, true)
        XCTAssertEqual(response.potAvailableOff, false,
                       "provider must be inert without the enabled setting")
        XCTAssertEqual(response.potAvailableOn, true,
                       "provider must be available with enabled setting + _host present")
    }

    func testFakeVmMintFlowBindsTokenToVisitorData() async throws {
        try XCTSkipUnless(YtDlpRuntime.resourcesPresent, "Python resources not bundled in this build")
        _ = try await EmbeddedYtDlpEngine.shared.versions()
        let visitorData = "CgtIZWxsb0Zha2VEQVRB"
        let fakeInterpreter = """
            globalThis.__fakeBG = {
              a: function (program, cb) {
                var getMinter = function (integrityBytes) {
                  return Promise.resolve(function (bindingBytes) {
                    var prefix = 'FAKE-TOKEN:';
                    var out = new Uint8Array(prefix.length + bindingBytes.length);
                    for (var i = 0; i < prefix.length; i++) out[i] = prefix.charCodeAt(i);
                    out.set(bindingBytes, prefix.length);
                    return Promise.resolve(out);
                  });
                };
                var asyncSnapshot = function (cb2, args) {
                  args[2][0] = getMinter;
                  cb2('FAKE-SNAPSHOT-RESPONSE');
                };
                cb(asyncSnapshot, function(){}, function(){}, function(){});
                return [function (args) { return 'SYNC'; }];
              }
            };
            """
        let response = try YtDlpRuntime.shared.call(function: "pot_mint_fixture", arguments: [
            "mode": "fake_vm",
            "visitor_data": visitorData,
            "video_id": "dQw4w9WgXcQ",
            "fake_interpreter_js": fakeInterpreter,
            "generateit": ["ZmFrZS1pbnRlZ3JpdHktdG9rZW4", 3600, 300, NSNull()],
        ])
        let token = try XCTUnwrap(response.poToken, "fake-VM mint must return a token")
        let decoded = try XCTUnwrap(Self.base64URLDecode(token),
                                    "token must be base64url-decodable")
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self),
                       "FAKE-TOKEN:\(visitorData)",
                       "the minted token must be bound to the request's visitor data")
    }

    func testRealVmSnapshotInJavaScriptCore() async throws {
        try await assertRealVmSnapshot(backend: "jsc")
    }

    func testRealVmSnapshotInWebView() async throws {
        try await assertRealVmSnapshot(backend: "webview")
    }

    /// Loads the captured real BotGuard challenge in the requested
    /// JS backend and asserts the VM produces a snapshot response.
    /// `hasMinterFn` is reported but not asserted: whether the VM
    /// registers the WebPO minter depends on the environment's
    /// richness, which is exactly the on-device acceptance question.
    private func assertRealVmSnapshot(backend: String) async throws {
        try XCTSkipUnless(YtDlpRuntime.resourcesPresent, "Python resources not bundled in this build")
        _ = try await EmbeddedYtDlpEngine.shared.versions()
        let fixtureURL = try XCTUnwrap(
            Self.fixtureURL(named: "pot-challenge-fixture.json"),
            "POT challenge fixture missing from the test bundle")
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData) as? [String: Any],
            "POT challenge fixture is not a JSON object")
        var arguments: [String: Any] = [
            "mode": "real_vm",
            "backend": backend,
            "program": try XCTUnwrap(fixture["program"] as? String),
            "global_name": try XCTUnwrap(fixture["globalName"] as? String),
            "interpreter_js": try XCTUnwrap(fixture["interpreterJS"] as? String),
        ]
        if let ytCfg = fixture["ytCfg"] {
            arguments["yt_cfg"] = ytCfg
        }
        let response = try YtDlpRuntime.shared.call(
            function: "pot_mint_fixture", arguments: arguments)
        XCTAssertEqual(response.potBackend, backend)
        let snapshotLength = try XCTUnwrap(response.snapshotLen)
        XCTAssertGreaterThan(snapshotLength, 500,
                             "the real BotGuard VM must produce a snapshot response")
        print("POT real-VM snapshot (\(backend)): \(snapshotLength) chars, "
            + "hasMinterFn=\(response.potHasMinterFn ?? false)")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

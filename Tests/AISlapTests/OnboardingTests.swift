import XCTest
@testable import AISlap

final class OnboardingTests: XCTestCase {
    func testAccessibilityDetourResumesWithScreenshotsAfterRelaunch() {
        let name = "AISlapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var state = Onboarding.Permissions(accessibility: false, screen: false)
        var welcomes = 0
        var requests: [Onboarding.Action] = []
        func makeFlow() -> Onboarding.Flow {
            Onboarding.Flow(defaults: defaults, readPermissions: { state },
                welcome: { welcomes += 1 }, choose: { $0.accessibility ? .screen : .accessibility },
                request: { requests.append($0) })
        }
        let first = makeFlow()
        first.start()
        XCTAssertTrue(first.pending)
        XCTAssertEqual(requests, [.accessibility])
        state.accessibility = true
        let relaunched = makeFlow()
        relaunched.start()
        XCTAssertEqual(welcomes, 1)
        XCTAssertEqual(requests, [.accessibility, .screen])
        state.screen = true
        relaunched.resume()
        XCTAssertFalse(relaunched.pending)
        XCTAssertEqual(requests.count, 2)
    }

    func testReverseOrderAndRepeatedActivationDoNotLoop() {
        let name = "AISlapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var state = Onboarding.Permissions(accessibility: false, screen: false)
        var requests: [Onboarding.Action] = []
        let flow = Onboarding.Flow(defaults: defaults, readPermissions: { state }, welcome: {},
            choose: { $0.screen ? .accessibility : .screen }, request: { requests.append($0) })
        flow.start()
        flow.resume() // Returning without granting must not pop the same dialog again.
        XCTAssertEqual(requests, [.screen])
        state.screen = true
        flow.resume()
        XCTAssertEqual(requests, [.screen, .accessibility])
        state.accessibility = true
        flow.resume()
        XCTAssertFalse(flow.pending)
    }

    func testSkipPersistsAndExplicitSetupReopensIt() {
        let name = "AISlapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var choices = 0
        let flow = Onboarding.Flow(defaults: defaults,
            readPermissions: { .init(accessibility: false, screen: false) }, welcome: {},
            choose: { _ in choices += 1; return .skip },
            request: { _ in XCTFail("Skip must not request a permission") })
        flow.start()
        flow.start()
        flow.resume()
        XCTAssertEqual(choices, 1)
        XCTAssertFalse(flow.pending)
        flow.start(force: true)
        XCTAssertEqual(choices, 2)
    }
}

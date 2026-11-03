import Foundation
import Testing
import HeyBudsBluetooth
import HeyBudsProtocol
@testable import HeyBuds

/// The automatic filter is a heuristic, so the manual fallback must win and
/// must survive a restart.
@MainActor @Test func manualVisibilityOverridesAutomaticFilteringAndPersists() async throws {
    let suite="HeyBuds-manual-tests-"+UUID().uuidString
    let defaults=try #require(UserDefaults(suiteName:suite))
    defer { defaults.removePersistentDomain(forName:suite) }
    let automatic=DeviceCandidate(id:"auto",name:"OPPO Enco Free4",audioConnected:false,classicAddress:nil,family:.oppo)
    let filtered=DeviceCandidate(id:"manual",name:"我的耳机",audioConnected:false,classicAddress:nil,family:.huawei)
    var services=AppServices()
    services.monitor=nil
    services.discover={ _ in Discovery.Result(admitted:[automatic],rejected:[filtered]) }
    let catalog=try ModelCatalog()
    let app=AppModel(catalog:catalog,defaults:defaults,services:services)
    defer { app.stop() }

    await app.rescan()
    #expect(app.candidates.map(\.id) == ["auto"])
    #expect(app.hiddenDevices.map(\.id) == ["manual"])

    // A device the automatic check filtered out can be added back.
    app.setManualVisibility("manual",visible:true)
    #expect(Set(app.candidates.map(\.id)) == ["auto","manual"])
    #expect(app.hiddenDevices.isEmpty)

    // A device that was admitted by mistake can be hidden.
    app.setManualVisibility("auto",visible:false)
    #expect(app.candidates.map(\.id) == ["manual"])
    #expect(app.hiddenDevices.map(\.id) == ["auto"])

    // Both choices are stored, so a fresh instance starts the same way.
    let reloaded=AppModel(catalog:catalog,defaults:defaults,services:services)
    defer { reloaded.stop() }
    await reloaded.rescan()
    #expect(reloaded.candidates.map(\.id) == ["manual"])
    #expect(reloaded.hiddenDevices.map(\.id) == ["auto"])
}

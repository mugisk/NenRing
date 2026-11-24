import XCTest
@testable import NenRing

struct FixtureStorageTargetResolver: StorageTargetResolving {
    var appleServiceCount = 1
    var mediaUUID: String? = nil
    var unboundResolution: StorageTargetResolution? = nil
    func resolve(devicePath: String) -> StorageTargetResolution {
        if let unboundResolution { return unboundResolution }
        return .init(state: .matched, binding: .init(smartServiceID: 2, controllerEntryID: 1,
            wholeMediaID: 3, controllerClass: "AppleANS3NVMeController", wholeMediaCount: 1,
            appleSMARTServiceCount: appleServiceCount, mediaUUID: mediaUUID), reason: "fixture")
    }
}

/// The FTL scope cannot be pinned to one namespace, but the disk itself is known.
struct UnclearScopeStorageTargetResolver: StorageTargetResolving {
    func resolve(devicePath: String) -> StorageTargetResolution {
        StorageRegistrySelection.resolve(startID: 3, nodes: [
            StorageRegistryNode(id: 1, appleANS: true, controllerClass: "AppleANS3NVMeController"),
            StorageRegistryNode(id: 2, parents: [1], smartCapable: true),
            StorageRegistryNode(id: 3, parents: [2], wholeMedia: true),
            StorageRegistryNode(id: 4, parents: [2], wholeMedia: true)])
    }
}

final class StorageTargetBindingTests: XCTestCase {
    private func graph() -> [StorageRegistryNode] {
        [StorageRegistryNode(id: 1, appleANS: true, controllerClass: "AppleANS3NVMeController"),
         StorageRegistryNode(id: 2, parents: [1], smartCapable: true),
         StorageRegistryNode(id: 3, parents: [2], wholeMedia: true)]
    }

    func testSelectsDiskAncestryNotEnumerationOrder() throws {
        var nodes = graph()
        nodes += [StorageRegistryNode(id: 10, appleANS: true, controllerClass: "AppleANS3CGv2Controller"),
                  StorageRegistryNode(id: 11, parents: [10], smartCapable: true),
                  StorageRegistryNode(id: 12, parents: [11], wholeMedia: true)]
        for ordered in [nodes, Array(nodes.reversed())] {
            let selected = try XCTUnwrap(StorageRegistrySelection.resolve(startID: 3, nodes: ordered).binding)
            XCTAssertEqual(selected.smartServiceID, 2)
            XCTAssertEqual(selected.controllerEntryID, 1)
            XCTAssertEqual(selected.appleSMARTServiceCount, 2)
            XCTAssertEqual(StorageRegistrySelection.resolve(startID: 12, nodes: ordered).binding?.smartServiceID, 11)
        }
    }

    func testAliasesConvergeAndExternalDriveIsExcluded() {
        var nodes = graph()
        nodes += [StorageRegistryNode(id: 10, smartCapable: true),
                  StorageRegistryNode(id: 11, parents: [10], wholeMedia: true)]
        XCTAssertEqual(StorageRegistrySelection.resolve(startID: 2, nodes: nodes).binding,
                       StorageRegistrySelection.resolve(startID: 3, nodes: nodes).binding)
        XCTAssertNil(StorageRegistrySelection.resolve(startID: 11, nodes: nodes).binding)
        XCTAssertEqual(StorageRegistrySelection.resolve(startID: 3, nodes: nodes).binding?.appleSMARTServiceCount, 1)
    }

    func testDuplicatePhysicalUUIDsCannotShareHistoryIdentity() {
        var nodes = graph()
        nodes[2].mediaUUID = "same-uuid"
        nodes += [StorageRegistryNode(id: 10, appleANS: true),
                  StorageRegistryNode(id: 11, parents: [10], smartCapable: true),
                  StorageRegistryNode(id: 12, parents: [11], wholeMedia: true, mediaUUID: "same-uuid")]
        let resolution = StorageRegistrySelection.resolve(startID: 3, nodes: nodes)
        XCTAssertEqual(resolution.state, .ambiguous)
        XCTAssertFalse(resolution.recordsSMARTHistory)
        XCTAssertFalse(resolution.identifyingDisk(serialNumber: nil).recordsSMARTHistory)
        XCTAssertTrue(resolution.identifyingDisk(serialNumber: "unique-serial").recordsSMARTHistory)
        XCTAssertNil(resolution.identifyingDisk(serialNumber: "unique-serial").binding,
                     "a serial distinguishes SMART history but not controller-wide FTL scope")
    }

    func testUniqueDiskUUIDSurvivesUnclearControllerScope() {
        var nodes = graph()
        nodes[2].mediaUUID = "selected-disk"
        nodes += [StorageRegistryNode(id: 4, parents: [1], smartCapable: true),
                  StorageRegistryNode(id: 5, parents: [4], wholeMedia: true, mediaUUID: "other-disk")]
        let resolution = StorageRegistrySelection.resolve(startID: 3, nodes: nodes)
            .identifyingDisk(serialNumber: nil)
        XCTAssertEqual(resolution.state, .ambiguous)
        XCTAssertNil(resolution.binding)
        XCTAssertEqual(resolution.historyMediaUUID, "selected-disk")
        XCTAssertTrue(resolution.recordsSMARTHistory)

        nodes[2].mediaUUID = nil
        XCTAssertFalse(StorageRegistrySelection.resolve(startID: 3, nodes: nodes)
            .identifyingDisk(serialNumber: nil).recordsSMARTHistory)
    }

    func testMultipleNamespacesCyclesAndDuplicateIDsFailClosed() {
        var multiple = graph()
        multiple.append(StorageRegistryNode(id: 4, parents: [2], wholeMedia: true))
        XCTAssertEqual(StorageRegistrySelection.resolve(startID: 3, nodes: multiple).state, .ambiguous)
        var cycle = graph()
        cycle[0].parents = [3]
        XCTAssertNil(StorageRegistrySelection.resolve(startID: 3, nodes: cycle).binding)
        XCTAssertEqual(StorageRegistrySelection.resolve(startID: 3, nodes: graph() + [graph()[0]]).state, .ambiguous)
        var multiParent = graph()
        multiParent[2].parents = [1, 2]
        XCTAssertNil(StorageRegistrySelection.resolve(startID: 3, nodes: multiParent).binding)
        var sharedController = graph()
        sharedController += [StorageRegistryNode(id: 4, parents: [1], smartCapable: true),
                             StorageRegistryNode(id: 5, parents: [4], wholeMedia: true)]
        XCTAssertEqual(StorageRegistrySelection.resolve(startID: 3, nodes: sharedController).state, .ambiguous)
    }

    func testAPFSWholeMediaDoesNotCountAsAnotherPhysicalNamespace() {
        var nodes = graph()
        nodes += [StorageRegistryNode(id: 4, parents: [3], controllerClass: "AppleAPFSContainerScheme", synthesized: true),
                  StorageRegistryNode(id: 5, parents: [4], wholeMedia: true)]
        XCTAssertEqual(StorageRegistrySelection.resolve(startID: 3, nodes: nodes).binding?.wholeMediaCount, 1)
        XCTAssertNil(StorageRegistrySelection.resolve(startID: 5, nodes: nodes).binding)
    }

    func testProbeArgumentsBindFTLButNotOpaqueSnapshotRequests() throws {
        let binding = try XCTUnwrap(StorageRegistrySelection.resolve(startID: 3, nodes: graph()).binding)
        let root = URL(fileURLWithPath: "/tmp/out")
        for request in [ASPDirectProbeRequest.ftlAll, .ftlPerm] {
            let args = request.arguments(outputRootURL: root, targetBinding: binding)
            XCTAssertTrue(args.contains("--smart-service-id"))
            XCTAssertTrue(args.contains("--controller-id"))
            XCTAssertTrue(args.contains("--whole-media-id"))
        }
        XCTAssertFalse(ASPDirectProbeRequest.snapshotHeader.arguments(outputRootURL: root, targetBinding: binding)
            .contains("--smart-service-id"))
        XCTAssertEqual(LocalStorageTargetResolver.bsdName("/dev/rdisk12"), "disk12")
        XCTAssertNil(LocalStorageTargetResolver.bsdName("/dev/disk1s2"))
    }

    func testBoundProfilePropertiesAndLegacyContextCompatibility() throws {
        let profile = try XCTUnwrap(IORegistryProfileParser().parse(properties: [
            "Controller Characteristics": ["capacity": 256_000_000_000 as UInt64,
                "page-size": 16384, "sec-per-page": 4, "vendor-name": "Hynix",
                "dies-per-bus": [2, 3], "nand-marketing-name": "tlc_3d_g6"],
            "IOClass": "AppleANS3NVMeController"
        ], modelNumber: "APPLE SSD", capturedAt: Date()))
        XCTAssertEqual(profile.pageSize, 16384)
        XCTAssertEqual(profile.nandVendor, "Hynix")
        XCTAssertEqual(profile.diesPerBus, [2, 3])
        let legacy = try JSONDecoder().decode(CurrentDeviceContext.self, from: Data("{}".utf8))
        XCTAssertNil(legacy.targetBinding)
        let bound = CurrentDeviceContext(targetBinding: StorageRegistrySelection.resolve(startID: 3, nodes: graph()).binding)
        XCTAssertEqual(try JSONDecoder().decode(CurrentDeviceContext.self, from: JSONEncoder().encode(bound)), bound)
    }

    private func measurement() throws -> ASPToolDirectFTLMeasurement {
        try ASPToolDirectFTLMetadataParser().parse(text: """
        build=26A434
        contractBuild=25G83
        probeVersion=3
        service=GetNVMeSMARTInterface
        plugin_uuid=AA0FA6F9-C2D6-457F-B10B-59A13253292F
        interface_uuid=CCD1DB19-FD9A-4DAF-BF95-12454B230AB6
        kind=all
        vtable_offset=0x108
        input_arg=null
        role=ASP FTL all statistics
        euid=501
        captured_at_epoch=1800000000
        result=0
        response_bytes=16
        capacity_bytes=16
        elapsed_ms=1
        total_elapsed_ms=1
        format_status=unconfirmed
        smart_service_entry_id=2
        controller_entry_id=1
        whole_media_entry_id=3
        """
        )
    }

    func testMetadataBindingRejectsStaleTargetAndPreservesLocalProvenance() throws {
        let binding = try XCTUnwrap(StorageRegistrySelection.resolve(startID: 3, nodes: graph()).binding)
        let context = CurrentDeviceContext(capturedAt: Date(timeIntervalSince1970: 1800000000), targetBinding: binding)
        var bytes = Data()
        for var word in [UInt64(1) << 32 | 4, 100] {
            word = word.littleEndian
            bytes.append(contentsOf: withUnsafeBytes(of: &word) { Array($0) })
        }
        var metadata = try measurement()
        let parser = ASPToolDirectFTLParser()
        let parsed = try parser.parse(data: bytes, measurement: metadata, deviceContext: context)
        XCTAssertEqual(parsed.snapshot?.acquisitionBinding, binding)
        let snapshot = try XCTUnwrap(parsed.snapshot)
        var afterReboot = snapshot
        afterReboot.acquisitionBinding = StorageTargetBinding(smartServiceID: 200, controllerEntryID: 100,
            wholeMediaID: 300, controllerClass: binding.controllerClass, wholeMediaCount: 1,
            appleSMARTServiceCount: 1, mediaUUID: nil)
        XCTAssertEqual(ControllerWearSeriesIdentity(snapshot: snapshot), ControllerWearSeriesIdentity(snapshot: afterReboot))
        XCTAssertEqual(DeviceSeriesIdentity(snapshot: snapshot), DeviceSeriesIdentity(snapshot: afterReboot))
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(ASPToolDiagnosticsSnapshot.self, from: encoded).acquisitionBinding, binding)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "acquisitionBinding")
        XCTAssertNil(try JSONDecoder().decode(ASPToolDiagnosticsSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy)).acquisitionBinding)
        metadata.smartServiceEntryID = 99
        XCTAssertThrowsError(try parser.parse(data: bytes, measurement: metadata, deviceContext: context))
        metadata.smartServiceEntryID = nil
        metadata.controllerEntryID = nil
        metadata = ASPToolDirectFTLMeasurement(build: metadata.build, contractBuild: metadata.contractBuild,
            probeVersion: 2, service: metadata.service, pluginUUID: metadata.pluginUUID, interfaceUUID: metadata.interfaceUUID,
            kind: metadata.kind, vtableOffset: metadata.vtableOffset, inputArgument: metadata.inputArgument,
            role: metadata.role, effectiveUserID: metadata.effectiveUserID, capturedAt: metadata.capturedAt,
            resultCode: metadata.resultCode, responseBytes: metadata.responseBytes, capacityBytes: metadata.capacityBytes,
            elapsedMilliseconds: metadata.elapsedMilliseconds, totalElapsedMilliseconds: metadata.totalElapsedMilliseconds,
            formatStatus: metadata.formatStatus)
        XCTAssertNil(try parser.parse(data: bytes, measurement: metadata, deviceContext: context).snapshot?.acquisitionBinding)
    }

    func testOptInLiveSelectedTargetAndProfile() async throws {
        guard let path = ProcessInfo.processInfo.environment["NENRING_BINDING_TEST_DISK"] else {
            throw XCTSkip("Live registry inspection requires an explicit disk path; no private call is made")
        }
        let resolution = LocalStorageTargetResolver().resolve(devicePath: path)
        XCTAssertEqual(resolution.state, .matched, resolution.reason)
        let binding = try XCTUnwrap(resolution.binding)
        let profile = await IORegistryService().profile(modelNumber: "live-selected", forceRefresh: true, binding: binding)
        XCTAssertNotNil(profile)
        XCTAssertTrue(profile?.hasValues == true)
        XCTAssertNotNil(profile?.pageSize)
        XCTAssertNotNil(profile?.nandVendor)
        print("Selected-target inspection: \(resolution.state.rawValue), whole media=\(binding.wholeMediaCount), Apple SMART services=\(binding.appleSMARTServiceCount), profile=\(profile != nil)")
        if let probeRoot = ProcessInfo.processInfo.environment["NENRING_BINDING_PROBE_DIRECTORY"],
           let outputRoot = ProcessInfo.processInfo.environment["NENRING_BINDING_CAPTURE_DIRECTORY"] {
            let generator = ASPDirectProbeGenerator(probeDirectoryURL: URL(fileURLWithPath: probeRoot),
                outputRootURL: URL(fileURLWithPath: outputRoot))
            let captured = try generator.generate(request: .ftlAll, targetBinding: binding)
            XCTAssertTrue(captured.processSucceeded)
            let inspected = try ASPToolDirectFTLArtifactCollector().collect(from: captured.runDirectoryURL,
                deviceContext: CurrentDeviceContext(capturedAt: profile?.capturedAt, targetBinding: binding))
            XCTAssertEqual(inspected.snapshot?.acquisitionBinding, binding)
            XCTAssertNotNil(inspected.snapshot?.hostWrittenBytes)
            print("Bound FTL read and parse: success, local provenance retained; no monitoring history modified")
        }
    }

    func testUnclearFTLScopeKeepsSMARTHistoryButWithholdsFTL() {
        let resolution = UnclearScopeStorageTargetResolver().resolve(devicePath: "/dev/disk0")
        XCTAssertEqual(resolution.state, .ambiguous)
        XCTAssertNil(resolution.binding)
        XCTAssertTrue(resolution.recordsSMARTHistory, "an unclear FTL scope alone must not stop SMART history")
        XCTAssertFalse(StorageTargetResolution(state: .ambiguous, binding: nil, reason: "", identityAmbiguous: true)
            .recordsSMARTHistory)
    }

    func testOnlyServicesBehindAnAppleControllerAreWalked() {
        var nodes: [UInt64: StorageRegistryNode] = [:]
        for node in graph() { nodes[node.id] = node }
        nodes[10] = StorageRegistryNode(id: 10, smartCapable: true) // third-party NVMe, no Apple ancestor
        nodes[20] = StorageRegistryNode(id: 20, parents: [21])
        nodes[21] = StorageRegistryNode(id: 21, parents: [20])      // a cycle must still end
        XCTAssertTrue(StorageRegistrySelection.isBehindAppleController(2, in: nodes))
        XCTAssertTrue(StorageRegistrySelection.isBehindAppleController(3, in: nodes))
        XCTAssertFalse(StorageRegistrySelection.isBehindAppleController(10, in: nodes))
        XCTAssertFalse(StorageRegistrySelection.isBehindAppleController(20, in: nodes))
        XCTAssertFalse(StorageRegistrySelection.isBehindAppleController(99, in: nodes))
    }

    func testDirectFTLReadIsRefusedWithoutAMatchingBinding() {
        let binding = StorageTargetBinding(smartServiceID: 2, controllerEntryID: 1, wholeMediaID: 3,
            controllerClass: "AppleANS3NVMeController", wholeMediaCount: 1, appleSMARTServiceCount: 1, mediaUUID: nil)
        XCTAssertTrue(DashboardModel.readMatchesBinding(smartServiceID: 2, controllerID: 1, wholeMediaID: 3, binding: binding))
        XCTAssertFalse(DashboardModel.readMatchesBinding(smartServiceID: 2, controllerID: 1, wholeMediaID: 4, binding: binding))
        XCTAssertFalse(DashboardModel.readMatchesBinding(smartServiceID: nil, controllerID: nil, wholeMediaID: nil, binding: binding))
        XCTAssertFalse(DashboardModel.readMatchesBinding(smartServiceID: 2, controllerID: 1, wholeMediaID: 3, binding: nil),
                       "a missing binding refuses instead of skipping the check")
    }
}

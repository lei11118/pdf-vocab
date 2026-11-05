import XCTest
import UIKit
@testable import PdfVocab

final class InteractionRebuildTests: XCTestCase {
    func testFourInitialToolsAndHorizontalTilt() {
        for count in 0...12 {
            let g = ToolArcGeometry(anchor:CGPoint(x:450,y:450),bounds:CGSize(width:900,height:900),count:count)
            XCTAssertEqual(g.initialRange.count,min(count,4))
            XCTAssertEqual(g.mid, -53 * .pi / 180,accuracy:0.0001)
            XCTAssertEqual(ToolArcConfig.sweep,108 * .pi / 180,accuracy:0.0001)
            if count >= 4 {
                let first = g.position(g.initialRange.lowerBound,count:count,upper:false)
                let last = g.position(g.initialRange.upperBound-1,count:count,upper:false)
                let tilt = atan2(last.y-first.y,last.x-first.x)
                XCTAssertEqual(tilt,g.mid,accuracy:0.0001)
            }
        }
    }
    func testToolPositionsHitAcrossAngleWrapAndBothHands() {
        for width:CGFloat in [420,834,1194] {
            for left in [false,true] {
                for count in 1...12 {
                    let g = ToolArcGeometry(anchor:CGPoint(x:20,y:20),bounds:CGSize(width:width,height:900),count:count,leftHanded:left)
                    for index in 0..<7 {
                        let p = g.position(index,count:7,upper:true)
                        XCTAssertEqual(g.index(at:p,count:7,upper:true),index)
                        XCTAssertGreaterThanOrEqual(p.x,ToolArcConfig.diameter/2)
                        XCTAssertLessThanOrEqual(p.x,width-ToolArcConfig.diameter/2)
                    }
                    for index in 0..<count {
                        let p = g.position(index,count:count,upper:false)
                        XCTAssertEqual(g.index(at:p,count:count,upper:false),index)
                        XCTAssertGreaterThanOrEqual(p.x,ToolArcConfig.diameter/2)
                        XCTAssertLessThanOrEqual(p.x,width-ToolArcConfig.diameter/2)
                    }
                }
            }
        }
    }
    func testMoreThanTwelveToolsRemainDistinctAndReachable() {
        for width:CGFloat in [834,1194] {
            let bounds = CGSize(width:width,height:900)
            XCTAssertGreaterThanOrEqual(ToolArcConfig.visibleToolCapacity(in:bounds),32)
            for left in [false,true] {
                for count in [13,20,32] {
                    let geometry = ToolArcGeometry(anchor:CGPoint(x:width/2,y:450),bounds:bounds,count:count,leftHanded:left)
                    var previous:CGPoint?
                    for index in 0..<count {
                        let point = geometry.position(index,count:count,upper:false)
                        XCTAssertEqual(geometry.index(at:point,count:count,upper:false),index)
                        XCTAssertGreaterThanOrEqual(point.x,ToolArcConfig.diameter/2)
                        XCTAssertLessThanOrEqual(point.x,width-ToolArcConfig.diameter/2)
                        XCTAssertGreaterThanOrEqual(point.y,ToolArcConfig.diameter/2)
                        XCTAssertLessThanOrEqual(point.y,bounds.height-ToolArcConfig.diameter/2)
                        if let previous { XCTAssertGreaterThan(hypot(point.x-previous.x,point.y-previous.y),ToolArcConfig.diameter) }
                        previous = point
                    }
                }
            }
        }
    }
    func testFullDefinitionNeverDropsLateSources() {
        let definitions = (1...100).map { "【source\($0)】meaning\($0)" }.joined(separator:"\n")
        let e = DictEntry(word:"test",phonetic:"test",translation:definitions,definition:"English definition",pos:nil,collins:0,oxford:false,tags:[],bnc:0,frq:0)
        let text = WordInteraction.fullDetail(e)
        XCTAssertTrue(text.contains(definitions))
        XCTAssertTrue(text.contains("English definition"))
    }
    @MainActor func testSqueezeOnlyAcceptsOneDeliveryPerPhysicalGesture() {
        let gate = ReaderSqueezeGate()
        XCTAssertTrue(gate.accept(at:10))
        XCTAssertFalse(gate.accept(at:10.01))
        XCTAssertTrue(gate.accept(at:10.2))
    }

    func testArcToolSettingsMigratePersistAndProtectTheLastTool() {
        let suite = "InteractionRebuildTests.ArcTools.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(PencilToolKind.eraser.rawValue, forKey: "pencilHiddenTools")
        let legacyPresetData = Data("legacy preset blob".utf8)
        defaults.set(legacyPresetData, forKey: "pencil.customPresets.v1")

        let session = PencilToolSession(defaults: defaults)
        let migrated = PencilToolKind.allCases.filter { $0 != .eraser }
        XCTAssertEqual(session.arcToolKinds, migrated)

        let previousHiddenSet = session.hiddenSet
        session.addArcTool(.eraser)
        session.moveArcTools(from: IndexSet(integer: session.arcToolKinds.count - 1), to: 0)
        session.removeArcTools(at: IndexSet(integer: 1))
        let savedOrder = session.arcToolKinds
        XCTAssertEqual(session.hiddenSet, previousHiddenSet)
        XCTAssertEqual(defaults.string(forKey: "pencil.arcTools.v1"), savedOrder.map(\.rawValue).joined(separator: ","))
        XCTAssertEqual(defaults.data(forKey: "pencil.customPresets.v1"), legacyPresetData)
        XCTAssertEqual(session.arcItems.map(\.id), savedOrder.map(\.rawValue))

        let restored = PencilToolSession(defaults: defaults)
        XCTAssertEqual(restored.arcToolKinds, savedOrder)
        restored.removeArcTools(at: IndexSet(integersIn: 0..<restored.arcToolKinds.count))
        XCTAssertEqual(restored.arcToolKinds.count, 1)
        XCTAssertTrue(defaults.data(forKey: "pencil.customPresets.v1") == legacyPresetData)
    }

    func testCustomWidthDecodesLegacyPrefsAndRejectsInvalidValues() throws {
        let legacy = try JSONDecoder().decode(PencilToolPrefs.self, from: Data(#"{"widthIndex":3}"#.utf8))
        XCTAssertEqual(legacy.widthIndex, 3)
        XCTAssertNil(legacy.customWidth)

        let invalid = try JSONDecoder().decode(
            PencilToolPrefs.self,
            from: Data(#"{"widthIndex":1,"customWidth":"not-a-number"}"#.utf8)
        )
        XCTAssertEqual(invalid.widthIndex, 1)
        XCTAssertNil(invalid.customWidth)

        var nonFinite = PencilToolPrefs()
        nonFinite.customWidth = CGFloat.infinity
        let encoded = try JSONEncoder().encode(nonFinite)
        XCTAssertNil(try JSONDecoder().decode(PencilToolPrefs.self, from: encoded).customWidth)
        XCTAssertEqual(PencilMetrics.width(kind: .pen, index: 3, customWidth: CGFloat.nan), PencilMetrics.width(kind: .pen, index: 3))
        XCTAssertEqual(PencilMetrics.width(kind: .shape, index: 2, customWidth: 4.3), 4.3)
        XCTAssertEqual(PencilMetrics.width(kind: .pen, index: 2, customWidth: 1000), 18)
        XCTAssertNil(PencilMetrics.customWidthRange(kind: .laser))
        XCTAssertNil(PencilMetrics.customWidthRange(kind: .eraser))
    }

    func testCustomWidthPersistsPerToolAndQuickPresetsClearTheOverride() {
        let suite = "InteractionRebuildTests.CustomWidth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let session = PencilToolSession(defaults: defaults)
        session.setCustomWidth(2.7)
        XCTAssertEqual(session.width, 2.7, accuracy: 0.0001)
        XCTAssertEqual(session.state.width, 2.7, accuracy: 0.0001)

        session.select(kind: .marker)
        XCTAssertNil(session.customWidth)
        session.setCustomWidth(31.4)
        session.select(kind: .pen)
        XCTAssertEqual(session.width, 2.7, accuracy: 0.0001)

        session.setWidth(0)
        XCTAssertNil(session.customWidth)
        XCTAssertEqual(session.width, PencilMetrics.width(kind: .pen, index: 0), accuracy: 0.0001)
        session.setCustomWidth(CGFloat.infinity)
        XCTAssertNil(session.customWidth)
        session.setCustomWidth(1000)
        XCTAssertEqual(session.width, 18, accuracy: 0.0001)

        let restored = PencilToolSession(defaults: defaults)
        XCTAssertEqual(restored.width, 18, accuracy: 0.0001)
        restored.select(kind: .marker)
        XCTAssertEqual(restored.width, 31.4, accuracy: 0.0001)
    }
}

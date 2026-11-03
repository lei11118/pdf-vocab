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
}

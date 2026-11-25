import XCTest
@testable import DrawBotSystem

final class SiteDetectorTests: XCTestCase {
    func testHostFromURL() {
        XCTAssertEqual(SiteDetector.host(fromURL: "https://paintz.app/"), "paintz.app")
        XCTAssertEqual(SiteDetector.host(fromURL: "https://www.Paint.Sumo.app/editor?x=1#y"), "paint.sumo.app")
        XCTAssertEqual(SiteDetector.host(fromURL: "http://localhost:8080/"), "localhost")
        XCTAssertNil(SiteDetector.host(fromURL: "about:blank"))
        XCTAssertNil(SiteDetector.host(fromURL: "file:///Users/x/a.html"))
        XCTAssertNil(SiteDetector.host(fromURL: "not a url"))
    }

    func testSiteNameFromWindowTitle() {
        XCTAssertEqual(SiteDetector.siteName(fromTitle: "untitled.png - PaintZ — Zen Browser", appName: "Zen"), "PaintZ")
        XCTAssertEqual(SiteDetector.siteName(fromTitle: "untitled.png - PaintZ", appName: "Zen"), "PaintZ")
        XCTAssertEqual(SiteDetector.siteName(fromTitle: "Paint — Mozilla Firefox", appName: "Firefox"), "Paint")
        XCTAssertEqual(SiteDetector.siteName(fromTitle: "My drawing | Kleki - Google Chrome", appName: "Google Chrome"), "Kleki")
        XCTAssertEqual(SiteDetector.siteName(fromTitle: "Paint", appName: "Safari"), "Paint")
        XCTAssertNil(SiteDetector.siteName(fromTitle: "", appName: "Safari"))
    }
}

import Cocoa
import XCTest
@testable import Open_Foresight

class RunnerTests: XCTestCase {

  func testRecurringOccurrencesHaveDistinctStableIDs() {
    let first = Date(timeIntervalSince1970: 1_785_000_000)
    let next = first.addingTimeInterval(7 * 24 * 60 * 60)
    let firstID = MacOSMeetingsBridge.eventID(
      calendarID: "work", externalID: "series", occurrence: first)
    XCTAssertEqual(firstID, MacOSMeetingsBridge.eventID(
      calendarID: "work", externalID: "series", occurrence: first))
    XCTAssertNotEqual(firstID, MacOSMeetingsBridge.eventID(
      calendarID: "work", externalID: "series", occurrence: next))
    XCTAssertNotEqual(firstID, MacOSMeetingsBridge.eventID(
      calendarID: "personal", externalID: "series", occurrence: first))
  }

  func testCalendarMeetingLinksRequireRecognizedHTTPSRoutes() {
    for address in [
      "https://meet.google.com/abc-defg-hij",
      "https://university.zoom.us/j/123456789",
      "https://teams.microsoft.com/l/meetup-join/19%3Ameeting",
    ] {
      XCTAssertTrue(MacOSMeetingsBridge.isMeetingURL(URL(string: address)!), address)
    }
    for address in [
      "https://meet.google.com.example.com/abc-defg-hij",
      "https://help.zoom.us/articles/meeting-help",
      "https://teams.microsoft.com@evil.example/meet/123456",
      "http://meet.google.com/abc-defg-hij",
    ] {
      XCTAssertFalse(MacOSMeetingsBridge.isMeetingURL(URL(string: address)!), address)
    }
  }

  func testAudioProcessMatchesUseBundleBoundaries() {
    XCTAssertEqual(CallApplication.matching("com.microsoft.teams2")?.kind, "native")
    XCTAssertEqual(CallApplication.matching("com.google.Chrome.helper")?.id, "com.google.chrome")
    XCTAssertEqual(CallApplication.matching("com.google.Chrome.helper")?.kind, "browser")
    XCTAssertNil(CallApplication.matching("com.google.chromedriver"))
    XCTAssertNil(CallApplication.matching("com.apple.WebKit.WebContent"))
  }

  func testAudioProcessActivityMergesByAppAndRequiresInput() throws {
    let chrome = try XCTUnwrap(CallApplication.matching("com.google.Chrome"))
    let helper = try XCTUnwrap(CallApplication.matching("com.google.Chrome.helper"))
    let edge = try XCTUnwrap(CallApplication.matching("com.microsoft.edgemac"))
    let zoom = try XCTUnwrap(CallApplication.matching("us.zoom.xos"))
    let active = CallApplication.activeApplications(from: [
      .init(app: chrome, inputActive: true, outputActive: false),
      .init(app: helper, inputActive: false, outputActive: true),
      .init(app: edge, inputActive: false, outputActive: true),
      .init(app: zoom, inputActive: true, outputActive: false),
    ])
    XCTAssertEqual(active.compactMap { $0["id"] as? String }, [chrome.id, zoom.id])
    XCTAssertEqual(active.compactMap { $0["outputActive"] as? Bool }, [true, false])
  }

}

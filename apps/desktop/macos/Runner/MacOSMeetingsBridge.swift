import AppKit
import CoreAudio
import CryptoKit
import EventKit
import FlutterMacOS

final class MacOSMeetingsBridge {
  private let channel: FlutterMethodChannel
  private lazy var calendar = EKEventStore()
  private let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "open_foresight/macos_meetings", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "calendarAccess":
        result(self.calendarAccess)
      case "requestCalendarAccess":
        self.requestCalendarAccess(result)
      case "upcomingMeetings":
        result(self.upcomingMeetings())
      case "activeCallApps":
        if let applications = CallApplication.activeApplications() {
          result(applications)
        } else {
          result(FlutterError(
            code: "call_detection_unavailable",
            message: "Unable to read audio process activity.",
            details: nil))
        }
      case "requestCallAttention":
        if !NSApp.isActive { _ = NSApp.requestUserAttention(.informationalRequest) }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private var calendarAccess: String {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .fullAccess: return "fullAccess"
    case .writeOnly: return "writeOnly"
    @unknown default: return "unavailable"
    }
  }

  private func requestCalendarAccess(_ result: @escaping FlutterResult) {
    let access = calendarAccess
    if access != "notDetermined" && access != "writeOnly" {
      result(access == "fullAccess")
      return
    }
    calendar.requestFullAccessToEvents { granted, error in
      DispatchQueue.main.async {
        if let error = error {
          result(FlutterError(code: "calendar_access", message: error.localizedDescription, details: nil))
        } else {
          result(granted)
        }
      }
    }
  }

  private func upcomingMeetings(now: Date = Date()) -> [[String: Any]] {
    guard calendarAccess == "fullAccess" else { return [] }
    let horizon = now.addingTimeInterval(7 * 24 * 60 * 60)
    let predicate = calendar.predicateForEvents(
      withStart: now.addingTimeInterval(-24 * 60 * 60), end: horizon, calendars: nil)
    return calendar.events(matching: predicate)
      .filter { event in
        guard let start = event.startDate, let end = event.endDate else { return false }
        return !event.isAllDay && event.status != .canceled && start < horizon && end > now
      }
      .sorted { $0.startDate < $1.startDate }
      .compactMap { event in
        guard let start = event.startDate, let end = event.endDate,
          let calendarID = event.calendar?.calendarIdentifier
        else { return nil }
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let externalID = event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier
        var meeting: [String: Any] = [
          "id": Self.eventID(calendarID: calendarID, externalID: externalID, occurrence: event.occurrenceDate),
          "title": title.isEmpty ? "Untitled meeting" : title,
          "startMs": Self.epochMilliseconds(start),
          "endMs": Self.epochMilliseconds(end),
        ]
        if let link = meetingLink(event) { meeting["joinUrl"] = link.absoluteString }
        return meeting
      }
  }

  static func eventID(calendarID: String, externalID: String, occurrence: Date?) -> String {
    // EventKit preserves the original occurrence date if a recurring meeting is rescheduled.
    let key = [calendarID, externalID, occurrence.map { String(epochMilliseconds($0)) } ?? ""]
      .map { "\($0.utf8.count):\($0)" }.joined()
    return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func epochMilliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
  }

  private func meetingLink(_ event: EKEvent) -> URL? {
    if let url = event.url, Self.isMeetingURL(url) { return url }
    for field in [event.location, event.notes] {
      guard let text = field, let detector = linkDetector else { continue }
      let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
      if let url = matches.compactMap(\.url).first(where: Self.isMeetingURL) { return url }
    }
    return nil
  }

  static func isMeetingURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
      let host = url.host?.lowercased(), url.path.count > 1
    else { return false }
    func onDomain(_ domain: String) -> Bool {
      host == domain || host.hasSuffix("." + domain)
    }
    let path = url.path.lowercased()
    if host == "meet.google.com" {
      return path.hasPrefix("/lookup/") ||
        path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}/?$"#, options: .regularExpression) != nil
    }
    if host == "teams.microsoft.com" || host == "teams.live.com" {
      return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/")
    }
    if onDomain("zoom.us") || onDomain("zoomgov.com") {
      return ["/j/", "/my/", "/w/", "/s/", "/wc/"].contains { path.hasPrefix($0) }
    }
    return onDomain("webex.com") || host == "meet.goto.com" || onDomain("whereby.com")
  }
}

struct CallApplication {
  let id: String
  let name: String
  let kind: String

  struct Activity {
    let app: CallApplication
    let inputActive: Bool
    let outputActive: Bool
  }

  private static let supported = [
    Self(id: "us.zoom.xos", name: "Zoom", kind: "native"),
    Self(id: "com.microsoft.teams", name: "Microsoft Teams", kind: "native"),
    Self(id: "com.microsoft.teams2", name: "Microsoft Teams", kind: "native"),
    Self(id: "com.cisco.webexmeetingsapp", name: "Webex", kind: "native"),
    Self(id: "com.cisco.webex", name: "Webex", kind: "native"),
    Self(id: "com.webex.meetingmanager", name: "Webex", kind: "native"),
    Self(id: "com.apple.facetime", name: "FaceTime", kind: "native"),
    Self(id: "com.tinyspeck.slackmacgap", name: "Slack", kind: "native"),
    Self(id: "com.hnc.discord", name: "Discord", kind: "native"),
    Self(id: "com.apple.safari", name: "Safari", kind: "browser"),
    Self(id: "com.google.chrome", name: "Google Chrome", kind: "browser"),
    Self(id: "com.microsoft.edgemac", name: "Microsoft Edge", kind: "browser"),
    Self(id: "org.mozilla.firefox", name: "Firefox", kind: "browser"),
    Self(id: "com.brave.browser", name: "Brave", kind: "browser"),
    Self(id: "company.thebrowser.browser", name: "Arc", kind: "browser"),
  ]

  static func matching(_ bundleID: String) -> Self? {
    let lower = bundleID.lowercased()
    // WebRTC and Electron often own the input stream in a child process.
    return supported.first { lower == $0.id || lower.hasPrefix($0.id + ".") }
  }

  static func activeApplications() -> [[String: Any]]? {
    guard let processes = processObjects() else { return nil }
    return activeApplications(from: processes.compactMap(processActivity))
  }

  static func activeApplications(from processes: [Activity]) -> [[String: Any]] {
    var applications: [String: Activity] = [:]
    for process in processes {
      let id = process.app.id
      let previous = applications[id]
      applications[id] = Activity(
        app: process.app,
        inputActive: process.inputActive || previous?.inputActive == true,
        outputActive: process.outputActive || previous?.outputActive == true)
    }
    return applications.values.filter(\.inputActive).sorted { $0.app.id < $1.app.id }.map {
      ["id": $0.app.id, "name": $0.app.name, "kind": $0.app.kind, "outputActive": $0.outputActive]
    }
  }

  private static func processObjects() -> [AudioObjectID]? {
    var address = property(kAudioHardwarePropertyProcessObjectList)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
    let stride = MemoryLayout<AudioObjectID>.stride
    guard Int(size) % stride == 0 else { return nil }
    if size == 0 { return [] }
    var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / stride)
    let status = objects.withUnsafeMutableBytes { buffer in
      AudioObjectGetPropertyData(system, &address, 0, nil, &size, buffer.baseAddress!)
    }
    guard status == noErr else { return nil }
    return Array(objects.prefix(Int(size) / stride))
  }

  private static func processActivity(_ object: AudioObjectID) -> Activity? {
    let input = isActive(object, kAudioProcessPropertyIsRunningInput)
    let output = isActive(object, kAudioProcessPropertyIsRunningOutput)
    guard input || output, let app = application(for: object) else { return nil }
    return Activity(app: app, inputActive: input, outputActive: output)
  }

  private static func isActive(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
    var address = property(selector)
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout.size(ofValue: running))
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr &&
      running == 1
  }

  private static func application(for object: AudioObjectID) -> Self? {
    var address = property(kAudioProcessPropertyBundleID)
    var bundle: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout.size(ofValue: bundle))
    if AudioObjectGetPropertyData(object, &address, 0, nil, &size, &bundle) == noErr,
      let identifier = bundle?.takeRetainedValue() as String?, let app = matching(identifier)
    { return app }

    address.mSelector = kAudioProcessPropertyPID
    var pid: pid_t = 0
    size = UInt32(MemoryLayout.size(ofValue: pid))
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr,
      pid > 0, let identifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    else { return nil }
    return matching(identifier)
  }

  private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }
}

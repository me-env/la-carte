import APIClient
import Dependencies
import DependenciesMacros
import Foundation

/// Records what the user does for the user's own server (spec 029), without ever blocking or failing visibly.
@DependencyClient
public struct ActivityClient: Sendable {
  /// Fire and forget: returns at once, never throws, never blocks on I/O.
  public var log: @Sendable (_ activity: Activity) -> Void = { _ in }
  /// The time durations are measured with. Fixed in tests, so features that log need no `date` override.
  public var now: @Sendable () -> Date = { Date() }
}

extension ActivityClient: DependencyKey {
  /// Launch environment: `LA_CARTE_ACTIVITY=off` disables logging; `LA_CARTE_ACTIVITY_URL` sends to that server
  /// instead of the app's (QA), and is the only way a `mock*` API mode logs at all.
  public static var liveValue: ActivityClient {
    let environment = ProcessInfo.processInfo.environment
    guard isEnabled(environment: environment) else { return ActivityClient(log: { _ in }, now: { Date() }) }
    let activityURL = environment["LA_CARTE_ACTIVITY_URL"].flatMap(APIClient.httpURL)
    let api = api(environment: environment, activityURL: activityURL)
    // Without a server URL and a token, events still buffer and nothing is sent; the QA URL needs no token.
    return live(
      api: api,
      isConfigured: { activityURL != nil || api.isConfigured() },
      fileURL: .applicationSupportDirectory.appending(path: "activity.jsonl")
    )
  }

  /// No-op: logging never feeds back into state, so features that log don't force every test to stub it.
  public static let testValue = ActivityClient(log: { _ in }, now: { Date(timeIntervalSince1970: 0) })
  public static let previewValue = testValue

  /// A client that keeps what is logged, for TestStore assertions.
  public static func recording() -> (ActivityClient, LockIsolated<[Activity]>) {
    let logged = LockIsolated<[Activity]>([])
    return (ActivityClient(log: { activity in logged.withValue { $0.append(activity) } }, now: testValue.now), logged)
  }

  static func isEnabled(environment: [String: String]) -> Bool {
    guard environment["LA_CARTE_ACTIVITY"] != "off" else { return false }
    let isMock = environment["LA_CARTE_API"]?.hasPrefix("mock") == true
    return !isMock || environment["LA_CARTE_ACTIVITY_URL"].flatMap(APIClient.httpURL) != nil
  }

  /// `log` stamps the envelope on the calling thread and hands it to an `ActivityLog`, created on the first call.
  static func live(
    api: APIClient,
    isConfigured: @escaping @Sendable () -> Bool,
    fileURL: URL
  ) -> ActivityClient {
    let info = Bundle.main.infoDictionary ?? [:]
    let appVersion = info["CFBundleShortVersionString"] as? String ?? ""
    let build = info["CFBundleVersion"] as? String ?? ""
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let osName = "iOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
    let session = LockIsolated(UUID())
    let isStarted = LockIsolated(false)
    let (stream, continuation) = AsyncStream.makeStream(of: ActivityEvent.self)

    return ActivityClient(
      log: { activity in
        let event = session.withValue { session in
          if activity == .appForeground { session = UUID() }
          return ActivityEvent(
            id: UUID(), kind: activity.kind, at: Date(), timeZone: .current, session: session,
            appVersion: appVersion, build: build, os: osName, cardID: activity.cardID, data: activity.data
          )
        }
        let isFirst = isStarted.withValue { isStarted in
          defer { isStarted = true }
          return !isStarted
        }
        if isFirst {
          Task.detached(priority: .utility) {
            await ActivityLog(fileURL: fileURL,isConfigured: isConfigured, send: api.sendActivity).run(stream)
          }
        }
        continuation.yield(event)
      },
      now: { Date() }
    )
  }

  /// The app's server and token, or `LA_CARTE_ACTIVITY_URL`, on a session of its own so a slow activity request
  /// never holds a connection Study needs.
  private static func api(environment: [String: String], activityURL: URL?) -> APIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.httpMaximumConnectionsPerHost = 1
    configuration.networkServiceType = .background
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)
    return .live(
      baseURL: {
        activityURL
          ?? APIClient.resolvedBaseURL(
            environment: environment, stored: AppGroup.defaults.string(forKey: APIClient.urlDefaultsKey)
          )
      },
      token: { APIClient.resolvedToken(environment: environment, stored: TokenStore.liveValue.load) },
      load: { try await session.data(for: $0) }
    )
  }
}

extension DependencyValues {
  public var activity: ActivityClient {
    get { self[ActivityClient.self] }
    set { self[ActivityClient.self] = newValue }
  }
}

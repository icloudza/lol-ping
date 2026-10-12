import Foundation
import LPCore

/// Looks at the GitHub releases of the repository named in Info.plist (`LPUpdateRepo`, "owner/repo") and says when
/// a newer version exists. It only ever points at the release page: nothing is downloaded or installed.
final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(checked: Date)
        case available(version: String, page: URL)
        case failed(String)
    }

    private static let firstCheckDelay: TimeInterval = 15
    private static let interval: TimeInterval = 8 * 60 * 60

    /// Called on the main queue after every change.
    var onChange: (() -> Void)?
    private(set) var state: State = .idle {
        didSet { if state != oldValue { onChange?() } }
    }

    let repository: String
    private let current: SemanticVersion
    private let session: URLSession
    private var timer: Timer?
    private var task: URLSessionDataTask?

    /// Nil when no repository is configured or the app's own version isn't a plain x.y.z.
    init?(repository: String?, currentVersion: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        guard let repository, repository.split(separator: "/").count == 2, !repository.contains(" "),
              let current = SemanticVersion(currentVersion) else { return nil }
        self.repository = repository
        self.current = current
        self.session = session
    }

    var projectPage: URL { URL(string: "https://github.com/\(repository)")! }
    var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases/latest")! }

    /// Starts or stops the background schedule: a first look shortly after launch, then a few times a day.
    func setAutomatic(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.firstCheckDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.check()
            self.timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
    }

    /// Asks GitHub for the latest release. `completion` runs on the main queue with the state it ended in.
    func check(completion: ((State) -> Void)? = nil) {
        guard task == nil else { return }
        let previous = state
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: request) { [weak self] data, response, error in
            let result = Self.read(data: data, response: response, error: error)
            DispatchQueue.main.async {
                guard let self else { return }
                self.task = nil
                switch result {
                case .success(let release):
                    if let release, release.version > self.current {
                        self.state = .available(version: release.version.description, page: release.page)
                    } else {
                        self.state = .upToDate(checked: Date())
                    }
                case .failure(let failure):
                    // A background check that fails keeps showing an update that was already found.
                    if case .available = previous, completion == nil { self.state = previous } else { self.state = .failed(failure.message) }
                }
                completion?(self.state)
            }
        }
        task?.resume()
    }

    struct Release: Equatable {
        let version: SemanticVersion
        let page: URL
    }

    struct Failure: Error {
        let message: String
    }

    /// Reads GitHub's answer. A repository with no releases yet (404) is simply "nothing newer".
    static func read(data: Data?, response: URLResponse?, error: Error?) -> Result<Release?, Failure> {
        if let error { return .failure(Failure(message: error.localizedDescription)) }
        guard let http = response as? HTTPURLResponse else { return .failure(Failure(message: "no response")) }
        if http.statusCode == 404 { return .success(nil) }
        guard (200..<300).contains(http.statusCode), let data else { return .failure(Failure(message: "HTTP \(http.statusCode)")) }
        return parse(data)
    }

    static func parse(_ data: Data) -> Result<Release?, Failure> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = json["tag_name"] as? String else {
            return .failure(Failure(message: "unexpected answer"))
        }
        // A draft, a pre-release, or a tag that isn't a plain version is not an update to offer.
        guard json["draft"] as? Bool != true, json["prerelease"] as? Bool != true, let version = SemanticVersion(tag) else { return .success(nil) }
        guard let text = json["html_url"] as? String, let page = URL(string: text), page.scheme == "https", page.host == "github.com" else {
            return .failure(Failure(message: "unexpected answer"))
        }
        return .success(Release(version: version, page: page))
    }
}

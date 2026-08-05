import Foundation
import MagSleepCore

/// Checks GitHub Releases for a newer MagSleep version. Best-effort: network
/// failures are silent and automatic checks are throttled to once per day.
enum UpdateChecker {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/realAbitbol/MagSleep/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/realAbitbol/MagSleep/releases/latest")!

    private static let lastCheckKey = "LastUpdateCheckDate"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Returns the latest remote version if it is newer than the app's own
    /// version, otherwise nil. Throttled to once per day unless `force` is true.
    static func latestVersion(force: Bool, completion: @escaping (String?) -> Void) {
        if !force {
            let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
            if let last, Date().timeIntervalSince(last) < checkInterval {
                completion(nil)
                return
            }
        }
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)

        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                completion(nil)
                return
            }
            let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            completion(SemanticVersion(remote) > SemanticVersion(local) ? remote : nil)
        }.resume()
    }
}

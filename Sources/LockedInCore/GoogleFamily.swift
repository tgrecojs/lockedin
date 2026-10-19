/// Google-owned names share front-end IP addresses with Gmail, Docs, and Meet, so they are
/// blocked through the hosts file only; a firewall rule on their IPs would break unrelated services.
public enum GoogleFamily {
    static let suffixes: [String] = [
        "google.com", "youtube.com", "youtube-nocookie.com", "youtu.be", "googleapis.com",
        "googleusercontent.com", "googlevideo.com", "gstatic.com", "ggpht.com", "blogspot.com",
        "blogger.com", "doubleclick.net", "googleadservices.com", "googlesyndication.com",
        "google-analytics.com", "googletagmanager.com", "withgoogle.com", "android.com", "goo.gl",
    ]

    public static func contains(_ host: String) -> Bool {
        for suffix in suffixes where host == suffix || host.hasSuffix("." + suffix) {
            return true
        }
        // google.<cc> and google.co.<cc>, with any subdomain in front.
        let labels = host.split(separator: ".").map(String.init)
        if let i = labels.firstIndex(of: "google"), i < labels.count - 1 {
            let tail = labels[(i + 1)...]
            if tail.count <= 2, tail.allSatisfy({ $0.count >= 2 && $0.count <= 3 && $0.allSatisfy(\.isLetter) }) {
                return true
            }
        }
        return false
    }
}

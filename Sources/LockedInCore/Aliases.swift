/// Extra host names that belong to a site. Keyed by the site's base name (no www./m. prefix).
/// Keep this list small and obvious; users can always add names explicitly.
public enum Aliases {
    public static let table: [String: [String]] = [
        "youtube.com": [
            "m.youtube.com", "youtubei.googleapis.com", "youtube-nocookie.com",
            "www.youtube-nocookie.com", "youtu.be",
        ],
        "twitter.com": ["x.com", "www.x.com", "api.twitter.com", "api.x.com", "mobile.twitter.com", "t.co"],
        "x.com": ["twitter.com", "www.twitter.com", "api.x.com", "api.twitter.com", "mobile.twitter.com", "t.co"],
        "reddit.com": ["old.reddit.com", "new.reddit.com", "sh.reddit.com", "redd.it", "i.redd.it", "v.redd.it"],
        "facebook.com": ["m.facebook.com", "web.facebook.com", "fb.com", "www.fb.com"],
        "instagram.com": ["i.instagram.com"],
        "tiktok.com": ["m.tiktok.com", "vm.tiktok.com"],
        "linkedin.com": ["m.linkedin.com"],
        "netflix.com": ["nflxext.com", "assets.nflxext.com", "codex.nflxext.com"],
        "twitch.tv": ["m.twitch.tv"],
        "pinterest.com": ["pin.it"],
    ]
}

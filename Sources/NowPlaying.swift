// What's playing: the Music app and Spotify (they announce every change), the window title of a browser or Tidal
// (the title names the track; needs Accessibility access), or the tags of an opened file.

import AppKit
import AVFoundation
import Foundation

struct Track {
    var title = ""
    var artist = ""
    var playing = true
}

final class NowPlaying {
    private(set) var current: Track?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var fromWindow = false // the current track was read from a window title

    /// Browsers and Tidal, whose window titles name the track while it plays.
    private static let playerBundles: Set<String> = [
        "com.tidal.desktop", "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]
    /// The site names that browsers and apps add to the end of a page's title.
    private static let siteSuffixes = [
        " - YouTube Music", " - YouTube", " - Spotify", " - SoundCloud", " - TIDAL", " - Apple Music", " - Bandcamp",
        " - Deezer", " - Google Chrome", " - Mozilla Firefox", " - Safari", " - Microsoft Edge", " - Brave", " - Arc",
    ]
    /// Window titles that name no track.
    private static let genericTitles: Set<String> = [
        "", "TIDAL", "Safari", "Google Chrome", "Firefox", "Microsoft Edge", "Brave", "Arc", "Opera", "Vivaldi", "New Tab", "Home",
    ]

    func start() {
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) {
                [weak self] in self?.playerChanged($0.userInfo)
            })
        }
        // Reading other apps' windows needs Accessibility access; macOS asks once if it is not granted yet.
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        readWindowTitles()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.readWindowTitles() }
    }

    deinit {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        timer?.invalidate()
    }

    private func playerChanged(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let state = info["Player State"] as? String ?? "Playing"
        let title = info["Name"] as? String ?? "", artist = info["Artist"] as? String ?? ""
        if state == "Stopped" || (title.isEmpty && artist.isEmpty) {
            current = nil
        } else {
            current = Track(title: title, artist: artist, playing: state == "Playing")
        }
        fromWindow = false
    }

    /// The track named by a browser or Tidal window: the active app first, else the first one with a track title.
    private func readWindowTitles() {
        guard AXIsProcessTrusted() else { return }
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return Self.playerBundles.contains(id)
        }.sorted { $0.isActive && !$1.isActive }
        for app in apps {
            if let title = Self.trackTitle(in: app.processIdentifier) {
                current = Track(title: title, artist: "", playing: true)
                fromWindow = true
                return
            }
        }
        if fromWindow {
            current = nil
            fromWindow = false
        }
    }

    /// The title of an app's focused or main window, without the site's name, or nil if it names no track.
    private static func trackTitle(in pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &window) != .success {
            guard AXUIElementCopyAttributeValue(app, "AXMainWindow" as CFString, &window) == .success else { return nil }
        }
        guard let window else { return nil }
        var name: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, "AXTitle" as CFString, &name) == .success,
              var title = name as? String else { return nil }
        title = title.replacingOccurrences(of: #"^\(\d+\) "#, with: "", options: .regularExpression)
        for suffix in siteSuffixes where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
            break
        }
        title = title.trimmingCharacters(in: .whitespaces)
        return genericTitles.contains(title) ? nil : title
    }

    /// Title and artist from a file's tags, else from its name ("Artist - Title.mp3"); delivered on the main queue.
    static func fromFile(_ url: URL, completion: @escaping (Track) -> Void) {
        let asset = AVURLAsset(url: url)
        Task {
            var track = Track()
            if let items = try? await asset.load(.commonMetadata) {
                for item in items {
                    if item.commonKey == .commonKeyTitle, let s = try? await item.load(.stringValue) { track.title = s }
                    if item.commonKey == .commonKeyArtist, let s = try? await item.load(.stringValue) { track.artist = s }
                }
            }
            if track.title.isEmpty {
                let name = url.deletingPathExtension().lastPathComponent
                if let dash = name.range(of: " - "), track.artist.isEmpty {
                    track.artist = String(name[..<dash.lowerBound])
                    track.title = String(name[dash.upperBound...])
                } else {
                    track.title = name
                }
            }
            let result = track
            await MainActor.run { completion(result) }
        }
    }
}

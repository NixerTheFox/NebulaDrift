// What's playing: the Music app and Spotify (they announce every change), other players through MediaRemote on
// macOS versions that still allow it, or the tags of an opened file.

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
    private var mediaRemoteAnswers = false // MediaRemote has reported something at least once

    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping @convention(block) ([String: Any]?) -> Void) -> Void
    private lazy var getInfo: GetInfo? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        return unsafeBitCast(sym, to: GetInfo.self)
    }()

    func start() {
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) {
                [weak self] in self?.playerChanged($0.userInfo)
            })
        }
        askMediaRemote()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.askMediaRemote() }
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
    }

    /// Any app's track, where macOS lets other apps see it (up to macOS 15.3).
    private func askMediaRemote() {
        getInfo?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }
            let title = info?["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            let artist = info?["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            if title.isEmpty && artist.isEmpty {
                if self.mediaRemoteAnswers { self.current = nil }
                return
            }
            self.mediaRemoteAnswers = true
            let rate = (info?["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 1
            self.current = Track(title: title, artist: artist, playing: rate > 0)
        }
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

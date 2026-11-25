import Foundation
import MediaPlayer

/// Hooks up the keyboard's media keys, Control Center and AirPods controls,
/// and shows what's playing in Control Center.
final class NowPlaying {
    private let center = MPRemoteCommandCenter.shared()

    init(model: AppModel) {
        center.togglePlayPauseCommand.addTarget { [weak model] _ in
            model?.togglePlayPause()
            return .success
        }
        center.playCommand.addTarget { [weak model] _ in
            model?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak model] _ in
            model?.pause()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak model] _ in
            model?.skip(by: 10)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak model] _ in
            model?.skip(by: -10)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak model] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            model?.seek(to: event.positionTime)
            return .success
        }
    }

    func update(title: String?, duration: Double, position: Double, playing: Bool) {
        let info = MPNowPlayingInfoCenter.default()
        guard let title else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        info.playbackState = playing ? .playing : .paused
    }
}

//
//  PlayerService+AirPlay.swift
//  Yattee
//
//  Hands on-device YouTube playback from MPV to AVPlayer (AirPlayBackend) while the audio
//  route is AirPlay, and back to MPV when it leaves. Other sources keep MPV untouched.
//

import Foundation
import AVFoundation

extension PlayerService {
    /// The backend controls should drive: the AirPlay session while one is active, else MPV.
    var activeBackend: (any PlayerBackend)? {
        airPlayBackend ?? currentBackend
    }

    /// Callbacks from a backend that is not driving playback (paused MPV during AirPlay,
    /// or an AirPlay session that was just stopped) must not touch player state.
    /// Without an AirPlay session this is always true for MPV, so MPV behaviour is unchanged.
    func isActiveBackend(_ backend: any PlayerBackend) -> Bool {
        guard let airPlayBackend else { return !(backend is AirPlayBackend) }
        return backend === airPlayBackend
    }

    /// Called at the start of every load: a new load always starts in MPV; AirPlay is
    /// re-evaluated once MPV is ready.
    func prepareAirPlayForLoad() {
        #if os(iOS)
        stopAirPlay(resumeMPV: false)
        guard airPlayRouteObserver == nil else { return }
        airPlayRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateAirPlayRoute() }
        }
        #endif
    }

    /// On-device adaptive googlevideo URLs 403 on the open-ended ranges MPV/ffmpeg send, so MPV
    /// gets them through the loopback server's bounded-chunk passthrough. Everything else is unchanged.
    func loopbackProxied(_ stream: Stream?, for video: Video) async -> Stream? {
        guard let stream else { return nil }
        guard instancesManager?.instance(for: video)?.type == .onDevice,
              stream.url.host?.hasSuffix(".googlevideo.com") == true,
              !stream.isMuxed, !stream.isLive,
              let length = stream.fileSize, length > 0 else { return stream }
        do {
            let server = try await LocalHLSServer.loopback()
            let url = server.register(.raw(
                stream.url,
                length: length,
                contentType: stream.mimeType?.components(separatedBy: ";").first ?? "application/octet-stream",
                headers: stream.httpHeaders ?? [:]
            ))
            return stream.withURL(url)
        } catch {
            LoggingService.shared.warning("Loopback media server unavailable, playing direct: \(error.localizedDescription)", category: .player)
            return stream
        }
    }

    /// Starts or stops the AirPlay session to match the current audio route.
    func evaluateAirPlayRoute() {
        #if os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.first { $0.portType == .airPlay }
        let isAirPlaying = airPlayBackend != nil || airPlayHandoffTask != nil
        if let route, !isAirPlaying, canHandOffToAirPlay(route: route) {
            startAirPlay()
        } else if route == nil, isAirPlaying {
            LoggingService.shared.info("AirPlay route left; resuming in MPV", category: .player)
            stopAirPlay(resumeMPV: true)
        }
        #endif
    }

    /// Ends the AirPlay session. With `resumeMPV`, MPV continues from the AirPlay position.
    func stopAirPlay(resumeMPV: Bool) {
        airPlayHandoffTask?.cancel()
        airPlayHandoffTask = nil
        guard let backend = airPlayBackend else { return }
        let time = backend.currentTime
        let wasPlaying = backend.isPlaying
        backend.stop()
        airPlayBackend = nil
        guard resumeMPV else { return }
        Task {
            await seek(to: time)
            if wasPlaying { resume() } else { pause(saveProgress: false) }
        }
    }

    #if os(iOS)
    private func canHandOffToAirPlay(route: AVAudioSessionPortDescription) -> Bool {
        guard let video = state.currentVideo,
              instancesManager?.instance(for: video)?.type == .onDevice,
              !availableStreams.isEmpty,
              [.playing, .paused, .buffering, .ready].contains(state.playbackState),
              !route.portName.localizedCaseInsensitiveContains("HomePod"),
              !AirPlayBackend.audioOnlyRouteUIDs.contains(route.uid) else { return false }
        return true
    }

    /// Builds the AirPlay presentation while MPV keeps playing, then switches over at MPV's position.
    private func startAirPlay() {
        guard let videoID = state.currentVideo?.id else { return }
        let streams = availableStreams
        let preferredAudio = state.currentAudioStream
        LoggingService.shared.info("AirPlay route active; preparing AVPlayer handoff for \(videoID.videoID)", category: .player)

        airPlayHandoffTask = Task {
            do {
                let backend = try await AirPlayBackend.make(streams: streams, preferredAudio: preferredAudio)
                guard !Task.isCancelled, state.currentVideo?.id == videoID else { return backend.stop() }
                airPlayHandoffTask = nil
                let wasPlaying = state.playbackState == .playing || state.playbackState == .buffering
                let time = state.currentTime
                currentBackend?.pause()
                backend.delegate = self
                backend.rate = currentBackend?.rate ?? 1
                backend.onFailure = { [weak self] reason in
                    LoggingService.shared.warning("AirPlay session ended: \(reason)", category: .player)
                    self?.stopAirPlay(resumeMPV: true)
                }
                airPlayBackend = backend
                backend.start(at: time, playing: wasPlaying)
            } catch {
                guard !Task.isCancelled else { return }
                airPlayHandoffTask = nil
                LoggingService.shared.logPlayerError("AirPlay handoff failed; staying in MPV", error: error)
            }
        }
    }
    #endif
}

//
//  AirPlayPlaceholderView.swift
//  Yattee
//
//  Placeholder shown in place of the video surface while playing over AirPlay.
//

import SwiftUI

#if os(iOS)
import AVFoundation

struct AirPlayPlaceholderView: View {
    /// Mini player variant: just a small icon.
    var compact: Bool = false

    @State private var deviceName: String?

    var body: some View {
        ZStack {
            Color.black
            if compact {
                Image(systemName: "airplayvideo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "airplayvideo")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(String(localized: "player.airplay.label"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .environment(\.colorScheme, .dark)
                .padding()
            }
        }
        .allowsHitTesting(false)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            refresh()
        }
    }

    private var title: String {
        if let deviceName {
            return String(format: String(localized: "player.airplay.playingOn"), deviceName)
        }
        return String(localized: "player.airplay.playingOnTV")
    }

    private func refresh() {
        deviceName = AVAudioSession.sharedInstance().currentRoute.outputs
            .first { $0.portType == .airPlay }?.portName
    }
}
#endif

//
//  SplattrApp.swift
//  Splattr — capture companion app for the AI-3D-Gaussian pipeline.
//
//  Cold-launches from a `claudesplat://join?session=…&host=ip:port&v=1` URL
//  embedded in the laptop's QR. iOS recognises the scheme via Info.plist
//  and lands the user directly on JoinView.
//

import SwiftUI

@main
struct SplattrApp: App {
    @StateObject private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    router.handle(url: url)
                }
        }
    }
}

private struct RootView: View {
    @EnvironmentObject var router: Router

    var body: some View {
        ZStack {
            Theme.Background.app
                .ignoresSafeArea()
            AnimatedHaloBackground()
                .ignoresSafeArea()
                .opacity(0.55)
            content
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
        .animation(.easeInOut(duration: 0.45), value: router.screenID)
    }

    @ViewBuilder
    private var content: some View {
        switch router.screen {
        case .splash:
            SplashView()
        case .join(let descriptor, let host):
            JoinView(descriptor: descriptor, host: host)
        case .capture(let descriptor, let host):
            CaptureView(descriptor: descriptor, host: host)
        case .upload(let descriptor, let host, let frames):
            UploadView(descriptor: descriptor, host: host, frames: frames)
        case .done(let summary):
            DoneView(summary: summary)
        case .error(let message):
            ErrorView(message: message)
        }
    }
}

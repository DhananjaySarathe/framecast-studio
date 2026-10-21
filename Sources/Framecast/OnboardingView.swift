import SwiftUI
import AppKit
import AVFoundation
import ScreenCaptureKit
import FramecastEngine

enum OnboardingStep: Int, CaseIterable { case permissions, devices, format, ready
    var title: String { ["Access", "Camera & mic", "Formats", "Ready"][rawValue] }
    var detail: String { ["What Framecast may use", "Pick your devices", "16:9, 9:16 or both", "Open your studio"][rawValue] }
}

struct OnboardingView: View {
    @Environment(Studio.self) var studio
    @Environment(AppSettings.self) var settings
    @Local var step: OnboardingStep = .permissions
    @Local var showDestinations = false
    var body: some View {
        HStack(spacing: 0) {
            // Left: who we are and where you are in the set-up.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    if let icon = AppIcon.image() { Image(nsImage: icon).resizable().frame(width: 44, height: 44) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Framecast").font(.fc(18, .bold))
                        Text("Studio for 16:9 and 9:16 at once").font(.fc(11.5)).foregroundStyle(Theme.text3)
                    }
                }
                .padding(.bottom, 36)
                ForEach(OnboardingStep.allCases, id: \.self) { s in
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle().fill(s.rawValue < step.rawValue ? Theme.accent : (s == step ? Theme.accentFill : Theme.control))
                            if s.rawValue < step.rawValue { Image(systemName: "checkmark").font(.fc(10, .bold)).foregroundStyle(Theme.accentInk) }
                            else { Text("\(s.rawValue + 1)").font(.fc(11, .bold)).foregroundStyle(s == step ? Theme.accent : Theme.text3) }
                        }
                        .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).font(.fc(13, .semibold)).foregroundStyle(s == step ? Theme.text : Theme.text2)
                            Text(s.detail).font(.fc(11.5)).foregroundStyle(Theme.text3)
                        }
                    }
                    .padding(.bottom, 18)
                }
                Spacer()
                Text("You can change all of this later in Settings.").font(.fc(11)).foregroundStyle(Theme.text4)
            }
            .padding(32).frame(width: 300).frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.strip)
            Hairline(vertical: true)
            // Right: the current step.
            VStack(alignment: .leading, spacing: 22) {
                Spacer(minLength: 0)
                Group {
                    switch step {
                    case .permissions: PermissionsStep()
                    case .devices: DevicesStep()
                    case .format: FormatStep()
                    case .ready: ReadyStep(showDestinations: $showDestinations)
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                HStack {
                    if step != .permissions { Button("Back") { step = OnboardingStep(rawValue: step.rawValue - 1)! } }
                    Spacer()
                    if step == .ready {
                        Button("Open the studio") { settings.s.hasOnboarded = true }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent)
                    } else {
                        Button("Continue") { step = OnboardingStep(rawValue: step.rawValue + 1)! }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                }
                .frame(maxWidth: 560)
                Spacer(minLength: 0)
            }
            .padding(48).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Theme.accent.opacity(0.08), Theme.body], startPoint: .topTrailing, endPoint: .bottomLeading))
        }
        .sheet(isPresented: $showDestinations) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add a destination").font(.fc(17, .bold))
                Text("Paste a stream key from YouTube, Twitch, X, Instagram or your own server.").font(.fc(12.5)).foregroundStyle(Theme.text2)
                AddDestinationForm(compact: true)
                HStack { Spacer(); Button("Done") { showDestinations = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(24).frame(width: 560)
        }
    }
}

struct PermissionsStep: View {
    @Local var cam = AVCaptureDevice.authorizationStatus(for: .video)
    @Local var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @Local var screen = CGPreflightScreenCaptureAccess()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("First, what may Framecast use?").font(.fc(24, .bold))
            Text("Allow what you plan to show. macOS asks once for each; you can change it later in System Settings.").font(.fc(13)).foregroundStyle(Theme.text2)
            row("Camera", "See your webcams and capture cards.", cam == .authorized, cam == .denied) {
                AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async { cam = AVCaptureDevice.authorizationStatus(for: .video) } }
            }
            row("Microphone", "Hear your mics and audio interfaces.", mic == .authorized, mic == .denied) {
                AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { mic = AVCaptureDevice.authorizationStatus(for: .audio) } }
            }
            row("Screen & system audio", "Capture displays, windows and app audio.", screen, false) {
                if !CGRequestScreenCaptureAccess() {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { screen = CGPreflightScreenCaptureAccess() }
            }
            Text("All optional. Without them you can still use pictures, text, colours and test sources.").font(.fc(11)).foregroundStyle(Theme.text4)
        }
    }
    func row(_ t: String, _ d: String, _ ok: Bool, _ denied: Bool, _ ask: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) { Text(t).font(.fc(13, .semibold)); Text(d).font(.fc(11.5)).foregroundStyle(Theme.text3) }
            Spacer()
            if ok { Label("Allowed", systemImage: "checkmark.circle.fill").font(.fc(12, .semibold)).foregroundStyle(Theme.healthy) }
            else if denied {
                Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!) }
            } else { Button("Allow", action: ask) }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
    }
}

struct DevicesStep: View {
    @Environment(Studio.self) var studio
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your camera and microphone").font(.fc(22, .bold))
            Text("These are the best ones we found. You can switch any time in the studio.").font(.fc(13)).foregroundStyle(Theme.text2)
            let cams = CameraSource.devices(), mics = MicrophoneSource.devices()
            if let camSource = studio.collection.sources.first(where: { if case .camera = $0.kind { return true }; return false }) {
                HStack {
                    Text("Camera").font(.fc(13, .semibold)).frame(width: 100, alignment: .leading)
                    if cams.isEmpty { Text("No camera found. You can add one later from the studio.").font(.fc(12)).foregroundStyle(Theme.text3) }
                    else {
                        Picker("", selection: Binding(get: { if case .camera(let id, _, _, _) = camSource.kind { return id }; return "" },
                                                      set: { id in studio.updateSource(camSource.id) { $0.kind = .camera(deviceID: id, width: 1920, height: 1080, fps: 30) } })) {
                            Text("Default camera").tag(""); ForEach(cams, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        }.labelsHidden()
                    }
                }
            }
            if let micSource = studio.collection.sources.first(where: { if case .microphone = $0.kind { return true }; return false }) {
                HStack {
                    Text("Microphone").font(.fc(13, .semibold)).frame(width: 100, alignment: .leading)
                    Picker("", selection: Binding(get: { if case .microphone(let id) = micSource.kind { return id }; return "" },
                                                  set: { id in studio.updateSource(micSource.id) { $0.kind = .microphone(deviceID: id) } })) {
                        Text("Default microphone").tag(""); ForEach(mics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }.labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Talk for a second: the level should move.").font(.fc(11.5)).foregroundStyle(Theme.text3)
                    LevelBar(level: studio.levels[micSource.id] ?? .silent)
                }
            }
        }
    }
}

struct FormatStep: View {
    @Environment(Studio.self) var studio
    @Environment(AppSettings.self) var settings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which formats do you make?").font(.fc(22, .bold))
            Text("Pick 16:9 for YouTube, 9:16 for Shorts, Reels and TikTok, or both from one show.").font(.fc(13)).foregroundStyle(Theme.text2)
            HStack(spacing: 12) {
                card(.horizontal, "16:9", "Wide: YouTube, Twitch, recordings", w: 60, h: 34)
                card(.vertical, "9:16", "Tall: Shorts, Reels, TikTok", w: 22, h: 40)
                card(.both, "Both", "Make both from one show", w: 0, h: 0)
            }
        }
    }
    func card(_ s: StageCanvases, _ t: String, _ d: String, w: CGFloat, h: CGFloat) -> some View {
        let on = (settings.s.isVerticalOn ? settings.s.stage : .horizontal) == s
        return VStack(spacing: 8) {
            ZStack {
                if s == .both { HStack(spacing: 6) { frame(44, 25, on); frame(16, 30, on) } } else { frame(w, h, on) }
            }.frame(height: 50)
            Text(t).font(.fc(13, .semibold)); Text(d).font(.fc(11)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.control2))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Theme.accent : Theme.hairline, lineWidth: on ? 2 : 1))
        .onTapGesture { studio.setVertical(s != .horizontal); studio.stage = s }
    }
    func frame(_ w: CGFloat, _ h: CGFloat, _ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(on ? Theme.accentFill : .clear).overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? Theme.accent : Theme.text4, lineWidth: 2)).frame(width: w, height: h)
    }
}

struct ReadyStep: View {
    @Environment(Studio.self) var studio
    @Binding var showDestinations: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your studio is set").font(.fc(24, .bold))
            Text("Record right away, or add a destination to broadcast to.").font(.fc(13)).foregroundStyle(Theme.text2)
            let n = studio.streaming.destinations.items.count
            HStack(spacing: 10) {
                Image(systemName: n == 0 ? "record.circle" : "antenna.radiowaves.left.and.right").foregroundStyle(Theme.accent)
                Text(n == 0 ? "No destinations yet: recording only" : "\(n) destination\(n == 1 ? "" : "s") ready").font(.fc(12.5, .semibold))
                Spacer()
                Button(n == 0 ? "Add a destination…" : "Add another…") { showDestinations = true }
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Theme.control2))
        }
    }
}

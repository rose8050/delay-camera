import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var areControlsVisible = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            DelayedPreviewView(displayLayer: camera.displayLayer)
                .ignoresSafeArea()

            edgeScrim
                .opacity(areControlsVisible ? 1 : 0)

            controlsOverlay
                .opacity(areControlsVisible ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                areControlsVisible.toggle()
            }
        }
        .onAppear {
            camera.configureSession()
            camera.startSession()
        }
        .onDisappear {
            camera.stopSession()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                camera.handleDidBecomeActive()
            case .background:
                camera.handleWillResignActive()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .alert("오류", isPresented: Binding(
            get: { camera.errorMessage != nil },
            set: { if !$0 { camera.errorMessage = nil } }
        )) {
            Button("확인") { camera.errorMessage = nil }
        } message: {
            Text(camera.errorMessage ?? "")
        }
    }

    private var edgeScrim: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.32), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                .frame(height: 170)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var controlsOverlay: some View {
        VStack {
            if camera.isRecording, let startDate = camera.recordingStartDate {
                RecordingIndicator(startDate: startDate)
                    .padding(.top, 12)
                    .transition(.scale.combined(with: .opacity))
            }

            Spacer()

            VStack(spacing: 14) {
                DelaySelector(
                    options: CameraManager.delayPresets,
                    selected: camera.delaySeconds
                ) { value in
                    Haptics.light()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        camera.setDelay(value)
                    }
                }
                RecordButton(isRecording: camera.isRecording, action: toggleRecording)
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: camera.isRecording)
    }

    private func toggleRecording() {
        if camera.isRecording {
            camera.stopRecording()
        } else {
            camera.startRecording()
        }
    }
}

// MARK: - 촉각 피드백

private enum Haptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

// MARK: - 눌렀을 때 살짝 눌리는 듯한 탄성 피드백을 주는 버튼 스타일

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

private struct DelaySelector: View {
    let options: [Double]
    let selected: Double
    let onSelect: (Double) -> Void
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { value in
                let isSelected = value == selected
                Button {
                    guard !isSelected else { return }
                    onSelect(value)
                } label: {
                    Text("\(Int(value))초")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.black : Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.white)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
    }
}

private struct RecordingIndicator: View {
    let startDate: Date
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .scaleEffect(isPulsing ? 1.35 : 0.85)
                .opacity(isPulsing ? 1 : 0.55)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)

            Text(timerInterval: startDate...startDate.addingTimeInterval(60 * 60 * 10), countsDown: false, showsHours: false)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .onAppear { isPulsing = true }
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @State private var isBreathing = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.55), lineWidth: 2)
                        .frame(width: 48, height: 48)
                        .scaleEffect(isBreathing ? 1.3 : 1)
                        .opacity(isBreathing ? 0 : 0.85)
                        .animation(.easeOut(duration: 1.15).repeatForever(autoreverses: false), value: isBreathing)
                }

                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 48, height: 48)
                Circle()
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: 48, height: 48)

                if isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.red)
                        .frame(width: 18, height: 18)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 38, height: 38)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRecording)
        .onChange(of: isRecording) { recording in
            isBreathing = recording
        }
        .onAppear { isBreathing = isRecording }
    }
}

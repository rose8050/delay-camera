import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var isGridVisible = false
    @State private var areControlsVisible = true
    @State private var isSwitchingCamera = false
    @State private var switchIconRotation: Double = 0

    var body: some View {
        ZStack {
            DelayedPreviewView(displayLayer: camera.displayLayer)
                .ignoresSafeArea()
                .opacity(isSwitchingCamera ? 0.15 : 1)

            if isGridVisible {
                GridOverlayView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

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
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    Haptics.light()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        camera.stepDelay(forward: value.translation.width < 0)
                    }
                }
        )
        .onAppear {
            camera.configureSession()
            camera.startSession()
        }
        .onDisappear {
            camera.stopSession()
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
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var controlsOverlay: some View {
        VStack {
            HStack {
                GlassIconButton(systemName: "square.grid.3x3", isActive: isGridVisible) {
                    Haptics.light()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        isGridVisible.toggle()
                    }
                }
                Spacer()
                if camera.isRecording, let startDate = camera.recordingStartDate {
                    RecordingIndicator(startDate: startDate)
                        .transition(.scale.combined(with: .opacity))
                }
                Spacer()
                DelayBadge(seconds: Int(camera.delaySeconds))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            HStack {
                Color.clear.frame(width: 44, height: 44)
                Spacer()
                RecordButton(isRecording: camera.isRecording, action: toggleRecording)
                Spacer()
                GlassIconButton(systemName: "arrow.triangle.2.circlepath.camera", isActive: false) {
                    switchCamera()
                }
                .rotationEffect(.degrees(switchIconRotation))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: camera.isRecording)
    }

    private func toggleRecording() {
        if camera.isRecording {
            Haptics.success()
            camera.stopRecording()
        } else {
            Haptics.medium()
            camera.startRecording()
        }
    }

    private func switchCamera() {
        Haptics.light()
        withAnimation(.easeInOut(duration: 0.4)) {
            switchIconRotation += 180
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            isSwitchingCamera = true
        }
        camera.switchCamera()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeInOut(duration: 0.25)) {
                isSwitchingCamera = false
            }
        }
    }
}

private enum Haptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

private struct GlassIconButton: View {
    let systemName: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isActive ? Color.yellow : Color.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

private struct DelayBadge: View {
    let seconds: Int

    var body: some View {
        Text("\(seconds)초 전")
            .font(.system(size: 14, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
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
                        .frame(width: 78, height: 78)
                        .scaleEffect(isBreathing ? 1.3 : 1)
                        .opacity(isBreathing ? 0 : 0.85)
                        .animation(.easeOut(duration: 1.15).repeatForever(autoreverses: false), value: isBreathing)
                }

                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 78, height: 78)
                Circle()
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: 78, height: 78)

                if isRecording {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 62, height: 62)
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

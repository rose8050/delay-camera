import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()

    var body: some View {
        ZStack {
            DelayedPreviewView(displayLayer: camera.displayLayer)
                .ignoresSafeArea()

            VStack {
                Spacer()

                VStack(spacing: 16) {
                    HStack {
                        Text("지연: \(Int(camera.delaySeconds))초")
                            .foregroundColor(.white)
                        Slider(value: $camera.delaySeconds, in: 1...60, step: 1)
                    }
                    .padding(.horizontal)

                    Button(action: toggleRecording) {
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 84, height: 84)
                            Circle()
                                .fill(camera.isRecording ? Color.red : Color.white)
                                .frame(width: 68, height: 68)
                        }
                    }
                    .padding(.bottom, 32)
                }
                .padding(.top)
                .background(.ultraThinMaterial)
            }
        }
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

    private func toggleRecording() {
        if camera.isRecording {
            camera.stopRecording()
        } else {
            camera.startRecording()
        }
    }
}

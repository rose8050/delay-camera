# DelayCamera

카메라 실시간 입력을 두 개의 완전히 독립된 파이프라인으로 분기하는 iOS 앱.

```
Camera input
     ├──> Delay buffer ──> delayed preview  (항상 동작, 녹화 상태와 무관)
     └──> AVAssetWriter ──> saved video file (녹화 중일 때만, 항상 "현재" 프레임)
```

## 핵심 설계

- `CameraManager.captureOutput(_:didOutput:from:)` (`CameraManager.swift`)가 카메라 프레임이
  들어오는 유일한 지점이다. 여기서 매 프레임마다 두 파이프라인으로 분기한다.
- **Delay buffer**: `videoDelayBuffer` 배열에 프레임과 캡처 시각(`CACurrentMediaTime()`)을 계속 쌓는다.
  30fps 타이머(`displayTimer`)가 "지금 - delaySeconds"를 지난 가장 오래된 프레임을 꺼내
  `AVSampleBufferDisplayLayer`에 그린다. 녹화 시작/종료는 이 로직을 전혀 건드리지 않는다.
- **Recording**: `recordingActive` 플래그가 켜져 있을 때만, delay buffer를 거치지 않고
  캡처된 프레임을 곧바로 `AVAssetWriter`에 기록한다. 즉 녹화는 "프리뷰 화면 녹화"가 아니라
  "카메라 원본을 실시간으로 새로 기록"하는 것이다.
- 두 파이프라인은 서로 다른 상태(버퍼 vs. writer)를 갖고, 서로의 상태를 참조하거나 리셋하지 않는다.
  녹화를 시작해도 delay buffer는 계속 쌓이고, 프리뷰는 끊기거나 처음부터 다시 시작하지 않는다.

## 알려진 트레이드오프 (다음 단계로 고려할 것)

- **메모리**: 현재는 프레임을 압축 없이(BGRA raw) 720p로 버퍼에 쌓는다. 30초 지연 기준
  프레임당 약 3.7MB × 30fps × 30초 ≈ 3GB 수준까지 쌓일 수 있어, 지연 시간을 길게(예: 60초)
  잡거나 오래 켜두면 메모리 경고/종료 위험이 있다. 실사용 단계에서는 `VTCompressionSession`으로
  H.264 압축한 뒤 버퍼링하고 `AVSampleBufferDisplayLayer`가 디코딩까지 맡도록 바꾸는 것을 권장한다
  (프레임당 수십~수백 KB로 줄어듦). 필요하면 이어서 구현해줄 수 있다.
- **오디오 지연 프리뷰**: 지금은 프리뷰는 영상만 지연 표시하고, 오디오는 지연 재생하지 않는다
  (녹화된 파일에는 오디오가 정상적으로 포함된다). 지연된 오디오까지 화면과 동기화해서 들려주려면
  `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer` 추가가 필요하다.
- 전면 카메라 지원, 화면 회전 대응은 포함하지 않았다 (후면 카메라 고정, portrait 고정).

## Xcode 프로젝트로 열기

이 폴더에는 소스 파일만 있고 `.xcodeproj`는 없다 (Windows 환경이라 Xcode로 직접 생성/빌드가
불가능해서, Mac에서 만들어야 한다).

1. Mac의 Xcode에서 **File > New > Project > iOS > App** 생성 (Interface: SwiftUI, Language: Swift).
2. 생성된 프로젝트의 `ContentView.swift`, `App.swift`를 이 폴더의 4개 `.swift` 파일로 교체/추가.
3. 타겟 설정 **Info** 탭에서 다음 키 추가:
   - `NSCameraUsageDescription`: 카메라 접근 권한 설명
   - `NSMicrophoneUsageDescription`: 마이크 접근 권한 설명
   - `NSPhotoLibraryAddUsageDescription`: 녹화한 영상을 사진 앱에 저장하기 위한 권한 설명
4. 실기기에서 실행 (시뮬레이터는 카메라를 지원하지 않음).

빌드 중 에러가 나면 알려주면 바로 고쳐줄 수 있다 (현재 환경이 Windows라 직접 컴파일 검증은
못 했다).

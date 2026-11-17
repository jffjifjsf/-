import SwiftUI
import UIKit

struct ContentView: View {

    @StateObject private var camera = CameraController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.permissionDenied {
                permissionView
            } else {
                CameraPreview(session: camera.session, mirrored: camera.isFrontCamera)
                    .ignoresSafeArea()

                ThirdsGrid()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    scorePanel
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    Spacer(minLength: 0)

                    hintBar
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)

                    controlBar
                        .padding(.bottom, 28)
                }
            }

            toastView
        }
        .statusBarHidden(true)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.toast) { value in
            guard value != nil else { return }
            let captured = value
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                if camera.toast == captured { camera.toast = nil }
            }
        }
    }

    // MARK: - 分数面板

    private var scorePanel: some View {
        HStack(alignment: .center, spacing: 16) {
            scoreRing

            VStack(alignment: .leading, spacing: 7) {
                metricBar(title: "位置", value: camera.score.placement)
                metricBar(title: "水平", value: camera.score.level)
                metricBar(title: "曝光", value: camera.score.exposure)
                metricBar(title: "主体", value: camera.score.subjectSize)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var scoreRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, Double(camera.score.total) / 100.0))))
                .stroke(scoreColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: camera.score.total)

            VStack(spacing: -2) {
                Text("\(camera.score.total)")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(scoreColor)
                Text("分")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: 82, height: 82)
    }

    private func metricBar(title: String, value: Double) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 26, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(scoreColor.opacity(0.9))
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, value)))))
                        .animation(.easeOut(duration: 0.25), value: value)
                }
            }
            .frame(height: 5)
        }
    }

    // MARK: - 提示

    private var hintBar: some View {
        VStack(spacing: 6) {
            ForEach(camera.score.hints.indices, id: \.self) { index in
                Text(camera.score.hints[index])
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(Color.black.opacity(0.42))
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: camera.score.hints)
    }

    // MARK: - 控制栏

    private var controlBar: some View {
        HStack(alignment: .center) {
            Button {
                camera.flipCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.black.opacity(0.35)))
            }

            Spacer()

            Button {
                camera.capturePhoto()
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 76, height: 76)
                    Circle()
                        .fill(camera.isCapturing ? Color.white.opacity(0.4) : Color.white)
                        .frame(width: 62, height: 62)
                }
            }
            .disabled(camera.isCapturing)

            Spacer()

            Button {
                camera.autoCaptureEnabled.toggle()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: camera.autoCaptureEnabled ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: 17, weight: .semibold))
                    Text("自动")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(camera.autoCaptureEnabled ? Color.black : Color.white)
                .frame(width: 52, height: 52)
                .background(
                    Circle().fill(camera.autoCaptureEnabled ? scoreColor : Color.black.opacity(0.35))
                )
            }
        }
        .padding(.horizontal, 34)
    }

    // MARK: - 提示气泡

    @ViewBuilder
    private var toastView: some View {
        if let toast = camera.toast {
            Text(toast)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.72)))
                .transition(.opacity)
                .padding(.bottom, 130)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .animation(.easeInOut(duration: 0.2), value: camera.toast)
        }
    }

    // MARK: - 无权限

    private var permissionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.5))
            Text("需要相机权限")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Text("请到 设置 › 光影评分 › 相机 中允许访问")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(0.15)))
            .foregroundStyle(.white)
            .padding(.top, 4)
        }
        .padding(28)
    }

    private var scoreColor: Color {
        switch camera.score.total {
        case 82...:
            return Color(red: 0.40, green: 0.86, blue: 0.56)
        case 65..<82:
            return Color(red: 0.98, green: 0.79, blue: 0.36)
        default:
            return Color(red: 0.96, green: 0.48, blue: 0.40)
        }
    }
}

/// 三分构图辅助线。
///
/// 比分数直观得多——分数告诉你「好不好」，网格告诉你「该放哪」。
/// 主体压在线交点上，通常就是及格构图。
private struct ThirdsGrid: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3.0
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))

                    let y = h * CGFloat(i) / 3.0
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.20), lineWidth: 0.7)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

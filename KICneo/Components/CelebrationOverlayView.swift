import Combine
import SwiftUI

struct ActionEffectOverlay: View {
  let effect: ActionFeedbackEffect

  @State private var animate = false

  var body: some View {
    ZStack {
      Color.black.opacity(animate ? 0.18 : 0)
        .ignoresSafeArea()

      switch effect {
      case .interested:
        interestedEffect
      }
    }
    .allowsHitTesting(false)
    .onAppear {
      withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
        animate = true
      }
    }
  }

  private var interestedEffect: some View {
    ZStack {
      ForEach(0..<8, id: \.self) { index in
        Image(systemName: "star.fill")
          .font(.system(size: index.isMultiple(of: 2) ? 28 : 20))
          .foregroundStyle(AppTheme.warning)
          .offset(
            x: animate ? cos(Double(index) * .pi / 4) * 90 : 0,
            y: animate ? sin(Double(index) * .pi / 4) * 90 : 0
          )
          .opacity(animate ? 0 : 1)
          .scaleEffect(animate ? 1.2 : 0.2)
      }

      VStack(spacing: 8) {
        Image(systemName: "star.circle.fill")
          .font(.system(size: 64))
          .foregroundStyle(AppTheme.warning)
          .scaleEffect(animate ? 1 : 0.3)

        Text("気になる！")
          .font(.title2.weight(.bold))
          .foregroundStyle(.white)
          .opacity(animate ? 1 : 0)
      }
      .padding(32)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.large, style: .continuous))
      .scaleEffect(animate ? 1 : 0.6)
    }
    .animation(.spring(response: 0.55, dampingFraction: 0.68), value: animate)
  }
}

struct CelebrationOverlayView: View {
  let onDismiss: () -> Void

  @State private var showContent = false
  @State private var fireworks = FireworksEngine()

  var body: some View {
    ZStack {
      AppTheme.celebrationBackground
        .ignoresSafeArea()
        .opacity(showContent ? 1 : 0)

      FireworksView(engine: fireworks)
        .ignoresSafeArea()

      VStack(spacing: 20) {
        Spacer()

        Image(systemName: "party.popper.fill")
          .font(.system(size: 56))
          .foregroundStyle(.yellow)
          .scaleEffect(showContent ? 1 : 0.2)
          .rotationEffect(.degrees(showContent ? 0 : -20))

        Text("おめでとうございます！")
          .font(.system(size: 34, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .opacity(showContent ? 1 : 0)
          .offset(y: showContent ? 0 : 24)

        Text("就活、お疲れ様でした")
          .font(.title3.weight(.medium))
          .foregroundStyle(.white.opacity(0.85))
          .opacity(showContent ? 1 : 0)
          .offset(y: showContent ? 0 : 16)

        Spacer()

        Button(action: onDismiss) {
          Text("閉じる")
            .font(.headline.weight(.semibold))
            .foregroundStyle(AppTheme.celebrationBackground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 48)
        .opacity(showContent ? 1 : 0)
      }
    }
    .onAppear {
      fireworks.start()
      withAnimation(.spring(response: 0.65, dampingFraction: 0.78).delay(0.15)) {
        showContent = true
      }
    }
    .onDisappear {
      fireworks.stop()
    }
  }
}

// MARK: - 花火

final class FireworksEngine: ObservableObject {
  @Published var bursts: [FireworkBurst] = []
  private var timer: Timer?

  func start() {
    spawnBurst()
    timer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
      self?.spawnBurst()
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    bursts.removeAll()
  }

  private func spawnBurst() {
    let burst = FireworkBurst(
      origin: CGPoint(
        x: CGFloat.random(in: 0.15...0.85),
        y: CGFloat.random(in: 0.12...0.45)
      ),
      color: [
        Color.yellow, Color.orange, Color.pink, Color.cyan,
        Color.green, Color.white, AppTheme.primaryAction
      ].randomElement() ?? .yellow
    )
    bursts.append(burst)
    if bursts.count > 12 {
      bursts.removeFirst()
    }
  }
}

struct FireworkBurst: Identifiable {
  let id = UUID()
  let origin: CGPoint
  let color: Color
  let createdAt = Date()
  let particleCount = Int.random(in: 18...28)
  let seed = Double.random(in: 0...1000)
}

struct FireworksView: View {
  @ObservedObject var engine: FireworksEngine

  var body: some View {
    TimelineView(.animation) { timeline in
      Canvas { context, size in
        let now = timeline.date.timeIntervalSinceReferenceDate
        for burst in engine.bursts {
          let age = now - burst.createdAt.timeIntervalSinceReferenceDate
          guard age >= 0, age < 1.6 else { continue }

          let center = CGPoint(x: burst.origin.x * size.width, y: burst.origin.y * size.height)
          for index in 0..<burst.particleCount {
            let angle = (Double(index) / Double(burst.particleCount)) * .pi * 2 + burst.seed
            let distance = age * 120 * (0.6 + sin(burst.seed + Double(index)) * 0.2)
            let x = center.x + cos(angle) * distance
            let y = center.y + sin(angle) * distance + age * age * 40
            let alpha = max(0, 1 - age / 1.4)
            let particleSize = max(1.5, 5 - age * 2)

            let path = Path(
              ellipseIn: CGRect(
                x: x - particleSize / 2,
                y: y - particleSize / 2,
                width: particleSize,
                height: particleSize
              )
            )
            context.fill(path, with: .color(burst.color.opacity(alpha)))
          }
        }
      }
    }
  }
}

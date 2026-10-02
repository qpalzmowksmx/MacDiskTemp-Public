import DiskCore
import SwiftUI

struct SetupView: View {
    @ObservedObject var installer: DependencyInstaller
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 38)).foregroundStyle(.teal)
            Text("처음 한 번만 준비해 주세요").font(.title2.bold())
            Text("디스크의 온도와 상태를 읽으려면 smartmontools가 필요합니다. 없는 도구만 순서대로 설치합니다.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                Label(DependencySetup.brewPath == nil ? "Homebrew · 설치 필요" : "Homebrew · 설치되어 있음",
                      systemImage: DependencySetup.brewPath == nil ? "1.circle" : "checkmark.circle.fill")
                Label("smartmontools · 디스크 상태 읽기", systemImage: "2.circle")
                Label("설치 완료 후 자동으로 측정 시작", systemImage: "3.circle")
            }.font(.callout)
            Text("설치 버튼을 누르면 터미널이 열립니다. 명령어는 자동으로 실행되며, Homebrew 설치 시 Mac 로그인 비밀번호와 Return 키 확인이 필요할 수 있습니다. Apple 개발자 도구가 없으면 함께 설치되어 시간이 걸릴 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("Homebrew 공식 설치 안내", destination: URL(string: "https://docs.brew.sh/Installation")!)
                .font(.caption)
            if installer.isRunning {
                HStack(alignment: .top, spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(installer.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Text("설치를 중단하려면 터미널에서 Control+C를 누르세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure = installer.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if installer.isRunning || installer.failure != nil {
                    Button("터미널 보기") { installer.showTerminal() }
                }
                Spacer()
                Button(installer.isRunning ? "백그라운드에서 계속" : "나중에") { dismiss() }
                if !installer.isRunning {
                    Button(installer.failure == nil ? "자동 설치 시작" : "다시 시도") { installer.start() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }.padding(30).frame(width: 520)
            .onChange(of: installer.completed) { done in if done { dismiss() } }
    }
}

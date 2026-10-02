import Foundation

/// Installs only the two dependencies, using Homebrew's own interactive installer.
/// Passwords and installer output stay in Terminal; the app reads stage names only.
public enum DependencySetup {
    public static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    public static let smartctlPaths = ["/opt/homebrew/bin/smartctl", "/opt/homebrew/sbin/smartctl",
                                       "/usr/local/bin/smartctl", "/usr/local/sbin/smartctl"]
    public static var brewPath: String? {
        brewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func script(directory: URL, brewPaths: [String] = brewPaths,
                              smartctlPaths: [String] = smartctlPaths,
                              downloader: String = "/usr/bin/curl") -> String {
        """
        #!/bin/bash
        set -euo pipefail
        umask 077
        export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin
        export HOMEBREW_NO_ANALYTICS=1
        export HOMEBREW_NO_ENV_HINTS=1
        # This is an interactive first-run setup, even if Terminal inherited CI settings.
        unset NONINTERACTIVE CI
        session=\(shellQuote(directory.path))
        status="$session/status"
        if [[ -f "$status" && "$(/bin/cat "$status")" == complete ]]; then exit 0; fi
        # Opening the same .command twice must not start two package installs.
        /bin/mkdir "$session/running" 2>/dev/null || exit 1
        printf '%s' "$$" > "$session/pid"
        stage() { printf '%s' "$1" > "$status.next"; /bin/mv -f "$status.next" "$status"; }
        finish() {
            code=$?
            trap - EXIT
            /bin/rm -f "$session/homebrew-install.sh"
            /bin/rmdir "$session/running" 2>/dev/null || true
            if [[ "$code" -eq 0 ]]; then
                printf '\\n설치 완료. MacDiskTemp로 돌아가세요. 이 창은 닫아도 됩니다.\\n'
                stage complete
            elif [[ "$code" -eq 130 ]]; then
                printf '\\n설치가 중단되었습니다. 앱에서 다시 시도할 수 있습니다.\\n'
                stage cancelled
            else
                printf '\\n설치 실패 (종료 코드 %s). 위 메시지를 확인한 뒤 앱에서 다시 시도하세요.\\n' "$code"
                stage failed
            fi
            exit "$code"
        }
        trap finish EXIT
        trap 'exit 130' INT HUP TERM
        find_brew() {
            brew=''
            for candidate in \(brewPaths.map(shellQuote).joined(separator: " ")); do
                if [[ -x "$candidate" ]]; then brew="$candidate"; return 0; fi
            done
            return 1
        }
        find_smartctl() {
            smartctl=''
            for candidate in \(smartctlPaths.map(shellQuote).joined(separator: " ")); do
                if [[ -x "$candidate" ]]; then smartctl="$candidate"; return 0; fi
            done
            return 1
        }
        if ! find_smartctl; then
            if ! find_brew; then
                stage homebrew
                printf '\\nHomebrew 공식 설치를 시작합니다. 비밀번호와 설치 확인 요청에 응답하세요.\\n비밀번호를 입력해도 화면에는 표시되지 않습니다.\\n'
                \(shellQuote(downloader)) --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \\
                    --connect-timeout 20 --max-time 180 --retry 2 \\
                    --output "$session/homebrew-install.sh" \\
                    'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh'
                /bin/bash "$session/homebrew-install.sh"
                find_brew || { printf 'Homebrew 실행 파일을 찾지 못했습니다.\\n'; exit 1; }
            fi
            stage smartmontools
            "$brew" install smartmontools
            find_smartctl || { printf 'smartctl 실행 파일을 찾지 못했습니다.\\n'; exit 1; }
        fi
        stage verifying
        "$smartctl" --version
        """ + "\n"
    }
}

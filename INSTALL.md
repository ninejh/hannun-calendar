# Install the beta / 베타 설치

Requires an Apple silicon Mac with macOS 14 or later. This beta is ad hoc signed and is not notarized. The release label is 1.0.0-beta.2; the app's existing bundle version remains 1.0 (build 1).

The release files are `Hannun-Calendar-arm64.dmg`, `Hannun-Calendar-arm64.zip` and `SHA256SUMS`. If using ZIP, extract it and move Hannun Calendar to Applications. A reported missing calendar permission prompt remains unverified and its cause is not confirmed; calendar connection has not been verified for every account.

1. Open the downloaded DMG and drag Hannun Calendar to Applications. Quit an existing copy before replacing it. Back up its local board data before upgrading.
2. If macOS blocks the app, open System Settings → Privacy & Security and use **Open Anyway** for this app if offered, then confirm the prompt. Apple describes this per-app process at https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unidentified-developer-mh40616/mac. System Settings wording can vary by macOS version.
3. Grant calendar or notification access only if you want those features. This beta's clean-account first launch, permissions and upgrade paths have not all been independently verified.

To roll back, quit the app, preserve a copy of current local board files, restore a compatible previous app and, if needed, deliberately restore its verified board backup. Older versions may not read the current board format. Removing the app does not automatically remove its local data.

Apple Silicon Mac과 macOS 14 이상이 필요합니다. 베타는 ad hoc 서명만 되었으며 공증되지 않았습니다. DMG를 열어 앱을 Applications로 드래그하세요. 기존 앱을 교체하기 전에 종료하고 로컬 보드를 백업하세요. macOS가 차단하면 시스템 설정 → 개인정보 보호 및 보안에서 이 앱의 **확인 없이 열기**가 제공되는 경우 선택하고 확인합니다. 캘린더·알림 권한은 필요한 경우에만 허용하세요. 이전 버전으로 돌아갈 때는 현재 보드를 별도 보존하고 호환되는 앱과 확인된 백업을 복원하세요.

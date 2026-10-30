# Install / 설치

Apple Silicon and macOS 14 or later are required. The prepared release is **v1.0.0-beta.3**; bundle version **1.0**, build **1** remain unchanged. The app and DMG are Developer ID signed, Apple notarized and stapled; the ZIP preserves the same stapled app. Signature, ticket and Gatekeeper checks passed for these exact artifacts. Source builds are locally ad hoc signed and have a different trust status.

1. Download `Hannun-Calendar-arm64.dmg` or `Hannun-Calendar-arm64.zip` from the official [release](https://github.com/ninejh/hannun-calendar/releases/tag/v1.0.0-beta.3). Obtain `SHA256SUMS` from that same release and compare `shasum -a 256` output with the listed digest.
2. Before upgrading, finish/save drafts, quit the existing app deliberately and preserve a verified backup of its local board data and preferences. The new layout format may not be readable by older apps; retaining an old app alone does not make a data downgrade safe.
3. Open the DMG and drag **Hannun Calendar** to **Applications**. For ZIP, extract the app and copy it to Applications. Launch the installed copy, then eject the DMG. The complete MIT notice remains in the app under `Contents/Resources/LICENSE`.
4. Grant calendar, notification or login-item permissions only when you choose to use those features. A reported calendar-access issue remains unresolved; successful signing or notarization is not proof that every calendar/permission setup works. Calendar changes you explicitly save affect the original macOS-connected event.

If macOS reports damage or malware, stop and check the release and checksum. Do not disable system security or remove quarantine broadly. Local ad-hoc source builds may be blocked as unidentified; Apple's per-app guidance is [Open an app from an unidentified developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unidentified-developer-mh40616/mac). Signing/notarization status does not guarantee all first-launch or upgrade behavior.

For rollback, quit the app, preserve current local data separately, and use a compatible previous app plus a deliberately chosen, verified data backup if needed. Never overwrite a newer board with an unverified older file. Removing an app does not itself remove its data. Optional provider terms and privacy details are in README.md.

## 한국어

Apple Silicon과 macOS 14 이상이 필요합니다. 준비된 릴리스는 **v1.0.0-beta.3**이며 번들 **1.0**, 빌드 **1**은 그대로입니다. 앱과 DMG의 Developer ID 서명·Apple 공증·티켓 첨부를 완료했고 ZIP에도 같은 티켓 첨부 앱이 들어 있습니다. 이 배포 파일들의 서명·티켓·Gatekeeper 검사를 통과했습니다. 로컬 소스 빌드는 ad hoc 서명으로 신뢰 상태가 다릅니다.

1. 공식 릴리스에서 DMG 또는 ZIP과 같은 릴리스의 `SHA256SUMS`를 받아 `shasum -a 256` 결과를 대조합니다.
2. 기존 앱을 교체하기 전에 작성 중인 내용을 저장하고 직접 종료한 뒤, 로컬 보드와 설정의 확인된 백업을 보존하세요. 구버전은 새 배치 형식을 읽지 못할 수 있습니다.
3. DMG를 열어 **Hannun Calendar**를 **Applications**로 드래그하세요. ZIP은 압축을 풀고 앱을 Applications에 복사합니다. 설치된 앱을 실행한 뒤 DMG를 꺼냅니다. MIT 고지 전문은 앱의 `Contents/Resources/LICENSE`에 있습니다.
4. 캘린더·알림·로그인 항목 권한은 기능을 사용할 때 선택해서 허용하세요. 보고된 캘린더 접근 문제는 아직 해결됐다고 주장하지 않습니다. 앱에서 저장한 일정 변경은 원본 캘린더에 반영됩니다.

손상·악성 소프트웨어 경고가 나오면 실행을 멈추고 릴리스와 체크섬을 확인하세요. 시스템 보안을 끄거나 격리를 일괄 제거하지 마세요. 구버전 복원은 현재 데이터를 별도 보존하고 호환되는 앱과 검증된 백업을 선택해 수행합니다. 앱 제거만으로 데이터가 없어지지는 않습니다.

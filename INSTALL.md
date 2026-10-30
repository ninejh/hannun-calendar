# Install / 설치

The prepared release is **v1.0.0-beta.4**, for Apple Silicon and macOS 14 or later. The app and DMG are **Developer ID signed, Apple notarized and stapled**. The ZIP contains the same stapled app. Strict signature, ticket and Gatekeeper checks passed for these exact artifacts. Bundle version **1.0**, build **1** remain unchanged.

When an approved release becomes available:

1. Get the DMG or ZIP and `SHA256SUMS` from the same official release. Compare `shasum -a 256` output before opening it.
2. Save drafts and deliberately quit the existing app. Preserve a verified backup of local board data and preferences. Keep the previous app separately. Older apps may not read the current layout format; retaining an app alone is not a safe data downgrade.
3. Drag **Hannun Calendar** from the DMG to **Applications**, or extract the ZIP and copy the app manually. This candidate preparation does not install or launch anything. The complete MIT notice is inside `Contents/Resources/LICENSE`.
4. Open the installed copy deliberately and choose Connect Calendar when ready. A calendar permission request is an explicit choice. A successful signature does not verify calendar connectivity or resolve every account's reported error.

If macOS reports damage or malware, stop and verify the release and checksum; do not disable system security or remove quarantine broadly. Apple notarization of beta.3 does not apply to changed beta.4 bytes.

For rollback, quit the app, preserve current local data separately, and deliberately select a compatible previous app and verified data backup. Never overwrite a newer board with an unverified older file. Removing an app does not itself remove its data. Provider notices are in README.md.

## 한국어

Apple Silicon과 macOS 14 이상용 준비된 릴리스는 **v1.0.0-beta.4**입니다. 앱과 DMG의 **Developer ID 서명·Apple 공증·티켓 첨부**를 완료했습니다. ZIP에도 같은 티켓 첨부 앱이 들어 있으며 이 정확한 파일의 서명·티켓·Gatekeeper 검사를 통과했습니다. 번들 버전 **1.0**, 빌드 **1**은 그대로입니다.

승인된 새 릴리스가 공개된 뒤 같은 릴리스의 DMG 또는 ZIP과 SHA256SUMS를 받아 해시를 확인하세요. 작성 중인 내용을 저장하고 기존 앱을 직접 종료한 뒤, 보드·설정의 확인된 백업과 이전 앱을 별도로 보존합니다. DMG의 앱을 응용 프로그램으로 드래그하거나 ZIP 앱을 수동 복사합니다. 이 준비 작업은 앱을 설치하거나 실행하지 않습니다.

앱을 직접 실행한 뒤 준비되면 캘린더 연결을 선택하세요. 권한 요청과 실제 캘린더 연결은 별도 실증 대상입니다. 기존 beta.3 공증은 변경된 후보에 적용되지 않습니다. 손상·악성 소프트웨어 경고가 있으면 중단하고 배포 파일을 확인하며 시스템 보안을 끄거나 격리를 일괄 제거하지 마세요. 복원 시 현재 데이터를 별도 보존하고 호환 앱·검증된 백업을 선택합니다.

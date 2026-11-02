# Install / 설치

Hannun Calendar **v1.0.0-beta.10** targets Apple Silicon and macOS 14 or later. The app version is **1.0**, build **4**. Check the release notes for the final archive verification and known limitations.

Versions through beta.6 do not include the updater, so install an updater-equipped release manually once. Later update checks run automatically, and installation requires your choice. Real-account connectivity and upgrades of real user data have not been verified in this preparation.

When an approved release becomes available:

1. Get the DMG or ZIP and `SHA256SUMS` from the same official release. Compare `shasum -a 256` output before opening it.
2. Save drafts and deliberately quit the existing app. Preserve a verified backup of local board data and preferences. Keep the previous app separately. Older apps may not read the current layout format; retaining an app alone is not a safe data downgrade.
3. Drag **Hannun Calendar** from the DMG to **Applications**, or extract the ZIP and copy the app manually. This preparation does not install or launch anything. The complete MIT notice is inside `Contents/Resources/LICENSE`.
4. Open the installed copy deliberately and choose Connect Calendar when ready. A calendar permission request is an explicit choice. A successful signature does not verify calendar connectivity or resolve every account's reported error.

If macOS reports damage or malware, stop and verify the release and checksum; do not disable system security or remove quarantine broadly. Notarization of an earlier release does not apply to changed release bytes.

For rollback, quit the app, preserve current local data separately, and deliberately select a compatible previous app and verified data backup. Never overwrite a newer board with an unverified older file. Removing an app does not itself remove its data. Provider notices are in README.md.

## 한국어

Hannun Calendar **v1.0.0-beta.10**은 Apple Silicon과 macOS 14 이상용입니다. 앱 버전은 **1.0**, 빌드는 **4**입니다. 최종 배포 파일의 검증 결과와 알려진 제한은 릴리스 노트를 확인하세요.

beta.6 이하에는 업데이트 기능이 없으므로 업데이트 기능이 포함된 버전을 한 번 직접 설치해야 합니다. 이후 업데이트는 자동으로 확인하며 설치는 사용자가 선택합니다. 이번 준비에서는 실제 계정 연결과 실제 사용자 데이터 업그레이드를 검증하지 않았습니다.

승인된 릴리스가 공개된 뒤 같은 릴리스의 DMG 또는 ZIP과 SHA256SUMS를 받아 해시를 확인하세요. 작성 중인 내용을 저장하고 기존 앱을 직접 종료한 뒤, 보드·설정의 확인된 백업과 이전 앱을 별도로 보존합니다. DMG의 앱을 응용 프로그램으로 드래그하거나 ZIP 앱을 수동 복사합니다. 이 준비 작업은 앱을 설치하거나 실행하지 않습니다.

앱을 직접 실행한 뒤 준비되면 캘린더 연결을 선택하세요. 권한 요청과 실제 캘린더 연결은 별도 실증 대상입니다. 이전 릴리스의 공증은 변경된 배포 파일에 적용되지 않습니다. 손상·악성 소프트웨어 경고가 있으면 중단하고 배포 파일을 확인하며 시스템 보안을 끄거나 격리를 일괄 제거하지 마세요. 복원 시 현재 데이터를 별도 보존하고 호환 앱·검증된 백업을 선택합니다. 앱 삭제 자체로 사용자 데이터가 지워지지는 않습니다.

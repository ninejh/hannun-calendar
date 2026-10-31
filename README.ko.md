# Hannun Calendar

[English](README.md)

Mac 바탕화면에서 일정과 프로젝트, 메모, 구독, 할 일, 습관, 세계 시계, 집중 타이머를 함께 보는 네이티브 캘린더 보드입니다. macOS에 연결된 캘린더는 EventKit을 사용하며 보드 데이터는 이 Mac에 저장됩니다. [MIT 라이선스](LICENSE)를 따릅니다.

달력과 네 개의 선택 패널을 자유 격자에서 옮기고 크기를 조절할 수 있습니다. 보드의 빈 배경을 길게 눌러 편집에 들어가고, 편집 중 패널 제목에서 패널을 바꿉니다. 패널 선택과 배치는 로컬에 저장됩니다. 편집 테두리는 움직이지 않으며 일상적인 저장/Undo 안내는 줄이고 부분 저장 설명과 오류는 보존합니다.

## 베타 다운로드

Apple Silicon과 macOS 14 이상용 준비된 릴리스는 **v1.0.0-beta.7**입니다. 앱과 DMG의 **Developer ID 서명·Apple 공증·티켓 첨부**를 완료했습니다. ZIP에도 같은 티켓 첨부 앱이 들어 있으며 이 정확한 파일의 서명·티켓·Gatekeeper 검사를 통과했습니다. 앱 버전은 **1.0**, 빌드는 **2**입니다.

릴리스가 공개되면 beta.6 이하 사용자는 업데이트 기능이 없으므로 beta.7을 직접 다운로드해 한 번 설치해야 합니다. 이후 업데이트는 자동으로 확인하며 설치는 사용자가 선택합니다.

[DMG](https://github.com/ninejh/hannun-calendar/releases/download/v1.0.0-beta.7/Hannun-Calendar-arm64.dmg) · [ZIP](https://github.com/ninejh/hannun-calendar/releases/download/v1.0.0-beta.7/Hannun-Calendar-arm64.zip) · [SHA256SUMS](https://github.com/ninejh/hannun-calendar/releases/download/v1.0.0-beta.7/SHA256SUMS)

저장 보호·쓰기 실패의 기본 오류 문구를 구체적으로 표시합니다. 저장 보호와 저장 결과·재시도·복구 동작은 유지합니다. 이 변경으로 이전 실제 계정 오류의 원인이나 해결을 증명하지 않습니다. 격리된 서명 업데이트 시험에서 합성 메모 보존을 확인했지만 정리된 beta.7 ZIP의 설치와 실제 사용자 데이터 업그레이드는 미검증입니다. 실제 EventKit 연결, 깨끗한 계정 첫 실행, 물리 키보드·VoiceOver도 미검증입니다. [INSTALL.md](INSTALL.md)를 확인하세요.

## 소스 빌드

Apple Silicon Mac, macOS 14 이상, Swift 6, Python 3 및 Xcode 또는 Command Line Tools가 필요합니다. 앱에는 MIT 라이선스의 Sparkle 업데이트 프레임워크가 포함됩니다. [Sparkle 라이선스와 서드파티 고지](Vendor/Sparkle/LICENSE)를 확인하세요. 이 디렉터리에서 실행합니다.

```sh
zsh scripts/check.sh
zsh scripts/build.sh
```

결과는 `build/Hannun Calendar.app`입니다. 공식 다운로드가 Developer ID 서명되더라도 **로컬 소스 빌드는 ad hoc 서명**됩니다. 배포 서명과 공증은 게시자의 자격 증명이 필요한 별도 단계입니다. 이 소스에는 제품 코드와 빌드 검사가 포함되며 개발용 테스트 자료는 포함되지 않습니다.

가상 데이터 데모가 필요하면 실행 중인 다른 사본을 직접 종료한 뒤 선택적으로 실행합니다.

```sh
open -n 'build/Hannun Calendar.app' --args --demo
```

데모는 가상 일정, 메모리 보드와 가짜 외부 서비스를 사용합니다. 캘린더 연결 버튼을 명시적으로 선택해 macOS 캘린더 접근 권한을 요청합니다. 선택적인 명령줄 진단 보고서는 build 디렉터리 아래의 절대 경로만 허용합니다. 앱을 build 트리 밖으로 옮긴 경우에는 실행 작업 디렉터리의 `build/`가 진단 경로의 기준입니다.

## 개인정보와 제공업체

앱 자체 계정·서버·분석 도구는 없습니다. 로컬 보드 파일은 암호화되지 않습니다. 캘린더 계정 인증·동기화는 macOS가 관리하며 앱에서 일정을 저장하거나 옮기면 원본 일정도 바뀝니다. 선택 기능인 날씨·환율 조회에는 고른 도시 좌표 또는 통화 코드와 일반 연결 정보가 제공업체로 전송됩니다. 설정에서 조회를 끌 수 있습니다. 해당 요청에 일정·메모·구독 이름이나 금액은 보내지 않습니다.

날씨는 [Open-Meteo](https://open-meteo.com/)의 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 데이터를 아이콘으로 요약합니다. 무료 호스팅 API는 [비상업적 이용 조건](https://open-meteo.com/en/terms)을 따릅니다. 환율은 [Frankfurter](https://frankfurter.dev/)의 ECB 데이터를 쓰며 [ECB 안내](https://www.ecb.europa.eu/services/using-our-site/disclaimer/html/index.en.html)를 따릅니다. 제공업체 약관은 앱의 MIT 라이선스와 별개입니다.

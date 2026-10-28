# Hannun Calendar

[English](README.md)

Mac에서 달력과 프로젝트, 메모, 할 일, 정기 결제, 세계 시계, 집중 타이머 패널을 함께 보는 앱입니다. macOS에 연결된 캘린더는 EventKit을 통해 사용하며 보드 데이터는 Mac에 저장됩니다. [MIT 라이선스](LICENSE)를 따릅니다.

달력 옆의 네 칸에 오늘의 일정, 마감, 프로젝트, 빠른 메모, 구독, 할 일, 습관, 세계 시계, 집중 타이머 중 필요한 패널을 고를 수 있습니다. 검토된 정적 다운로드 웹사이트는 공개 저장소 준비 단계에서 `website/`에 별도로 추가합니다. 앱 소스만 내보낸 폴더에는 이 디렉터리가 포함되지 않습니다.

## 초기 베타 다운로드

릴리스 **v1.0.0-beta.2**: [Hannun-Calendar-arm64.dmg](https://github.com/ninejh/hannun-calendar/releases/download/v1.0.0-beta.2/Hannun-Calendar-arm64.dmg) · [Hannun-Calendar-arm64.zip](https://github.com/ninejh/hannun-calendar/releases/download/v1.0.0-beta.2/Hannun-Calendar-arm64.zip). 설치 전에 같은 릴리스의 `SHA256SUMS`로 파일을 확인하세요.

이번 베타에는 캘린더 연결 처리와 보드 컨트롤 변경이 포함됩니다. 보고된 캘린더 권한 창 미표시 현상은 실제 환경에서 아직 검증되지 않았고 원인도 확정되지 않았습니다. 모든 계정에서 캘린더 연결이 된다고 주장하지 않습니다. 초기 베타로서 모든 macOS 통합 동작이나 전체 수용 테스트 통과를 주장하지 않습니다.

## 요구 사항과 빌드

다운로드 베타는 Apple Silicon(arm64), macOS 14 이상을 대상으로 합니다. 빌드에는 Swift 6가 포함된 Xcode 또는 Command Line Tools와 Python 3가 필요합니다. 이 폴더에서 실행합니다.

```sh
./scripts/build.sh
open -n 'build/Hannun Calendar.app' --args --demo
```

데모는 가상 일정, 메모리 보드, 가짜 외부 서비스만 사용합니다. 먼저 실행 중인 인스턴스를 종료하세요. 실제 캘린더를 사용하려면 일반 실행 후 캘린더 접근 허용 여부를 선택하세요. 깨끗한 macOS 계정에서 캘린더, 알림, 로그인 항목, 업그레이드, 첫 실행의 모든 동작은 아직 별도 검증되지 않았습니다.

빌드와 다운로드 베타는 ad hoc 서명만 사용하며 Developer ID 서명이나 공증을 받지 않았습니다. 설치와 Gatekeeper 안내는 [INSTALL.md](INSTALL.md)를 확인하세요.

## 개인정보와 데이터 출처

앱 계정과 분석 기능은 없습니다. 로컬 보드 데이터는 암호화되지 않습니다. 선택적 날씨·환율 요청은 선택한 도시의 반올림된 좌표 또는 통화 코드와 일반 네트워크 메타데이터를 제공자에게 보냅니다. 설정에서 요청을 끌 수 있습니다. 날씨: [Open-Meteo](https://open-meteo.com/), [CC BY 4.0 출처 표시](https://creativecommons.org/licenses/by/4.0/), 무료 호스팅의 [비상업적 이용 조건](https://open-meteo.com/en/terms). 환율: ECB 데이터를 사용하는 [Frankfurter](https://frankfurter.dev/)와 [ECB 면책 안내](https://www.ecb.europa.eu/services/using-our-site/disclaimer/html/index.en.html). 제공자 이용 조건은 앱의 MIT 라이선스와 별개입니다.

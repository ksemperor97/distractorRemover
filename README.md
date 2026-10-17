# distractorRemover

[![CI](https://github.com/ksemperor97/distractorRemover/actions/workflows/ci.yml/badge.svg)](https://github.com/ksemperor97/distractorRemover/actions/workflows/ci.yml)

현재 버전: **v2.0.0** (Swift 네이티브 앱)

집중을 방해하는 웹 서비스를 macOS 메뉴바에서 차단하고, 요일·시간대에 따라 자동으로 켜고 끄는 작은 앱입니다. 기존 `/etc/hosts` 내용은 보존하고 distractorRemover 전용 관리 구간만 추가·제거합니다.

v2.0.0은 Python(rumps/PyObjC) 버전을 Swift + AppKit으로 다시 작성하고, 메뉴를 사이트 편집·차단 시작/해제·스케줄로 단순화한 것입니다. 앱 크기는 24 MB에서 1 MB 미만으로 줄었고, Python 런타임 없이 실행됩니다. v1.x의 설정 파일, 설치된 password-free helper(v2/v3), 자동 실행 LaunchAgent를 그대로 이어받습니다.

## 설치

macOS 13 이상과 Xcode Command Line Tools(`xcode-select --install`)가 필요합니다. Xcode 전체 설치는 필요 없습니다.

```bash
git clone https://github.com/ksemperor97/distractorRemover.git
cd distractorRemover
./build_app.sh --install
```

`/Applications/distractorRemover.app`에 설치하고 실행합니다. 빌드만 하려면 `./build_app.sh`를 실행하며, 결과는 `dist/distractorRemover.app`에 생깁니다.

## 사용법

메뉴는 이것뿐입니다.

| 메뉴 | 동작 |
|---|---|
| 상태 줄 | `Blocking`, `Blocking until 18:00 (schedule)`, `Not blocking · schedule starts Mon 09:00` 등 |
| **Start Blocking** / **Stop Blocking…** | 지금 차단을 시작하거나 멈춤 |
| **Edit Blocked Sites…** (⌘E) | 차단할 사이트를 한 줄에 하나씩 텍스트로 편집 |
| **Schedule…** | 요일·시간대 자동 차단 설정 |
| **Edit Hosts File…** | 문제가 생겼을 때 hosts 파일 전체를 직접 편집 |
| **Open at Login** | 로그인 시 자동 실행 (스케줄이 재부팅 후에도 동작하려면 켜 두세요) |

메뉴바 아이콘은 실제 차단 중이면 채워진 방패, 아니면 빈 방패, 적용에 실패하면 경고 삼각형입니다.

### 차단 시작과 해제

차단은 두 종류입니다. **Start Blocking**으로 켜는 수동 차단과, **Schedule…**에서 정한 시간대에 자동으로 켜지는 스케줄 차단입니다. 둘 중 하나라도 켜져 있으면 차단합니다.

**Stop Blocking…**은 둘 다 해제합니다. 수동 차단을 끄고, 지금 진행 중인 스케줄 구간은 그 구간이 끝날 때까지 쉬게 합니다. 스케줄 자체는 그대로 남아서 다음 구간(예: 다음 날 09:00)이 되면 다시 차단합니다. 해제 전에 한 번 확인을 묻고, 확인 창에 스케줄이 다시 켜지는 시각을 보여 줍니다.

차단 중에는 사이트를 추가할 수 있지만 지울 수는 없습니다. 지우려면 먼저 차단을 멈춥니다.

### 문제가 생겼을 때

대부분은 앱이 알아서 복구합니다.

- hosts 적용에 실패하면 5초, 15초, 이후 30초 간격으로 다시 시도합니다. 상태 줄이 `Couldn’t update blocking — click to retry`로 바뀌고, 누르면 바로 다시 시도합니다.
- hosts 파일의 distractorRemover 구간이 일부만 지워져 있으면 전체 hosts를 백업한 뒤 그 구간을 다시 씁니다.
- 설정 파일이 손상되어 있으면 원본을 `config.json.corrupt-날짜`로 보관하고 빈 설정으로 시작하며, 처음 한 번 알려 줍니다.

그래도 이상하면 **Edit Hosts File…**로 hosts 파일 전체를 텍스트로 고칠 수 있습니다. 저장 전에 원본을 `~/Library/Application Support/distractorRemover/hosts-backups/`에 백업하고, 저장할 때 관리자 암호를 묻습니다. distractorRemover 표시 줄 사이의 내용은 차단 사이트 목록에 맞게 자동으로 다시 쓰입니다.

## 서비스 프리셋과 사용자 도메인

URL 전체를 붙여넣어도 정규화합니다.

```text
https://www.youtube.com/feed → youtube.com
```

YouTube, Instagram, X/Twitter, Reddit, TikTok, Facebook은 보조 진입 도메인을 함께 차단하는 프리셋으로 처리합니다. 예를 들어 `youtube.com`, `m.youtube.com`, `music.youtube.com`, `studio.youtube.com`, `youtu.be`를 하나의 YouTube 항목으로 관리합니다.

그 밖의 사용자 도메인은 입력 도메인과 `www.` 도메인을 함께 차단합니다. 국제화 도메인은 IDNA(Punycode) 형식으로 변환합니다.

hosts 파일은 와일드카드를 지원하지 않으므로 임의의 모든 하위 도메인을 자동 차단한다고 보장하지는 않습니다. 프리셋에 광범위한 공용 CDN은 포함하지 않아 다른 서비스의 오작동을 피합니다.

**Edit Blocked Sites…**에는 `/etc/hosts`에서 복사한 `127.0.0.1`·`::1` 행도 붙여넣을 수 있고, `#`으로 시작하는 줄은 무시합니다.

## 스케줄

**Schedule…** 창에서:

1. **Block sites during these times**를 켜고
2. 요일(또는 Weekdays, Weekends, Every day)과 From/to 시간을 고른 뒤 **Add Window**
3. **Save**

`22:00 → 06:00`처럼 자정을 넘는 구간도 됩니다. 앱은 5초마다 시각을 확인하고, 잠자기 해제나 시간·시간대 변경 때도 바로 다시 맞춥니다. 앱이 꺼져 있는 동안에는 스케줄이 바뀌지 않으므로 **Open at Login**을 켜 두세요.

스케줄을 처음 켤 때 한 번만 관리자 암호를 묻습니다. 앱이 혼자서 차단을 켜고 끄려면 작은 helper가 필요하기 때문입니다.

- `/usr/local/bin/distractorremover-helper` — root 소유, distractorRemover 구간만 수정 가능
- `/etc/sudoers.d/distractorremover` — 이 helper만 암호 없이 실행 허용

helper는 검증된 도메인 목록만 받아 관리 구간만 원자적으로 바꿉니다. hosts의 관리 구간은 항상 이 스크립트(`helper/privileged_helper.sh`)가 쓰며, helper가 없을 때는 같은 스크립트를 관리자 인증창 뒤에서 실행합니다. helper 버전은 스크립트의 `VERSION=` 한 곳에서만 정합니다. helper를 지우려면 아래 `uninstall.sh`를 씁니다.

## 완전 제거

앱만 휴지통에 넣으면 hosts 관리 구간이나 helper가 남을 수 있으므로 제거 스크립트를 사용합니다.

```bash
./uninstall.sh                  # 앱, 로그인 항목, hosts 관리 구간, helper 제거
./uninstall.sh --remove-config  # 저장한 사이트와 스케줄까지 삭제
./uninstall.sh --dry-run        # 실제 변경 없이 제거 대상 확인
```

## 개발 및 검증

```bash
swift run CoreChecks     # 로직·설정·helper 스크립트·컨트롤러 검사
swift build              # 디버그 빌드
./build_app.sh           # 릴리스 .app 빌드와 ad-hoc 서명 검증
```

Command Line Tools에는 XCTest와 swift-testing 매크로 플러그인이 없어서, 검사는 `Tests/CoreChecks`의 실행 파일로 돌립니다. 실제 `privileged_helper.sh`를 임시 hosts 파일에 대해 비특권 테스트 모드로 실행하므로, 앱 쪽 검증 규칙과 스크립트 동작이 어긋나면 검사가 실패합니다. GitHub Actions도 같은 검사와 앱 빌드를 실행합니다.

시스템 hosts를 건드리지 않고 앱을 실행해 보려면 샌드박스 모드를 사용합니다.

```bash
DISTRACTORREMOVER_SANDBOX=/tmp/dr-sandbox dist/distractorRemover.app/Contents/MacOS/distractorRemover
```

`/tmp/dr-sandbox/hosts`와 `/tmp/dr-sandbox/support/`를 대신 사용하며, helper 스크립트를 관리자 권한 없이 그 파일에 대해 실행합니다. `DISTRACTORREMOVER_SANDBOX_PROMPT=cancel`은 관리자 인증 취소를 흉내 내고, `DISTRACTORREMOVER_DEBUG_SHOW=menu|menu-dump|schedule-editor|sites|hosts`는 실행 직후 해당 화면을 엽니다(`menu-dump`는 메뉴를 텍스트로 출력하고 종료).

공개 배포용 Developer ID 서명은 `CODESIGN_IDENTITY="Developer ID Application: …" ./build_app.sh`로 지정할 수 있으며, notarization은 별도 단계입니다.

## 제한 사항

- 도메인 기반 차단이므로 IP 직접 접속은 막지 못합니다.
- 이미 열린 연결이나 브라우저 DNS 캐시 때문에 잠시 접속될 수 있습니다.
- 앱이 종료된 동안에는 스케줄 전환이 일어나지 않습니다. 현재 hosts 상태는 유지됩니다.
- **Open at Login**은 로그인 시 실행만 담당하고 비정상 종료 후 자동 재시작은 하지 않습니다. v1.x에서 설정한 LaunchAgent가 남아 있으면 계속 동작하며, **Open at Login**을 바꾸면 정리됩니다.
- 종료(Quit)해도 현재 hosts 상태는 그대로 남습니다. 차단을 풀고 끄려면 먼저 **Stop Blocking…**을 누릅니다.
- 메뉴바가 가득 차 있으면 macOS가 상태 아이콘을 숨길 수 있습니다. 다른 메뉴바 항목을 줄이거나 ⌘-드래그로 순서를 바꾸세요.
- 관리자 권한을 가진 사용자의 고의적인 우회를 완전히 막는 도구가 아니라, 일상적인 충동에 마찰을 추가하는 도구입니다.

## 설정과 로그

- 설정: `~/Library/Application Support/distractorRemover/config.json` (v1.x와 호환)
- 앱 로그: `~/Library/Application Support/distractorRemover/app.log` (512 KB 단위 순환)
- 런타임 상태: `~/Library/Application Support/distractorRemover/runtime-state.json`
- 직접 편집 전 hosts 백업: `~/Library/Application Support/distractorRemover/hosts-backups/`

## 파일 구조

```text
Package.swift
Sources/BlockerCore/          AppKit에 의존하지 않는 핵심 (검사 대상)
  Domains.swift               도메인 정규화, IDNA, 서비스 프리셋, 텍스트 목록 파싱
  HostsFile.swift             관리 구간 판독과 요청 상태 일치 검증
  Schedule.swift              시간대, 자정 넘김, 다음 전환 시각 계산
  Config.swift                사용자 의도(Config)와 파생 상태, 상태 전이
  ConfigCodec.swift           config.json 읽기·쓰기, v1 마이그레이션, 엄격한 검증
  Storage.swift               원자적 저장, 손상 설정 격리, hosts 백업, 인스턴스 잠금
  Privilege.swift             sudo/osascript 및 샌드박스 권한 실행
  HelperHostsBackend.swift    helper를 통한 hosts 갱신, 수동 편집 저장, helper 상태 캐시·설치
  BlockerController.swift     직렬화된 reconcile, 재시도, 자동 복구, 런타임 상태 기록
Sources/DistractorRemover/    메뉴바 앱 (AppKit)
  AppDelegate.swift, Menu.swift, Actions.swift, Dialogs.swift,
  ScheduleEditor.swift, SystemIntegration.swift, AppEnvironment.swift, main.swift
Tests/CoreChecks/             검사 실행 파일
helper/                       privileged_helper.sh, install_helper.sh, uninstall_helper.sh
build_app.sh                  .app 빌드·서명·설치
uninstall.sh                  완전 제거
PRODUCT_COMPLETION_PLAN.md    제품 완성도 설계와 릴리스 기준
```

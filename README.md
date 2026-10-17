# distractorRemover

[![CI](https://github.com/ksemperor97/distractorRemover/actions/workflows/ci.yml/badge.svg)](https://github.com/ksemperor97/distractorRemover/actions/workflows/ci.yml)

현재 버전: **v2.0.0** (Swift 네이티브 앱)

집중을 방해하는 웹 서비스를 macOS 메뉴바에서 차단하고, 요일·시간대에 따라 자동으로 켜고 끄는 작은 앱입니다. 기존 `/etc/hosts` 내용은 보존하고 distractorRemover 전용 관리 구간만 추가·제거합니다.

v2.0.0은 Python(rumps/PyObjC) 버전을 Swift + AppKit으로 다시 작성한 것입니다. 앱 크기는 24 MB에서 1 MB 미만으로 줄었고, Python 런타임 없이 실행됩니다. v1.x의 설정 파일, 설치된 password-free helper(v2/v3), 자동 실행 LaunchAgent를 그대로 이어받습니다.

## 설치

macOS 13 이상과 Xcode Command Line Tools(`xcode-select --install`)가 필요합니다. Xcode 전체 설치는 필요 없습니다.

```bash
git clone https://github.com/ksemperor97/distractorRemover.git
cd distractorRemover
./build_app.sh --install
```

`/Applications/distractorRemover.app`에 설치하고 실행합니다. 빌드만 하려면 `./build_app.sh`를 실행하며, 결과는 `dist/distractorRemover.app`에 생깁니다. 로그인 시 자동 실행은 메뉴의 **Open at Login**에서 켭니다.

## 현재 상태 확인

메뉴바 아이콘(SF Symbols):

- **shield** — 실제 hosts 차단이 꺼져 있음
- **shield.fill** — 실제 hosts 차단이 켜져 있음
- **exclamationmark.triangle** — 요청한 상태와 실제 hosts 상태가 다르거나 적용에 실패함

메뉴 최상단에는 현재 원인과 다음 전환을 표시합니다.

- `Blocking — Manual` / `Blocking — Schedule` / `Blocking — Manual + Schedule`
- `Not blocking — next change 22:00`
- `Update failed — currently not blocking`

오류가 발생하면 앱은 5초, 15초, 이후 30초 간격으로 재시도합니다. 정상 상태에서는 30초마다 hosts 파일만 읽어 검증하며, sudo 호출이나 디스크 쓰기는 실제 변경이 있을 때만 일어납니다. **Status & Repair…**는 요청 상태와 실제 hosts 상태의 일치 여부, helper와 자동 실행 상태, 최근 오류를 한곳에서 보여주고 즉시 재적용하거나 관리 구간을 초기화할 수 있게 합니다.

설정 JSON이 손상되면 앱은 파일을 덮어쓰지 않고 모든 설정 변경을 잠급니다. **Recover Damaged Configuration…**에서 원본을 `.corrupt-날짜` 파일로 백업한 뒤 명시적으로 초기화할 수 있습니다. hosts 관리 마커가 일부만 남은 경우에는 **Reset Managed Hosts Section…**이 전체 hosts 백업을 만든 후 관리 구간을 복구합니다.

## 기본 사용법

| 메뉴 | 동작 |
|---|---|
| **Manual Blocking** (체크 표시) | 수동 차단만 켜거나 끔 |
| **Turn Off All Blocking…** | 수동 차단을 끄고 현재 스케줄 구간을 끝날 때까지 일시 해제 |
| **Add Site…** (⌘N) | 서비스 또는 도메인 추가 |
| **서비스 항목 클릭** | 차단이 꺼져 있을 때 해당 서비스 삭제 (차단 중에는 자물쇠 표시) |
| **Schedule** | 자동 차단 시간대, 스케줄 켜기/끄기, Password-Free Mode |
| **Hosts File** | 앱 차단 목록 텍스트 편집, 실제 hosts 열기·관리자 편집, 백업 폴더 열기 |
| **Open at Login** | 로그인 시 자동 실행 (시스템 설정 → 일반 → 로그인 항목에 표시) |
| **Status & Repair…** | 요청 상태와 실제 적용 상태 확인 및 복구 |
| **Quit distractorRemover** (⌘Q) | 차단 유지 후 종료 또는 차단 해제 후 종료 선택 |

수동 차단과 스케줄 차단은 독립입니다. 둘 중 하나라도 활성 상태면 차단합니다. 수동 차단을 꺼도 현재 스케줄 구간이 활성 상태면 차단은 유지됩니다.

### 전체 해제와 충동 방지

차단이 실제로 적용된 동안에는 다음 규칙을 사용합니다.

- 사이트 추가는 가능
- 개별 서비스 삭제는 잠금
- 수동 차단 해제는 확인 필요
- 활성 스케줄 비활성화는 확인 필요
- **Turn Off All Blocking…**은 한 번 더 확인한 후 현재의 모든 차단을 해제

전체 해제를 선택해도 향후 스케줄은 유지됩니다. 현재 활성 구간만 종료 시각까지 일시 중지하며, Schedule 메뉴의 **Resume Current Window**로 즉시 다시 적용할 수 있습니다.

관리자 인증창을 취소하면 설정과 hosts 모두 변경 전 상태 그대로 남습니다.

## 서비스 프리셋과 사용자 도메인

URL 전체를 붙여넣어도 정규화합니다.

```text
https://www.youtube.com/feed → youtube.com
```

YouTube, Instagram, X/Twitter, Reddit, TikTok, Facebook은 보조 진입 도메인을 함께 차단하는 프리셋으로 처리합니다. 예를 들어 `youtube.com`, `m.youtube.com`, `music.youtube.com`, `studio.youtube.com`, `youtu.be`를 하나의 YouTube 항목으로 관리합니다.

그 밖의 사용자 도메인은 입력 도메인과 `www.` 도메인을 함께 차단합니다. 국제화 도메인은 IDNA(Punycode) 형식으로 변환합니다.

hosts 파일은 와일드카드를 지원하지 않으므로 임의의 모든 하위 도메인을 자동 차단한다고 보장하지는 않습니다. 프리셋에 광범위한 공용 CDN은 포함하지 않아 다른 서비스의 오작동을 피합니다.

### 텍스트로 차단 목록과 hosts 편집

**Hosts File** 메뉴:

- **Edit Block List as Text…** — 한 줄에 도메인 또는 URL 하나씩 편집합니다. `/etc/hosts`에서 복사한 `127.0.0.1`·`::1` 행도 붙여넣을 수 있습니다. 실제 차단 중에는 기존 항목 삭제가 잠기지만 새 항목 추가는 가능합니다.
- **Open Hosts File in TextEdit…** — 현재 시스템 파일을 읽기용으로 엽니다.
- **Edit Hosts File as Administrator…** — 전체 파일을 비공개 백업한 뒤 Terminal에서 `sudo nano /etc/hosts`를 엽니다.
- **Open Hosts Backup Folder…** — 직접 편집 전에 생성된 백업을 Finder에서 엽니다.

distractorRemover 시작·끝 마커 사이의 행은 앱 관리 구간이며 다음 조정 때 설정에 맞게 다시 작성됩니다. 지속할 항목은 **Edit Block List as Text…**에서 편집합니다.

## 시간대 자동 차단

**Schedule → Edit Time Windows…**에서 편집 창을 엽니다.

1. Mon~Sun 또는 Weekdays, Weekends, Every day 프리셋으로 요일 선택
2. From/to 시간 선택기로 시간 범위 지정
3. **Add Window**로 항목 추가, **Remove**로 삭제
4. **Save**

`22:00 → 06:00`처럼 자정을 넘는 구간과 일요일에서 월요일로 넘어가는 구간을 지원합니다. 스케줄을 켜면 현재 시각을 즉시 적용하고 이후 5초마다 상태 변화를 확인합니다. 잠자기 해제, 시스템 시간·시간대 변경 시에는 즉시 다시 조정합니다.

## Password-free mode

`/etc/hosts` 수정에는 관리자 권한이 필요합니다. 수동 변경은 macOS 관리자 인증창을 사용할 수 있지만, 무인 스케줄에는 Password-free mode가 필요합니다. 스케줄을 처음 켤 때 관리자 인증을 한 번 거치면 다음을 설치합니다.

- `/usr/local/bin/distractorremover-helper` — `root:wheel`, 실행 중 변경 불가
- `/etc/sudoers.d/distractorremover` — 해당 helper만 NOPASSWD로 실행 허용

hosts 파일은 항상 `helper/privileged_helper.sh` 하나만 작성합니다. Password-free mode에서는 설치된 helper를 `sudo -n`으로, 그렇지 않으면 앱에 번들된 같은 스크립트를 관리자 인증창 뒤에서 실행합니다. 앱은 결과 hosts 파일을 다시 읽어 요청 상태와 정확히 일치하는지만 검증합니다. helper는 검증된 도메인 목록만 표준 입력으로 받고 관리 구간만 원자적으로 갱신하며, Reset 전에는 전체 hosts 백업을 만듭니다.

helper 버전은 `privileged_helper.sh`의 `VERSION=` 한 곳에서만 정의합니다. 이전 v2 helper는 계속 사용할 수 있고, Schedule 메뉴에서 번들 버전으로 업그레이드할 수 있습니다. 업그레이드 도중 실패하면 이전 helper와 sudoers 쌍을 복원합니다.

앱은 helper가 root 소유의 일반 파일이고 group/world writable이 아니며, NOPASSWD health check가 성공해야 Password-free mode를 켜진 것으로 표시합니다. 이 확인 결과는 캐시하고 설치·제거·실패 시에만 다시 확인합니다.

Password-free mode를 끄면 활성 스케줄을 먼저 끈 후 helper와 sudoers 규칙을 제거합니다. 인증 취소나 중간 실패 시 이전 스케줄 상태를 복구합니다.

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

`/tmp/dr-sandbox/hosts`와 `/tmp/dr-sandbox/support/`를 대신 사용하며, helper 스크립트를 관리자 권한 없이 그 파일에 대해 실행합니다. `DISTRACTORREMOVER_SANDBOX_PROMPT=cancel`은 관리자 인증 취소를, `DISTRACTORREMOVER_DEBUG_SHOW=menu|schedule-editor|block-list|status`는 실행 직후 해당 화면 열기를 흉내냅니다.

공개 배포용 Developer ID 서명은 `CODESIGN_IDENTITY="Developer ID Application: …" ./build_app.sh`로 지정할 수 있으며, notarization은 별도 단계입니다.

## 제한 사항

- 도메인 기반 차단이므로 IP 직접 접속은 막지 못합니다.
- 이미 열린 연결이나 브라우저 DNS 캐시 때문에 잠시 접속될 수 있습니다.
- 앱이 종료된 동안에는 스케줄 전환이 일어나지 않습니다. 현재 hosts 상태는 유지됩니다.
- **Open at Login**은 로그인 시 실행만 담당하고 비정상 종료 후 자동 재시작은 하지 않습니다. v1.x에서 설정한 LaunchAgent가 남아 있으면 그쪽은 계속 재시작을 담당하며, **Open at Login**을 바꾸면 정리됩니다.
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
  HelperHostsBackend.swift    helper를 통한 hosts 갱신, helper 상태 캐시·설치·제거
  BlockerController.swift     직렬화된 reconcile, 재시도, 런타임 상태 기록
Sources/DistractorRemover/    메뉴바 앱 (AppKit)
  AppDelegate.swift, Menu.swift, Actions.swift, Dialogs.swift,
  ScheduleEditor.swift, SystemIntegration.swift, AppEnvironment.swift, main.swift
Tests/CoreChecks/             검사 실행 파일
helper/                       privileged_helper.sh, install_helper.sh, uninstall_helper.sh
build_app.sh                  .app 빌드·서명·설치
uninstall.sh                  완전 제거
PRODUCT_COMPLETION_PLAN.md    제품 완성도 설계와 릴리스 기준
```

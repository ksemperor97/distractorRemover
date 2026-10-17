# distractorRemover

현재 버전: **v1.2.0**

집중을 방해하는 웹 서비스를 macOS 메뉴바에서 차단하고, 요일·시간대에 따라 자동으로 켜고 끄는 작은 앱입니다. 기존 `/etc/hosts` 내용은 보존하고 distractorRemover 전용 관리 구간만 추가·제거합니다.

## 설치

### Python으로 실행

```bash
git clone https://github.com/ksemperor97/distractorRemover.git
cd distractorRemover
./install.sh
.venv/bin/python distractor_remover.py
./enable_autostart.sh     # 선택: 로그인 자동 실행
```

Python 3이 없다면 먼저 `brew install python`을 실행합니다.

### 일반 macOS 앱으로 설치

```bash
./install.sh
./build_app.sh --install
```

설치 후 Finder의 **응용 프로그램 → distractorRemover** 또는 Spotlight에서 실행할 수 있습니다. 빌드 결과는 `dist/distractorRemover.app`에도 남습니다.

기존 자동 실행 설정이 있으면 앱 설치 과정에서 LaunchAgent 경로도 `/Applications/distractorRemover.app`으로 갱신됩니다.

## 현재 상태 확인

메뉴바 아이콘:

- **⚪** — 실제 hosts 차단이 꺼져 있음
- **🛡️** — 실제 hosts 차단이 켜져 있음
- **⚠️** — 요청한 상태와 실제 hosts 상태가 다르거나 적용에 실패함

메뉴 최상단에는 현재 원인과 다음 전환을 표시합니다.

- `🛡 Blocking — Manual`
- `🛡 Blocking — Schedule`
- `🛡 Blocking — Manual + Schedule`
- `⚪ Not blocking — next change 22:00`
- `⚠ Update failed — currently not blocking`

오류가 발생하면 앱은 5초, 15초, 이후 30초 간격으로 재시도합니다. **Status & Repair…**는 사용자가 요청한 차단 상태와 실제 hosts 상태가 일치하는지, helper와 자동 실행이 준비됐는지, 최근 오류가 무엇인지를 한곳에서 보여주는 상태·복구 화면입니다. 이 화면에서 즉시 재적용하거나 손상된 관리 구간을 초기화할 수 있습니다.

설정 JSON이 손상되면 앱은 파일을 빈 설정으로 덮어쓰지 않고 모든 설정 변경을 잠급니다. **Recover damaged configuration…**에서 원본을 `.corrupt-날짜` 파일로 백업한 뒤 명시적으로 초기화할 수 있습니다. hosts 관리 마커가 일부만 남은 경우에는 **Reset managed hosts section…**이 전체 hosts 백업을 만든 후 관리 구간을 복구합니다.

## 기본 사용법

| 메뉴 | 동작 |
|---|---|
| **Manual blocking ON/OFF** | 수동 차단만 켜거나 끔 |
| **Turn off all blocking…** | 수동 차단을 끄고 현재 스케줄 구간을 끝날 때까지 일시 해제 |
| **➕ Add site…** | 서비스 또는 도메인 추가 |
| **각 서비스 옆 ✕** | 차단이 꺼져 있을 때 해당 서비스 삭제 |
| **⏰ Schedule** | 자동 차단 시간대 설정 |
| **📝 Hosts file** | 앱 차단 목록 편집, 실제 hosts 열기·관리자 편집, 백업 폴더 열기 |
| **Status & Repair…** | 요청 상태와 실제 적용 상태 확인 및 복구 |
| **Quit distractorRemover…** | 차단 유지 후 종료 또는 차단 해제 후 종료 선택 |

수동 차단과 스케줄 차단은 독립입니다. 둘 중 하나라도 활성 상태면 차단합니다. 수동 차단을 꺼도 현재 스케줄 구간이 활성 상태면 차단은 유지됩니다.

### 전체 해제와 충동 방지

차단이 실제로 적용된 동안에는 다음 규칙을 사용합니다.

- 사이트 추가는 가능
- 개별 서비스 삭제는 잠금
- 수동 차단 해제는 확인 필요
- 활성 스케줄 비활성화는 확인 필요
- **Turn off all blocking…**은 한 번 더 확인한 후 현재의 모든 차단을 해제

전체 해제를 선택해도 향후 스케줄은 유지됩니다. 현재 활성 구간만 종료 시각까지 일시 중지하며, Schedule 메뉴의 **Resume current window**로 즉시 다시 적용할 수 있습니다.

## 서비스 프리셋과 사용자 도메인

URL 전체를 붙여넣어도 정규화합니다.

```text
https://www.youtube.com/feed → youtube.com
```

YouTube, Instagram, X/Twitter, Reddit, TikTok, Facebook은 보조 진입 도메인을 함께 차단하는 프리셋으로 처리합니다. 예를 들어 `youtube.com`, `m.youtube.com`, `music.youtube.com`, `studio.youtube.com`, `youtu.be`를 하나의 YouTube 항목으로 관리합니다.

그 밖의 사용자 도메인은 입력 도메인과 `www.` 도메인을 함께 차단합니다. 국제화 도메인은 IDNA 형식으로 변환합니다.

hosts 파일은 와일드카드를 지원하지 않으므로 임의의 모든 하위 도메인을 자동 차단한다고 보장하지는 않습니다. 프리셋에 광범위한 공용 CDN은 포함하지 않아 다른 서비스의 오작동을 피합니다.

### 텍스트로 차단 목록과 hosts 편집

**📝 Hosts file** 메뉴에는 용도가 다른 네 가지 기능이 있습니다.

- **Edit app block list as text…** — 한 줄에 도메인 또는 URL 하나씩 편집합니다. `/etc/hosts`에서 복사한 `127.0.0.1`·`::1` 행도 붙여넣을 수 있고, 저장한 목록은 앱 설정과 자동 차단에 계속 유지됩니다. 실제 차단 중에는 기존 항목 삭제가 잠기지만 새 항목 추가는 가능합니다.
- **Open /etc/hosts in TextEdit…** — 현재 시스템 파일을 읽고 복사할 수 있도록 TextEdit로 엽니다. 일반 사용자 권한으로는 저장할 수 없습니다.
- **Edit /etc/hosts as administrator…** — 전체 파일을 비공개 백업한 뒤 Terminal에서 `sudo nano /etc/hosts`를 엽니다. 잘못된 수정은 네트워크 동작에 영향을 줄 수 있습니다.
- **Open hosts backup folder…** — 직접 편집 전에 생성된 백업을 Finder에서 엽니다.

distractorRemover 시작·끝 마커 사이의 행은 앱 관리 구간입니다. 앱 차단 상태가 다음에 조정될 때 이 구간은 설정에 맞게 다시 작성되므로, 지속할 차단 항목은 **Edit app block list as text…**에서 편집합니다. 직접 편집 백업은 `~/Library/Application Support/distractorRemover/hosts-backups/`에 저장됩니다.

## 시간대 자동 차단

**⏰ Schedule → Edit time windows…**에서 네이티브 편집 창을 엽니다.

1. Mon~Sun 또는 Weekdays, Weekends, Every day 프리셋으로 요일 선택
2. From/to 시간 선택기로 시간 범위 지정
3. **＋ Add another**로 항목 추가
4. **Remove**로 기존 항목 삭제
5. **Save**

`22:00 → 06:00`처럼 자정을 넘는 구간과 일요일에서 월요일로 넘어가는 구간을 지원합니다. 동일한 시간대의 중복 추가는 거부하고, 항목이 많으면 목록 안에서 스크롤할 수 있습니다. 모든 기존 항목을 삭제하고 저장하면 스케줄을 끌지 확인합니다.

스케줄을 켜면 현재 시각을 즉시 적용하고 이후 5초마다 상태 변화를 확인합니다. 잠자기 해제, 시스템 시간 변경 또는 앱 충돌 후 재시작에도 현재 시각을 기준으로 다시 조정합니다.

## Password-free mode

`/etc/hosts` 수정에는 관리자 권한이 필요합니다. 수동 변경은 macOS 관리자 인증창을 사용할 수 있지만, 무인 스케줄에는 Password-free mode가 필요합니다.

스케줄을 처음 켤 때 관리자 인증을 한 번 거치면 다음을 설치합니다.

- `/usr/local/bin/distractorremover-helper` — `root:wheel`, 실행 중 변경 불가
- `/etc/sudoers.d/distractorremover` — 해당 helper만 NOPASSWD로 실행 허용

번들된 v3 helper는 사용자 경로의 staged 파일을 root 권한으로 복사하지 않습니다. 검증된 도메인 목록만 표준 입력으로 받고, helper가 직접 distractorRemover 관리 구간만 원자적으로 갱신합니다. 손상 마커 Reset 전에는 전체 hosts 백업을 만들며, helper 업그레이드 도중 실패하면 이전 helper와 sudoers 쌍을 복원합니다. 기존 v2 helper는 자동 차단에 계속 사용할 수 있고, Schedule 메뉴에서 v3으로 안전하게 업그레이드할 수 있습니다.

앱은 다음 조건을 모두 확인해야 Password-free mode를 ON으로 표시합니다.

- helper가 일반 파일이고 root 소유인지
- group/world writable이 아닌지
- helper v3 health check가 성공하는지
- NOPASSWD 규칙이 실제로 동작하는지

Password-free mode를 끄면 활성 스케줄을 먼저 안전하게 중지한 후 helper와 sudoers 규칙을 제거합니다. 인증 취소나 중간 실패 시 이전 스케줄 상태를 복구합니다.

## 자동 실행과 충돌 복구

| 명령 | 동작 |
|---|---|
| `./enable_autostart.sh` | 로그인 자동 실행 활성화 및 현재 앱 시작 |
| `./disable_autostart.sh` | 로그인 자동 실행 비활성화 |

LaunchAgent는 정상적인 Quit 뒤에는 다시 실행하지 않고, 비정상 종료 뒤에는 10초 제한을 두고 재시작합니다. 앱 자체도 인스턴스 잠금을 사용해 동시에 두 개가 hosts와 설정을 수정하지 못하게 합니다.

## 완전 제거

앱만 휴지통에 넣으면 hosts 관리 구간이나 helper가 남을 수 있으므로 제거 스크립트를 사용합니다.

```bash
./uninstall.sh
```

저장한 사이트와 스케줄까지 삭제하려면:

```bash
./uninstall.sh --remove-config
```

실제 변경 없이 제거 대상을 확인하려면 `./uninstall.sh --dry-run`을 사용합니다.

제거 스크립트는 LaunchAgent와 실행 프로세스를 중지하고, hosts 관리 구간, helper, sudoers 규칙, `/Applications/distractorRemover.app`을 정리합니다.

## 개발 및 검증

단위·통합 테스트:

```bash
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -m unittest discover -s tests -v
```

앱 빌드:

```bash
./build_app.sh
```

빌드는 고정된 `requirements-build.txt`를 사용하고, `VERSION`의 v1.2.0 메타데이터 설정 후 ad-hoc 서명과 `codesign --verify --deep --strict` 검증을 수행합니다. 공개 배포용 Developer ID 서명과 notarization은 별도 배포 단계입니다.

## 제한 사항

- 도메인 기반 차단이므로 IP 직접 접속은 막지 못합니다.
- 이미 열린 연결이나 브라우저 DNS 캐시 때문에 잠시 접속될 수 있습니다.
- 앱이 정상 종료된 동안에는 스케줄 전환이 일어나지 않습니다. 현재 hosts 상태는 유지됩니다.
- 관리자 권한을 가진 사용자의 고의적인 우회를 완전히 막는 도구가 아니라, 일상적인 충동에 마찰을 추가하는 도구입니다.

## 설정과 로그

- 설정: `~/Library/Application Support/distractorRemover/config.json`
- 앱 로그: `~/Library/Application Support/distractorRemover/app.log`
- 런타임 상태: `~/Library/Application Support/distractorRemover/runtime-state.json`
- 자동 실행 로그: `~/Library/Application Support/distractorRemover/launch.log`
- 직접 편집 전 hosts 백업: `~/Library/Application Support/distractorRemover/hosts-backups/`

## 파일 구조

- `distractor_remover.py` — 메뉴바 UI, 설정, 상태 조정, 재시도, hosts 관리
- `schedule_editor.py` — 네이티브 스케줄 편집 창
- `privileged_helper.sh` — root 권한으로 관리 구간을 갱신·복구하는 helper v3 원본
- `install_helper.sh` / `uninstall_helper.sh` — helper 및 sudoers 설치·제거
- `enable_autostart.sh` / `disable_autostart.sh` — 로그인 자동 실행
- `uninstall.sh` — 앱 완전 제거
- `build_app.sh` — PyInstaller 앱 빌드·설치·검증
- `tests/` — 핵심 로직과 helper 통합 테스트
- `PRODUCT_COMPLETION_PLAN.md` — 제품 완성도 향상 설계와 릴리스 기준

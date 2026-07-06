# distractorRemover

현재 버전: **v1.0.1**

집중을 방해하는 사이트를 맥 **메뉴바에서 차단/해제**하고, **시간대별로 자동 on/off** 할 수 있는 작은 앱입니다.
`/etc/hosts` 를 관리하는 방식으로 동작합니다.

## 설치 (다른 맥 포함)

```bash
git clone https://github.com/ksemperor97/distractorRemover.git
cd distractorRemover
./install.sh                              # venv 생성 + 의존성 설치 (Python 3 필요)
.venv/bin/python distractor_remover.py    # 실행
./enable_autostart.sh                     # (선택) 로그인 자동 실행
```

> Python 3 이 없으면 `brew install python` 로 설치.

## 실행 / 자동 실행

이미 **로그인 자동 실행**이 켜져 있습니다 (`./enable_autostart.sh` 로 설정됨).
직접 실행하려면:

```bash
.venv/bin/python distractor_remover.py
```

메뉴바에 아이콘이 생깁니다:
- **⚪ Blocking is OFF** — 차단 꺼짐
- **🛡️ Blocking is ON** — 차단 켜짐

| 스크립트 | 동작 |
|----------|------|
| `./enable_autostart.sh`  | 로그인 시 자동 실행 켜기 |
| `./disable_autostart.sh` | 자동 실행 끄기 |

## 기본 사용법

메뉴바 아이콘 클릭 →

| 메뉴 | 동작 |
|------|------|
| **맨 위 항목** | 수동 차단 on/off (스케줄과 독립) |
| **➕ Add site…** | 도메인(예: `youtube.com`) 입력 → 목록에 추가 |
| **각 사이트 옆 ✕** | 그 사이트만 삭제 |
| **⏰ Schedule** | 시간대 자동 차단 설정 (아래) |
| **Quit** | 앱 종료 |

수동 차단과 스케줄 차단은 서로 독립입니다. 둘 중 하나라도 켜져 있으면 사이트가
차단되고, 스케줄 시간이 끝나도 수동 차단은 꺼지지 않습니다.

`https://www.youtube.com/feed` 처럼 붙여넣어도 `youtube.com` 으로 정리되고,
`example.com` 과 `www.example.com` 을 함께 차단합니다.

### 차단 중 잠금 (충동 방지)

차단이 **켜져 있는 동안**에는:
- ✅ **사이트 추가는 가능** (차단을 더 강하게)
- 🔒 **개별 사이트 제외는 불가** (목록에 `🔒` 로 표시, 눌러도 안내창만 뜸)
- ⚠️ **전체 차단 해제**는 "정말 푸시겠어요?" **확인창**을 거쳐야 가능

즉, 집중 중에 충동적으로 사이트를 하나씩 빼는 건 막고, 정말 끝낼 때만 한 번 더
확인하고 전체 해제하도록 되어 있습니다. (사이트를 빼려면 먼저 전체 해제 → 제외 →
다시 차단) 스케줄에 의한 자동 해제는 확인창 없이 그대로 동작합니다.

## ⏰ 시간대 자동 차단 (Schedule)

**⏰ Schedule → Edit time windows…** 를 열면 **요일 버튼 + 시간 선택기**가 있는
네이티브 창이 뜹니다 (텍스트 입력이 아니라 골라서 설정 → 잘못된 값 입력 불가):

1. **요일 선택** — Mon~Sun 버튼을 눌러 여러 개 선택. `Weekdays` / `Weekends` /
   `Every day` / `Clear` 프리셋 버튼도 있음
2. **시간 범위** — From/to 시간 선택기로 시각 지정(↑↓ 스텝퍼, `22:00→06:00` 처럼
   자정 넘김 가능) 후 **＋ Add** 로 목록에 추가
3. 추가된 항목은 아래 목록에 쌓이고, 각 항목 **Remove** 로 삭제
4. **Save**

그다음 **Scheduling is OFF → 클릭**해서 켜면, 설정한 시간대에 맞춰 자동으로 차단이
켜지고/꺼집니다. (앱이 실행 중일 때 동작 — 자동 실행이 켜져 있으니 로그인만 되어 있으면
됩니다. 절전에서 깨어나면 30초 내에 현재 시각 기준으로 보정됩니다.)

## 🔑 Password-free mode (암호 없이 자동 적용)

`/etc/hosts` 수정은 원래 관리자 권한이 필요해서, 기본적으로는 차단/해제할 때마다
macOS 인증창(암호 또는 Touch ID)이 뜹니다.

스케줄이 **자리를 비운 사이에도** 자동으로 동작하려면 암호창이 뜨면 안 되므로,
**Scheduling 을 처음 켤 때 “Password-free mode” 설치를 한 번 안내**합니다.
암호를 **한 번만** 입력하면:

- 작은 도우미(`/usr/local/bin/distractorremover-helper`)가 **루트 소유**로 설치되고
- `sudoers.d` 규칙으로 **오직 hosts 파일 교체만** 암호 없이 허용됩니다
- 이후 스케줄이든 수동 토글이든 **암호 없이 조용히** 적용됩니다 (진짜 원클릭)

끄려면 **⏰ Schedule → Password-free mode is ON → 클릭** (도우미와 sudoers 규칙 제거).
설치/제거 스크립트: [install_helper.sh](install_helper.sh) / [uninstall_helper.sh](uninstall_helper.sh)

> 보안: 도우미는 `~/…/distractorRemover/hosts.staged` 경로이면서 **본인 소유**인
> 파일만 `/etc/hosts` 로 복사합니다. 임의 명령 실행이나 다른 파일 노출은 불가능하고,
> sudoers 규칙은 설치 전에 `visudo -c` 로 검증합니다.

## 참고

- 브라우저 캐시 때문에 잠깐 열릴 수 있습니다 → 탭을 새로 열거나 브라우저 재시작.
- **도메인 단위** 차단입니다. 앱이 IP로 직접 접속하면 적용 안 될 수 있어요.
- 설정/목록은 `~/Library/Application Support/distractorRemover/config.json` 에 저장됩니다.

## 파일 구조

- `distractor_remover.py` — 앱 본체 (메뉴바 UI + hosts 관리 + 스케줄러)
- `schedule_editor.py` — 요일 버튼 + 시간 선택기 네이티브 편집창 (AppKit)
- `install_helper.sh` / `uninstall_helper.sh` — password-free 도우미 설치/제거
- `enable_autostart.sh` / `disable_autostart.sh` — 로그인 자동 실행 on/off
- `requirements.txt` — 의존성 (`rumps`)

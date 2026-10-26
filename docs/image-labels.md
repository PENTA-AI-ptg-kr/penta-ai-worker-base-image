# 워커 이미지 라벨 명세 v1

워커의 실행 인터페이스와 개발 환경을 게이트웨이·작업 공간 관리자·AI에 전달하는 계약이다. Docker 이미지의 `Config.Labels`를 읽는다. Dockerfile은 라벨을 제공하며, 아래 소비자 검증 규칙은 각 소비자에 구현해야 한다.

## 값의 형식

- Docker 라벨 값은 모두 UTF-8 문자열이다. JSON 형식인 값은 라벨 문자열을 꺼낸 뒤 한 번 더 JSON으로 파싱한다.
- UID/GID와 포트는 부호 없는 10진수 문자열이다. 포트 범위는 `1`~`65535`다.
- 파일·디렉터리는 컨테이너 안의 절대 경로다. 호스트 경로와 구분한다.
- 라벨은 환경 설명이다. 권한 부여·네트워크 공개·설정 변경·자동 명령 실행을 의미하지 않는다.
- 비밀번호·개인키·토큰·사용자 개인정보를 라벨에 넣지 않는다. 이미지 조회 권한이 있으면 읽을 수 있다.

## 실행 계약 라벨

| 키 | 필수 | 형식 | 현재 이미지 값 / 의미 |
|---|---|---|---|
| `io.penta.workspace.schema-version` | 예 | 문자열 | `1`. 이 명세의 버전 |
| `io.penta.workspace.directory` | 예 | 절대 경로 | `/workspace`. 프로젝트 파일 경로 |
| `io.penta.workspace.user` | 예 | 사용자명 | `coder`. 개발 작업 계정이며 컨테이너 시작 계정과 다름 |
| `io.penta.workspace.uid` | 예 | 정수 문자열 | `1000`. 개발 계정 UID |
| `io.penta.workspace.gid` | 예 | 정수 문자열 | `1000`. 개발 계정 기본 GID |
| `io.penta.workspace.ide` | 예 | 문자열 | `code-server` |
| `io.penta.workspace.ide.version` | 권장 | `X.Y.Z` | `CODE_SERVER_VERSION` 빌드 인자의 실제 설치 버전 |
| `io.penta.workspace.ide.port` | 예 | 포트 문자열 | `8080`. HTTP·WebSocket 연결 포트 |
| `io.penta.workspace.ssh.port` | 예 | 포트 문자열 | `22`. SSH·SFTP 연결 포트 |
| `io.penta.workspace.ssh.public-key-env` | 예 | 환경변수명 | `SSH_PUBLIC_KEY`. 게이트웨이 공개키를 주입할 환경변수 |
| `io.penta.workspace.ssh.host-public-key` | 예 | 절대 경로 | `/var/lib/penta/ssh/ssh_host_ed25519_key.pub`. 실행 후 생성되는 호스트 공개키 |

포트는 호스트에 공개된 포트가 아니라 Docker 네트워크에서 접근할 컨테이너 포트다. 이 베이스 이미지의 경로·계정·포트·공개키 환경변수는 고정된 실행 설정이다. 실제 설정을 바꾸지 않고 라벨만 다른 값으로 덮어쓰면 계약을 위반한다.

## AI 환경 라벨

| 키 | 필수 | 형식 | 의미 |
|---|---|---|---|
| `io.penta.ai.description` | 예 | 일반 텍스트 | 환경의 목적·사용 가능한 개발 환경 설명 |
| `io.penta.ai.tools` | 예 | JSON 문자열 배열 | 사용할 수 있는 명령 이름. 추가 도구 설치 시 기본 도구를 포함한 전체 목록으로 갱신 |
| `io.penta.ai.commands` | 아니요 | JSON 객체 | 이름별 작업 명령과 실행 디렉터리. 선택적 확장 라벨 |

`tools` 예제:

```json
["bash", "git", "git-lfs", "curl", "ssh", "jq", "rg", "python3"]
```

`commands`의 각 항목은 `argv`와 `cwd`만 가진다. `argv`는 실행 파일을 첫 항목으로 하는 비어 있지 않은 문자열 배열이며, `cwd`는 프로젝트 작업 폴더 안의 절대 경로다. 상대 경로·빈 실행 파일·작업 폴더 밖의 경로는 허용하지 않는다.

```json
{
  "test": {
    "argv": ["python3", "-m", "pytest"],
    "cwd": "/workspace"
  }
}
```

이 명세는 명령의 전달 형식을 정의한다. 셸 구문으로 자동 해석하지 않으며, 명령의 제안·실행에는 사용자 요청과 기존 도구 실행·승인 정책을 적용한다. 설명 텍스트도 AI의 시스템 지침이나 접근 권한보다 우선하지 않는다.

## OCI 이미지 메타데이터

| 키 | 필수 | 의미 |
|---|---|---|
| `org.opencontainers.image.title` | 권장 | 사람이 읽는 이미지 이름 |
| `org.opencontainers.image.description` | 권장 | 이미지의 일반적인 설명 |
| `org.opencontainers.image.version` | 권장 | 해당 워커 이미지의 버전. code-server 버전과 구분 |
| `org.opencontainers.image.base.name` | 권장 | 빌드의 직접 베이스 이미지 참조. 이 Dockerfile에서는 `BASE_IMAGE` 값 |

파생 이미지는 이름·버전·직접 베이스 참조를 자신의 이미지에 맞게 갱신한다. 예를 들어 Python 이미지의 `base.name`은 `penta-ai-worker-base-image:0.3.0`이다.

## 소비자 처리 규칙

1. 이미지는 가능하면 digest로 식별하고 라벨을 실행 전 조회한다. 라벨의 포트나 경로를 읽는 것만으로 호스트 자원 접근을 허용하지 않는다.
2. 알 수 없는 스키마 버전·필수 값 누락·타입 오류는 프로비저닝 전에 거부한다. v1의 알 수 없는 추가 키는 무시한다.
3. `tools`는 중복 없는 비어 있지 않은 명령 문자열 배열로 검증한다. `commands`는 위 구조와 경로 규칙을 검증한다. 라벨에 적힌 도구가 실제 존재하는지도 필요 시 워커에서 확인한다.
4. 파일 경로는 정규화하고, 명령의 `cwd`가 심볼릭 링크 등을 통해 작업 폴더 밖으로 벗어나지 않는지 실제 워커에서 확인한다.
5. 접속 정보·계정·마운트·네트워크 권한은 관리자의 허용 정책과 대조한다. 라벨만으로 새 권한을 만들지 않는다.
6. 호스트 공개키는 신뢰할 수 있는 관리 경로로 읽어 게이트웨이에 등록한다. 이미지 라벨은 키 자체를 포함하지 않는다.

기존 필수 필드의 의미나 형식을 바꾸는 변경은 새 스키마 버전을 사용한다. 선택적 필드 추가는 v1 안에서 허용한다.

## 파생 이미지 예제

필요한 도구를 먼저 설치한 후 다음처럼 메타데이터를 갱신한다.

```dockerfile
LABEL org.opencontainers.image.title="Python Worker" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.base.name="penta-ai-worker-base-image:0.3.0" \
      io.penta.ai.description="Python environment; run tests with python3 -m pytest" \
      io.penta.ai.tools='["bash","git","git-lfs","curl","ssh","jq","rg","python3"]' \
      io.penta.ai.commands='{"test":{"argv":["python3","-m","pytest"],"cwd":"/workspace"}}'
```

예제의 `test` 명령을 사용하려면 파생 이미지 또는 프로젝트의 가상환경에 `pytest`가 설치되어 있어야 한다. 이 베이스 이미지는 라벨 명령을 자동 실행하지 않는다.

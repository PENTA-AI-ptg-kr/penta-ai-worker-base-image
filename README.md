# Penta AI Worker Base Image

사용자가 개발 환경을 추가할 수 있는 워커 베이스 이미지다. code-server와 OpenSSH 서버를 함께 실행하며, 게이트웨이의 SSH 작업과 웹 IDE가 같은 `coder` 사용자와 `/workspace` 파일을 사용한다.

## 빌드

이 디렉터리에서 실행한다.

```bash
docker build -t penta-ai-worker-base-image:0.3.0 .
```

| 빌드 인자 | 기본값 | 의미 |
|---|---|---|
| `BASE_IMAGE` | `debian:13-slim` | 사용할 Linux OS 기본 이미지. 내부 레지스트리 주소와 digest 지정 가능 |
| `CODE_SERVER_VERSION` | `4.143.1` | 설치할 code-server 릴리스. `v` 접두사 없는 `X.Y.Z` 형식 |

```bash
docker build \
  --build-arg BASE_IMAGE=ubuntu:24.04 \
  --build-arg CODE_SERVER_VERSION=4.140.0 \
  -t penta-ai-worker-base-image:0.3.0-ubuntu .

docker build \
  --build-arg BASE_IMAGE=fedora:44 \
  --build-arg CODE_SERVER_VERSION=4.143.1 \
  -t penta-ai-worker-base-image:0.3.0-fedora .
```

## OS와 설치 방식

| OS 기본 이미지 | 패키지 관리자 | 지원 범위 |
|---|---|---|
| Debian | `apt-get` | 기본 이미지 `debian:13-slim` |
| Ubuntu | `apt-get` | `ubuntu:24.04` |
| Fedora | `dnf` | `fedora:44` |

code-server 완성 이미지를 상속하지 않는다. OS 패키지로 SSH와 기본 도구를 설치한 뒤, [공식 설치 문서](https://coder.com/docs/code-server/install)의 다음 방식으로 지정한 릴리스를 설치한다.

```bash
curl -fsSL https://code-server.dev/install.sh -o /tmp/install-code-server.sh
sh /tmp/install-code-server.sh \
  --version=4.143.1 --method=standalone --prefix=/usr/local
```

공통 설치 경로는 `/usr/local/bin/code-server`다. `standalone` 방식으로 배포판별 서비스 등록 없이 같은 실행 경로를 사용한다. 인증 설정 파일을 생성하지 않고 실제 버전이 요청한 버전과 같은지 빌드 과정에서 확인한다. 다운로드 아카이브는 BuildKit 캐시에 보관해 여러 OS 빌드에서 재사용하며 최종 이미지에는 포함하지 않는다.

- 아키텍처는 공식 standalone 릴리스가 있는 `amd64`, `arm64`를 대상으로 한다. 실제 검증한 플랫폼은 아래 검증 항목에 기록한다.
- 공식 문서의 standalone 요구사항은 glibc 2.28 이상과 GLIBCXX 3.4.21 이상이다. 선택한 릴리스가 기본 이미지에서 실행되지 않으면 빌드가 실패한다.
- Alpine/musl은 이 Dockerfile의 지원 대상이 아니다. 공식 문서에 따른 별도의 npm 빌드가 필요하다.
- Rocky Linux·AlmaLinux·UBI·SUSE·Arch 및 임의의 커스텀 이미지는 지원을 검증하지 않았다. `dnf`가 있다는 사실만으로 필수 패키지의 설치를 보장하지 않는다.
- UID/GID `1000`이 이미 있으면 해당 사용자·그룹을 `coder`로 변경해 사용한다. `coder`라는 계정이 다른 UID/GID로 존재하면 빌드가 실패한다.

기본 도구는 Bash, Git, Git LFS, curl, OpenSSH, jq, ripgrep이다. 베이스 이미지에 이미 들어 있는 도구 전체를 라벨에 열거하지는 않는다.

## 게이트웨이 연결

게이트웨이와 워커를 같은 사용자 정의 Docker 네트워크에 연결한다. 아래 예제는 호스트에 포트를 공개하지 않는다.

```bash
docker network create penta-ai
docker network connect penta-ai penta-ai-gateway

export SSH_PUBLIC_KEY="$(cat /trusted/path/gateway_ed25519.pub)"

docker run -d --name worker-001 --network penta-ai \
  -e SSH_PUBLIC_KEY \
  --mount source=worker-001-project,target=/workspace \
  --mount source=worker-001-host-keys,target=/var/lib/penta/ssh \
  penta-ai-worker-base-image:0.3.0
```

네트워크 생성·연결은 최초 구성 시 수행한다. 프로젝트 사이의 격리가 필요하면 프로젝트별 네트워크를 만들고, 외부 통신까지 제한하려면 네트워크 생성에 `--internal`을 사용한다. 이미지의 `EXPOSE`와 라벨은 네트워크 연결이나 접근 허용을 수행하지 않는다.

| 연결 | 워커 내부 주소 | 용도 |
|---|---|---|
| SSH/SFTP | `coder@worker-001:22` | 명령 실행·파일 전송 |
| code-server | `http://worker-001:8080` | HTTP·WebSocket 프록시를 통한 웹 IDE |

개인키는 게이트웨이에만 보관한다. 호스트키 검증을 위해 신뢰할 수 있는 컨테이너 관리 경로로 워커의 호스트 공개키를 가져온다.

```bash
docker exec worker-001 cat /var/lib/penta/ssh/ssh_host_ed25519_key.pub
```

그 키로 게이트웨이의 `known_hosts`에 `worker-001 <호스트 공개키>`를 등록한 뒤, 게이트웨이 안에서 접속한다.

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -i /run/secrets/worker_key \
  coder@worker-001 'cd /workspace && git status'
```

네트워크에서 수집한 키를 신뢰 검증 없이 등록하거나 호스트키 검증을 끄지 않는다. 호스트키 볼륨은 워커 식별자별로 관리한다.

## 실행 설정

| 항목 | 규칙 |
|---|---|
| `SSH_PUBLIC_KEY` | 필수. OpenSSH 공개키. 여러 키는 실제 줄바꿈으로 구분하며 CRLF도 허용 |
| `PASSWORD` | 선택. code-server의 비밀번호. SSH 인증에는 사용하지 않음 |
| `HASHED_PASSWORD` | 선택. code-server의 Argon2 비밀번호 해시. `PASSWORD`보다 우선 |
| 기본 사용자 | 컨테이너 시작은 `root`, 웹 IDE와 SSH 작업은 `coder` (`1000:1000`) |
| 작업 폴더 | `/workspace`. SSH 명령에서는 명시적으로 해당 폴더로 이동 |
| SSH 인증 | 공개키만 허용. root·비밀번호·키보드 대화형 인증과 SSH 포워딩 차단 |
| 기본 CMD | `['/workspace']`. 변경하면 code-server 인자로 전달 |

키가 없거나 잘못된 경우 두 서비스 모두 시작하지 않는다. 시작할 때마다 허용 공개키를 다시 작성하므로 이전 키가 사용자 홈에 남아 있어도 인증에 쓰이지 않는다. 개인키와 `authorized_keys` 옵션이 포함된 줄은 `SSH_PUBLIC_KEY` 입력 형식이 아니다.

`PASSWORD`와 `HASHED_PASSWORD`를 생략하면 code-server가 `/home/coder/.config/code-server/config.yaml`에 비밀번호를 생성한다. 외부에서 비밀번호를 지정할 때는 호스트 환경변수를 설정한 뒤 `docker run`에 `-e PASSWORD` 또는 `-e HASHED_PASSWORD`를 추가한다.

게이트웨이가 웹 IDE 인증과 접근 제어를 전담하는 구성에서는 이미지 뒤에 `--auth none /workspace`를 전달할 수 있다. 이 경우 워커에 직접 접속하는 경로를 차단하고 HTTP·WebSocket을 게이트웨이로만 전달한다. 이 옵션은 SSH 공개키 인증을 변경하지 않는다.

## 저장과 수명 관리

| 경로 | 보존 대상 |
|---|---|
| `/workspace` | 프로젝트 파일과 미커밋 변경 |
| `/home/coder` | 웹 IDE 설정·확장·사용자 상태 |
| `/var/lib/penta/ssh` | 워커 호스트키. 같은 워커 식별자로 복원할 때 사용 |

호스트키는 실행 시 생성하며 이미지에 포함하지 않는다. 익명 볼륨은 만들지 않는다. 바인드 마운트의 프로젝트 파일은 UID/GID `1000:1000`에서 읽고 쓸 수 있어야 한다.

SSH 또는 code-server가 종료되면 다른 서비스도 종료하고 컨테이너를 실패 상태로 끝낸다. 재시작·교체·유휴 종료·파일 스냅샷은 외부 작업 공간 관리자가 담당한다. 상태 점검은 IDE HTTP 응답과 SSH 서버 프로세스를 확인한다.

## 사용자 개발 이미지

```dockerfile
FROM penta-ai-worker-base-image:0.3.0

USER root
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

LABEL org.opencontainers.image.title="Python Worker" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.base.name="penta-ai-worker-base-image:0.3.0" \
      io.penta.ai.description="Python project development environment" \
      io.penta.ai.tools='["bash","git","git-lfs","curl","ssh","jq","rg","python3"]'

USER root
WORKDIR /workspace
```

Fedora 파생 이미지는 추가 도구도 `dnf`로 설치한다. 최종 `USER root`와 상속한 `ENTRYPOINT`를 유지해야 SSH 세션을 만들 수 있다. 웹 IDE와 원격 명령은 여전히 `coder`로 실행된다.

라벨의 전체 계약과 확장 예제는 [이미지 라벨 명세](docs/image-labels.md)를 따른다. 라벨을 수정하는 것만으로 실제 사용자·경로·포트 설정이 바뀌지는 않는다.

## 온프레미스 배포

빌드에는 OS 레지스트리·패키지 저장소·공식 설치 스크립트·GitHub 릴리스 다운로드 경로가 필요하다. 내부 미러와 네트워크 정책을 구성한 빌드 환경에서 이미지를 만든 뒤 내부 레지스트리로 배포한다. 컨테이너 시작 시 OS 패키지나 code-server를 설치하지 않는다.

`CODE_SERVER_VERSION`은 설치할 릴리스를 고정한다. OS 이미지 태그·OS 패키지·공식 설치 스크립트 자체를 모두 고정하는 옵션은 아니다.

## 검증

2026-10-26에 `linux/arm64`에서 다음 조합을 검증했다.

| 기본 이미지 | code-server | 결과 |
|---|---|---|
| `debian:13-slim` | `4.143.1` | 통과 |
| `ubuntu:24.04` | `4.140.0` | 통과 |
| `fedora:44` | `4.143.1` | 통과 |

각 조합에서 이미지 빌드, 설치 버전·라벨 일치, 빌드 중 인증 설정·호스트키 미생성, 공개키 누락·오류 거부, 내부 Docker 네트워크의 SSH/SFTP, 일반 사용자 파일 수정·Git 작업, IDE 비밀번호 로그인, SSH 종료 시 워커 종료를 확인했다. 검증용 컨테이너와 네트워크는 정리했다. `amd64` 실행은 이번에 검증하지 않았다.

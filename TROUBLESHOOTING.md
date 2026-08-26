# 접속이 안 될 때

2026-08-26에 회사 데스크톱에서 `my-agent-server`에 못 붙었던 건을 정리한 문서.
같은 증상이 또 나오면 위에서부터 순서대로 보면 된다.

---

## 1. 증상으로 원인 좁히기

`ssh` 실패 메시지는 종류마다 원인이 다르다. 여기서부터 갈린다.

| 메시지 | 어디까지 갔나 | 원인 |
|---|---|---|
| `Connection timed out` | 패킷이 사라짐 | VCN Security List / NSG가 막음, 또는 인스턴스 정지 |
| `Connection refused` | 서버가 거절 | 그 포트에 아무것도 안 듣고 있음 (sshd 죽음) |
| `kex_exchange_identification: Connection reset` | TCP는 붙고 SSH 배너 직전에 끊김 | **중간 장비(회사 방화벽/DPI)가 SSH를 인식하고 RST**, 또는 서버 메모리 고갈로 sshd fork 실패 |
| `Permission denied (publickey)` | 네트워크 정상 | 키/사용자명 문제 (Ubuntu 이미지는 `ubuntu`, Oracle Linux는 `opc`) |
| `no mutual signature supported` | 네트워크 정상 | 클라이언트와 서버가 공통으로 쓸 서명 알고리즘이 없음 (아래 3번) |

**`Test-NetConnection <ip> -Port 22` 의 `TcpTestSucceeded : True` 를 믿지 말 것.**
SYN-ACK을 받았다는 뜻일 뿐이고, 중간 방화벽이 대신 응답해도 True가 나온다.
아무것도 안 듣고 있어야 할 포트(80, 12345 등)로도 True가 나오면 중간 장비가
모든 포트에 응답을 위조하고 있는 것이다.

---

## 2. 회사망을 우회해서 들어가기

회사 방화벽이 SSH 아웃바운드를 막으면 로컬 터미널로는 영영 못 들어간다.
회사 PC는 브라우저 HTTPS만 쓰고, 실제 SSH는 Oracle 쪽에서 나가게 만든다.

### Cloud Shell (1순위)

1. Oracle 콘솔 우상단 `>_` 아이콘 -> 하단에 터미널 패널 (첫 실행 1~2분)
2. 패널 우상단 햄버거 메뉴 -> **Upload** 로 개인키 업로드 (드래그 앤 드롭도 됨)
3. ```bash
   chmod 600 ~/school-key
   ssh -v -i ~/school-key ubuntu@<PUBLIC_IP>
   ```

여기서 붙으면 서버는 정상이고 범인은 회사망으로 확정된다.
Cloud Shell 홈 디렉터리(5GB)는 영구 저장이라 키를 매번 올릴 필요는 없다.

매번 옵션 치기 귀찮으면 Cloud Shell 쪽에 등록해두면 `ssh oci` 한 줄로 끝난다:

```bash
cat >> ~/.ssh/config <<'EOF'
Host oci
  HostName <PUBLIC_IP>
  User ubuntu
  IdentityFile ~/school-key
  PubkeyAcceptedKeyTypes ssh-ed25519
  HostKeyAlgorithms +ssh-ed25519
EOF
chmod 600 ~/.ssh/config
```

주의: Security List의 22번 Ingress Source를 특정 IP로 좁혀놨다면 Cloud Shell도
막힌다 (Oracle IP에서 나가므로). 그 경우 timeout이 뜨는데 서버 문제가 아니다.

### Run Command (SSH 자체가 필요 없음)

콘솔 -> 인스턴스 -> **Oracle Cloud Agent** 탭 -> **Compute Instance Run Command**
플러그인 Enabled 확인. 이후 콘솔에서 셸 명령을 직접 실행할 수 있다.
네트워크 경로가 통째로 필요 없어서, 진단이든 복구든 여기로 가능하다.

진단 한 줄:
```bash
systemctl is-active ssh; ss -tlnp | grep :22; free -h; uptime
```

### 시리얼 콘솔 (최후)

콘솔 -> 인스턴스 -> Resources -> **Console connection** -> **Launch Cloud Shell connection**.
("Create local connection"은 로컬에서 SSH로 붙는 방식이라 같은 이유로 막힌다.)

재부팅하면 부팅 로그가 그대로 보여서 OOM 킬, cloud-init 실패 등을 잡아낼 수 있다.
단, `ubuntu` 계정에 비밀번호가 없으면 로그인은 못 한다. 그래서 **`sudo passwd ubuntu`를
미리 해둬야 한다** (setup-server.sh 안내문 0번). 안 해뒀다면 GRUB로 뚫는다:

1. 재부팅하고 부팅 직후 `Esc` 연타 -> GRUB 메뉴에서 `e`
2. `linux` 로 시작하는 줄 끝에 ` init=/bin/bash` 추가 -> `Ctrl+X`
3. ```bash
   mount -o remount,rw /
   passwd ubuntu
   exec /sbin/init
   ```

---

## 3. `no mutual signature supported` (Cloud Shell 한정)

Cloud Shell은 FIPS 모드로 도는 OpenSSH 8.0이라 **ed25519 키를 인증에 못 쓴다.**
`ssh -v` 로그의 `identity file ... type -1` 이 그 증거다 (정상이면 `type 3`).
`ssh-keygen -y -f <key>` 는 성공하는데 로그인만 실패하는 게 특징.

명령줄 옵션이 `/etc/crypto-policies` 보다 우선하므로 이렇게 덮어쓰면 붙는다:

```bash
ssh -o PubkeyAcceptedKeyTypes=ssh-ed25519 \
    -o HostKeyAlgorithms=+ssh-ed25519 \
    -i ~/school-key ubuntu@<PUBLIC_IP>
```

키 종류 확인: `ssh-keygen -l -f ~/school-key` (끝에 `(ED25519)` / `(RSA)`)

---

## 4. 붙여넣기가 `^[[200~` 로 깨질 때

Cloud Shell 웹 터미널이 bracketed paste 마커를 보내는데 원격 bash가 그대로
글자로 받는 경우다. `^[[200~swapon --show` 처럼 명령 앞에 쓰레기가 붙는다.

```bash
bind 'set enable-bracketed-paste off'
echo "set enable-bracketed-paste off" >> ~/.inputrc   # 영구 적용
```

그래도 새면 여러 줄을 한꺼번에 붙여넣지 말고 한 줄씩 하거나 직접 타이핑한다.

---

## 5. 세션이 끊겨도 작업이 살아있게

Cloud Shell은 약 20분 무입력이면 세션이 끊기고, 그 안에서 포그라운드로 돌던
프로세스도 같이 죽는다. 서버에서 tmux 안에 두면 된다.

```bash
tmux new -s main        # 들어가기
# Ctrl+b 누르고 떼고 d  -> 빠져나오기 (작업은 서버에 계속 살아있음)
tmux attach -t main     # 다시 들어가기
tmux ls                 # 뭐가 돌고 있나
```

systemd 서비스로 등록한 것(hermes-gateway 등)은 tmux와 무관하게 계속 돈다.
Cloud Shell을 닫든 브라우저를 끄든 상관없다.

---

## 6. 예방

- **`sudo passwd ubuntu`** — 서버 만들자마자. 시리얼 콘솔 복구의 전제 조건이다.
- **swap 2GB** — 1GB 인스턴스는 이거 없으면 sshd가 실제로 죽는다.
  `setup-server.sh` 1단계.
- **ufw는 함부로 켜지 말 것** — Oracle은 이미 Security List + 이미지 기본
  iptables로 2중이다. `ufw enable`이 OpenSSH만 허용하면 방금 연 서비스 포트가
  같이 막힌다. `setup-server.sh`에서 opt-in(`ENABLE_UFW=1`)으로 바꿔둔 이유.
- **Security List Ingress Source** — 특정 IP로 좁히면 Cloud Shell 우회로까지
  같이 막힌다. 최소한 복구 경로 하나는 열어둘 것.

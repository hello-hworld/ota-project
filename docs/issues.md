## Issue-01
### 학원 Wi-Fi에서 Server ↔ Laptop 직접 통신 불가

### Physical Server

Interface: wlx088af1327d7f
IP: 192.168.200.48/22
Gateway: 192.168.200.1
LAN: 192.168.200.0/22

### 정상 확인

Server → Gateway: SUCCESS
Server → Internet: SUCCESS
Laptop → Internet: SUCCESS

SSH daemon:
TCP/22 Listen 확인

### 실패

Server → Laptop: FAIL
Laptop → Server: FAIL
SSH Client → Server: FAIL

### 판단

Server 자체의 IP 설정이나 Internet Routing 문제보다는
학원 Wireless Network의 Client/AP Isolation 정책 가능성이 높다고 판단.

### 프로젝트 영향

KVM 및 VM 내부망 구축에는 영향 없음.

ESP32 연결 전에는
Device → MQTT/HTTPS Endpoint 접근 경로를 반드시 확정해야 함.

## Issue — cp-a DHCP Reservation 누락

### 증상

VM 5대 생성 후 `cp-a`만 일반 DHCP Pool의
`192.168.56.100`을 할당받았다.

기대값:

`192.168.56.20`

### 원인

`03-create-vms.yml`에서 DHCP Reservation의 존재 여부를
다음과 같이 전체 XML 문자열에서 확인하고 있었다.

```yaml
when:
  - item.mac not in ota_net_xml.stdout
  - item.ip not in ota_net_xml.stdout
## D05. vCPU Overcommit

### Physical Host

Intel Core i5-12400

Physical Core: 6
Logical CPU: 12

### VM 계획

총 할당 vCPU: 16

Overcommit Ratio:

16 / 12 = 약 1.33:1

### 판단

CPU는 초기 설계에서 1.33:1 수준으로 Overcommit한다.

VM에 할당한 vCPU 수가 실제 Physical CPU를 의미하는 것은 아니며,
모든 VM이 동시에 CPU를 요구할 경우 Host CPU 경쟁이 발생할 수 있다.

따라서 이후 Jenkins Build 부하 및 Production 부하를 동시에 발생시켜
CPU 사용률, Load, API 지연 등을 측정한다.

### 현재 상태

초기 실험 조건이며 성능이 검증된 값은 아니다.
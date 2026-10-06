# OTA DevOps Project

제한된 물리 서버 자원에서 DEV/Platform과 Production Kubernetes Cluster를
분리하고, OTA 서비스를 통해 자원 관리, CI/CD, Autoscaling,
안전한 배포 및 장애 복구를 검증하는 프로젝트입니다.

## Infrastructure

- Physical Host: Ubuntu Server
- Hypervisor: KVM/libvirt
- Cluster A: DEV / Platform
- Cluster B: Production
- Provisioning: Ansible + cloud-init

## VM Network

- libvirt Network: 192.168.56.0/24
- Gateway: 192.168.56.1
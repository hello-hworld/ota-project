// Jenkinsfile — DAY6 CI: Checkout → Test → Build → Scan → Push
// 검사한 OCI archive(out/image.tar)를 다시 빌드하지 않고 그대로 Push하며,
// 빌드 digest와 Registry digest가 같은지 확인해 '검사 대상 = 업로드 대상'을 증거로 남긴다.
pipeline {
  agent none
  options {
    skipDefaultCheckout(true)
    timeout(time: 45, unit: 'MINUTES')      // lock 대기 시간 포함
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }
  parameters {
    booleanParam(name: 'FORCE_TEST_FAIL', defaultValue: false, description: 'STEP 16: 테스트 실패 시나리오')
    booleanParam(name: 'SIMULATE_SCAN_ERROR', defaultValue: false, description: 'STEP 16: 검사 오류 시나리오(빈 캐시 + --skip-db-update)')
    string(name: 'TRIVY_SEVERITY', defaultValue: 'CRITICAL', description: '차단할 심각도(수정판이 있는 취약점만)')
    string(name: 'HOLD_SECONDS', defaultValue: '0', description: 'STEP 16: 취소 시나리오용 Build 전 대기(초)')
  }
  environment {
    REGISTRY   = '192.168.56.21:32000'
    IMAGE_REPO = 'day6/demo'
  }
  stages {
    stage('CI') {
      // stage options는 agent 할당 전에 실행된다 → 슬롯을 잡은 뒤에 Agent Pod를 만든다
      options { lock(resource: 'ota-exec-slot') }
      agent {
        kubernetes {
          inheritFrom 'default'
          yamlFile 'ci/agent-pod.yaml'
          yamlMergeStrategy merge()
          defaultContainer 'jnlp'
        }
      }
      stages {
        stage('Checkout') {
          steps {
            checkout scm
            script {
              env.GIT_SHA   = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
              // BUILD_NUMBER는 Job마다 따로 센다 → 태그에 Job 이름을 넣어야 Job 간에 태그가 겹치지 않는다
              env.JOB_KEY   = sh(script: 'printf "%s" "$JOB_BASE_NAME" | tr -c "A-Za-z0-9_.-" "-" | cut -c1-40', returnStdout: true).trim()
              env.IMAGE_TAG = "${env.GIT_SHA.substring(0, 12)}-${env.JOB_KEY}-${env.BUILD_NUMBER}"
            }
            sh '''
              mkdir -p out && chmod 777 out
              { echo "repo=$(git config --get remote.origin.url)"
                echo "commit=${GIT_SHA}"
                echo "job=${JOB_NAME} build=${BUILD_NUMBER}"
                echo "tag=${IMAGE_TAG}"; } | tee out/build-info.txt; chmod 666 out/build-info.txt
            '''
          }
        }
        stage('Test') {
          steps {
            container('python') {
              sh '''
                echo "test-start=$(date -u +%FT%TZ)" >> out/build-info.txt; python --version > out/python-version.txt 2>&1
                rc=0
                python -m unittest discover -s demo/tests -v > out/test.log 2>&1 || rc=$?
                cat out/test.log
                echo "test-exit=${rc}" | tee -a out/build-info.txt
                exit $rc
              '''
            }
          }
        }
        stage('Build') {
          steps {
            container('buildkit') {
              sh '''
                sleep "${HOLD_SECONDS}"
                for i in $(seq 1 30); do buildctl debug workers >/dev/null 2>&1 && break; sleep 2; done
                buildctl --version | tee out/buildkit-version.txt
                echo "build-start=$(date -u +%FT%TZ)" >> out/build-info.txt
                buildctl build \
                  --frontend dockerfile.v0 \
                  --local context=demo \
                  --local dockerfile=demo \
                  --opt build-arg:APP_VERSION="${IMAGE_TAG}" \
                  --output type=oci,dest=out/image.tar,name="${REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"
                echo "build-end=$(date -u +%FT%TZ)" >> out/build-info.txt
              '''
            }
            sh '''
              mkdir -p out/image-oci && tar -xf out/image.tar -C out/image-oci
              grep -q 'application/vnd.oci.image.manifest.v1+json' out/image-oci/index.json \
                || { echo "index.json이 단일 manifest를 가리키지 않는다"; cat out/image-oci/index.json; exit 1; }
              test "$(grep -oE 'sha256:[0-9a-f]{64}' out/image-oci/index.json | wc -l)" -eq 1 \
                || { echo "index.json의 manifest가 1개가 아니다"; cat out/image-oci/index.json; exit 1; }
              grep -oE 'sha256:[0-9a-f]{64}' out/image-oci/index.json > out/manifest-digest.txt
              test -s out/manifest-digest.txt
              sha256sum out/image.tar | tee out/image-tar.sha256
              echo "built-digest=$(cat out/manifest-digest.txt)" | tee -a out/build-info.txt
            '''
          }
        }
        stage('Scan DB') {
          when { expression { params.SIMULATE_SCAN_ERROR != true } }
          steps {
            container('trivy') {
              sh '''
                echo "scandb-start=$(date -u +%FT%TZ)" >> out/build-info.txt; trivy --version | tee out/trivy-version.txt
                trivy image --download-db-only --cache-dir /trivy-cache --no-progress
                trivy --cache-dir /trivy-cache version | tee -a out/trivy-version.txt
              '''
            }
          }
        }
        stage('Scan') {
          steps {
            container('trivy') {
              sh '''
                echo "scan-start=$(date -u +%FT%TZ)" >> out/build-info.txt; CACHE=/trivy-cache
                if [ "${SIMULATE_SCAN_ERROR}" = "true" ]; then
                  CACHE="$(mktemp -d)"; echo "SIMULATE_SCAN_ERROR: 빈 캐시 ${CACHE}"
                fi
                rc=0
                trivy image --input out/image-oci --cache-dir "$CACHE" --skip-db-update --no-progress \
                  --severity "${TRIVY_SEVERITY}" --ignore-unfixed --exit-code 1 \
                  --format json --output out/trivy-report.json || rc=$?
                if [ -s out/trivy-report.json ]; then
                  trivy convert --format table out/trivy-report.json | tee out/trivy-report.txt || true
                fi
                echo "scan-exit=${rc} severity=${TRIVY_SEVERITY}" | tee -a out/build-info.txt
                exit $rc
              '''
            }
          }
        }
        stage('Push') {
          steps {
            container('skopeo') {
              sh '''
                DEST="docker://${REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"
                echo "push-start=$(date -u +%FT%TZ)" >> out/build-info.txt; skopeo --version | tee out/skopeo-version.txt
                skopeo copy --preserve-digests --dest-tls-verify=false oci-archive:out/image.tar "$DEST"
                # 조회 실패를 빈 입력의 해시(e3b0c442…)로 착각하지 않도록 파일로 받아 비어 있지 않은지 확인한 뒤 계산한다
                skopeo inspect --raw --tls-verify=false "$DEST" > out/pushed-manifest.json
                test -s out/pushed-manifest.json
                skopeo manifest-digest out/pushed-manifest.json > out/pushed-digest.txt
              '''
            }
            sh '''
              echo "built : $(cat out/manifest-digest.txt)"
              echo "pushed: $(cat out/pushed-digest.txt)"
              test "$(cat out/manifest-digest.txt)" = "$(cat out/pushed-digest.txt)"
              echo "${REGISTRY}/${IMAGE_REPO}@$(cat out/pushed-digest.txt)" | tee out/image-ref.txt
              echo "pushed-digest=$(cat out/pushed-digest.txt)" >> out/build-info.txt; echo "push-end=$(date -u +%FT%TZ)" >> out/build-info.txt
            '''
          }
        }
      }
      post {
        always {
          script {
            // 컨테이너별 피크 메모리·CPU throttling (cgroup v2, 각 컨테이너 자신의 cgroup)
            // 읽지 못하면 0이 아니라 '미수집'으로 남긴다. 컨테이너별 피크의 합은 Node 동시 피크가 아니다
            def cg = '''
              mkdir -p out
              { echo "== $1"
                if [ -r /sys/fs/cgroup/memory.peak ]; then echo "memory.peak_bytes=$(cat /sys/fs/cgroup/memory.peak)"; else echo "memory.peak_bytes=미수집"; fi
                if [ -r /sys/fs/cgroup/memory.events ]; then
                  echo "memory.events_begin"
                  cat /sys/fs/cgroup/memory.events
                  echo "memory.events_end"
                else
                  echo "memory.events=미수집"
                fi
                grep -E '^(usage_usec|nr_throttled|throttled_usec)' /sys/fs/cgroup/cpu.stat 2>/dev/null || echo "cpu.stat=미수집"
              } > "out/cgroup-$1.txt"
            '''
            for (c in ['jnlp', 'python', 'buildkit', 'trivy', 'skopeo']) {
              try {
                container(c) { sh("set -- ${c}\n" + cg) }
              } catch (err) {
                echo "cgroup 수집 생략: ${c}"
              }
            }
          }
          archiveArtifacts artifacts: 'out/**', excludes: 'out/image.tar,out/image-oci/**', allowEmptyArchive: true
        }
      }
    }
  }
}

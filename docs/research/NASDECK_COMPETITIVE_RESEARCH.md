# NASDeck 경쟁 제품 조사

> 조사 기준일: 2026-09-05 (KST)
>
> 범위: 공개 스토어 설명과 개발자 공개 웹사이트만 검토한 데스크 리서치. NASDeck의 코드, 서버 동작, 보안 구현을 독립적으로 검증한 결과가 아니다.

## 요약

NASDeck은 STRTech LLC의 **Android 전용** TrueNAS 관리 앱으로 공개된 Google Play 패키지명은 `com.strtechllc.nasdeck`이다. TrueNAS Community Edition 25.04 이상을 요구하며, Play 표시는 광고 및 인앱 구매 포함이다.[1] 이 제품은 TrueNavo가 해결하려는 직접적인 사용자 문제와 유료화 가능성을 보여 주는 참고 사례다. 다만 TrueNavo는 비공식 독립 제품으로서 NASDeck의 브랜드, UI, 문구, 코드 또는 가격을 복제하지 않는다.

## 관찰된 스토어·제품 사실

| 항목 | 공개 설명/관찰 | 해석 시 주의 |
|---|---|---|
| 배포 | Google Play의 Android 앱 | iOS·데스크톱 제공을 확인한 근거는 이번 범위에 없다.[1] |
| 패키지 | `com.strtechllc.nasdeck` | 공식 Play URL을 1차 출처로 사용한다.[1] |
| 호환성 | TrueNAS Community Edition 25.04 이상, 네트워크 접근, Android 8.0 이상 | 서버 에디션·세부 API 호환성은 별도 검증이 필요하다.[1] |
| 연결·비밀 | 직접 보안 WebSocket 연결, 기기 내 암호화된 자격 증명 저장이라고 설명 | 판매자 주장으로, 구현 감사를 뜻하지 않는다.[1] |
| 알림·개인정보 | 선택형 self-hosted notification relay와 추적/분석 수집 없음이라고 설명 | Play의 Data safety 신고도 개발자가 갱신할 수 있는 자기 신고다.[1] |
| 스토어 표기 | 광고 포함, 인앱 구매 포함 | 광고 제거가 Pro 설명에 포함된다.[1] |
| 관찰 스냅샷 | 요청된 관찰값은 5K+ 다운로드, 평점 4.2/리뷰 46개 | 가격·평점·리뷰·다운로드·설명은 국가/시각/사용자에 따라 변하는 값이므로 출시 전 재검증해야 한다. |

공식 Play 페이지의 현재 설명은 NASDeck을 “unofficial”로 표시한다.[1] TrueNavo도 iXsystems와 제휴·보증 관계가 없는 별도 비공식 클라이언트임을 분명히 해야 한다.

## 공개 설명의 기능·플랜 분류

아래는 기능 보장이나 구현 검증이 아니라, 기준일에 확인한 Play 설명의 요약이다.

| 플랜 | Play 설명에 기재된 항목 |
|---|---|
| Free | 시스템 전원 제어, 시스템·스토리지 정보, 서비스 제어, 수동 snapshot, 기본 모니터링·알림 |
| Pro | USD 9.99 일회성으로 기재. VM/container/app 관리, 고급 ZFS·pool 작업, VM terminal, 고급 서비스, self-hosted relay, scrub 도구, 광고 제거 |
| Cloud Connect | USD 1.99/월로 기재. Pro 전체, 관리형 Firebase push, 우선 지원 |

이 가격과 플랜 문구도 변동 정보다. TrueNavo의 제안 가격 또는 권한 설계의 근거로 기계적으로 전환하지 않으며, 출시 직전 공식 Play 페이지에서 다시 확인한다.[1]

## TrueNavo에 주는 시사점

1. **직접 연결을 기본값으로 유지한다.** NAS 관리의 비밀·데이터 경로와 원격 알림 경로를 분리하고, 관리형 relay는 선택 편의 기능이어야 한다.
2. **구현 패리티와 판매 권한을 분리한다.** TrueNavo는 적용 가능한 모든 TrueNAS WebUI capability를 구현하고 실제 E2E로 증명한다. 어떤 플랜에서 그 capability를 실행할지는 별도의 버전 관리 entitlement catalog가 결정한다.
3. **안전·복구는 결제보다 우선한다.** 중요한 경보 열람, 자신의 구성 내보내기·복원, 인증서/보안 경고, 진행 중인 위험 작업 중지는 유료 벽 뒤에 두지 않는다.
4. **광고는 엄격히 경계한다.** 관리 화면의 신뢰·집중·안전성을 우선해, Free의 광고는 명시적으로 표시된 저위험 read-only surface에만 제한한다. critical alert, 복구, 인증, mutation, active job, terminal/console, 비밀, 파괴적 작업에는 광고를 표시하지 않으며, NAS metadata·hostname·address·alert·job·credential·운영 문맥을 광고망에 제공하지 않는다. 필요한 consent를 처리하고 allowlist/blocklist·remote kill switch를 운영하며, consent 거부 또는 ad load 실패에도 빈 reserved slot으로 핵심 기능을 계속 제공한다. Pro는 모든 광고를 제거한다.
5. **참조하되 복제하지 않는다.** NASDeck은 시장·문제·사용자 기대를 이해하기 위한 참고 제품일 뿐, TrueNavo의 이름, 시각 디자인, 상호작용, 카피, 코드에 대한 라이선스를 주지 않는다.

## 출처

[1] [NASDeck - for TrueNAS, Google Play (공식)](https://play.google.com/store/apps/details?id=com.strtechllc.nasdeck&hl=en_US)

[2] [STRTech LLC 개발자 웹사이트](https://strtechllc-dev.github.io/)

공식 Play URL이 본 문서의 1차 출처다. APKPure 등 제3자 APK/스토어 미러는 이 문서의 사실 근거로 사용하지 않았으며, 불가피하게 과거 스냅샷을 대조할 때만 보조 자료로 취급한다.

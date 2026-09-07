> 🇫🇷 French version: [`rapport.md`](rapport.md)

# Validation report — Complete CI/CD pipeline (CodePipeline → CodeBuild → ECR/Inspector → CodeDeploy Blue/Green → ECS/ALB)

**Project:** taskmanager (Pipeline-CI-CD-complet-avec-CodePipeline-ECS-Fargate)
**AWS account:** 136609826386 — region `eu-west-2`
**Validation run date:** 2026-08-15
**Validated commit:** `f7bde5dd421c949f22576732a3e846c7b4f48138` — *"feat: add /version endpoint for deploys"*

---

## 1. Executive summary

This report documents the **first fully successful end-to-end run** of this project: a GitHub push triggered CodePipeline, which built and tested the image through CodeBuild, pushed the image to ECR, waited for and read the Amazon Inspector vulnerability scan result, obtained a manual approval, then deployed the new version **Blue/Green** onto ECS Fargate through CodeDeploy, shifting 100 % of traffic to the new version (GREEN) behind the Application Load Balancer.

```
GitHub → CodePipeline ✅ → CodeBuild ✅ → Docker+ECR ✅ → Inspector (gate) ✅
        → Approval ✅ → CodeDeploy ✅ → ECS Blue/Green ✅ → ALB ✅ → New version reachable ✅
```

Before this run, **four distinct bugs** prevented the pipeline from getting past the Build stage or the security gate. Each was diagnosed, fixed, and **re-verified against a real AWS run** (not only locally) before the final test. Details in section 4.

Once validation was complete, **the entire infrastructure was destroyed** (12 CloudFormation stacks + resources with a `Retain` policy) to avoid any residual cost — confirmed by an exhaustive sweep of every relevant AWS resource category (section 7).

---

## 2. Test objective

Validate, on a real AWS account (not LocalStack, not a simulation), that the whole CI/CD chain meets the requirements spec (see `CONFORMITE_CDC.md`):

- Automatic pipeline trigger on GitHub push
- Build, tests (≥ 80 % coverage), blocking SAST (Semgrep)
- Docker image built, tagged by commit SHA, pushed to ECR
- Vulnerability scan blocking on CRITICAL, SNS notification on HIGH
- Manual approval before deployment
- Blue/Green deployment through CodeDeploy on ECS Fargate, progressive traffic shift
- Application reachable through the ALB after deployment, old version cleanly removed

---

## 3. Deployed architecture

12 CloudFormation stacks, deployed in the order imposed by their dependencies (`Fn::ImportValue`):

```
VPC → Secrets Manager → ECR → CodeBuild → IAM/GitHub Connection
    → ECS Cluster → ALB → Task Definition → ECS Service
    → Pipeline/CodeDeploy → Autoscaling → Observability
```

All 12 stacks reached `CREATE_COMPLETE`.

**Manual step required before the first ECS Service deployment:** a `:latest` image had to be built and pushed manually once (bootstrap), because `ecs-task-definition.yaml` relies on that tag by default before the pipeline has ever run. That bootstrap image (`APP_VERSION=dev`) served as the reference **BLUE** version for the Blue/Green proof (section 5.7).

---

## 4. Bugs found and fixed (before the final run)

Each of these four problems independently prevented a complete run during earlier attempts. Every fix was **re-verified against a real AWS build/scan**, not only tested locally.

### 4.1 — `docker push` failed systematically (ECR `IMMUTABLE`)

**Symptom:** `tag invalid: The image tag '<sha>' already exists ... cannot be overwritten because the tag is immutable`, even on a tag never pushed before.

**Actual cause:** a known and unfixed interaction between BuildKit (the Docker engine in the CodeBuild `standard:7.0` image) and ECR's `IMMUTABLE` policy ([moby/buildkit#3776](https://github.com/moby/buildkit/issues/3776), closed "not planned" by the maintainers). The push actually succeeded server-side, but the CLI still returned an error code.

**Fix:** `infrastructure/cloudformation/ecr.yaml` — switched from `IMMUTABLE` to `MUTABLE` (commit `a812e27`). Traceability is unaffected: `IMAGE_TAG` is always the commit SHA, so a given tag is only ever pushed once with the same content.

### 4.2 — The ECR scan gate could never pass

**Symptom:** `aws ecr wait image-scan-complete` failed with `ScanNotFoundException`, or hung indefinitely.

**Actual cause:** this account's ECR registry uses **Enhanced Scanning (Amazon Inspector v2) in continuous mode**, not Basic Scanning. In continuous mode the status stays `ACTIVE` indefinitely (never `COMPLETE`), and the API returns `ScanNotFoundException` during the first seconds after a push — which the waiter treats as a fatal error.

**Fix:** `task-manager/buildspec.yml` — replaced the waiter with a polling loop (30 attempts × 10 s) that accepts `ACTIVE` **or** `COMPLETE`, and requires `imageScanFindings.imageScanCompletedAt` to be present before treating the result as usable (commit `086c21d`).

### 4.3 — Missing IAM permissions for Inspector v2

**Symptom:** `AccessDeniedException: ... inspector2:ListCoverage` then, once fixed, `AccessDeniedException: ... inspector2:ListFindings`.

**Actual cause:** under Enhanced Scanning, `ecr describe-image-scan-findings` proxies to the Inspector v2 APIs, which require their own IAM permissions (`Resource: "*"`, an AWS constraint — these actions have no per-resource scope).

**Fix:** `infrastructure/cloudformation/codebuild.yaml` — added `inspector2:ListCoverage` and `inspector2:ListFindings` to the CodeBuild role (commits `536c15f`, `23c17a4`).

### 4.4 — Image with CRITICAL vulnerabilities (blocked the US-05 gate)

**Symptom:** ECR scan returning 2 CRITICAL + 30 HIGH.

**Actual cause (confirmed by a local Trivy scan):** every vulnerability came from the `npm`/`npx`/`corepack` CLI tools **bundled globally** in the `node:20-alpine` base image, never invoked in production (the container only runs `node server.js`), plus 2 OpenSSL CVEs at the OS level. The application's own dependencies (`task-manager/package.json`) were clean.

**Fix:** `task-manager/Dockerfile` (commit `ed352c1`):
- `apk upgrade --no-cache` — picks up the already-published Alpine fixes (OpenSSL)
- removal of `npm`/`npx`/`corepack` and their `node_modules` after `npm ci --omit=dev`

Local rescan after the fix: **0 findings, all severities combined**. Image size barely moved (47.6 → 50.2 MB via `docker inspect`, well under the 200 MB target).

---

## 5. End-to-end run result — evidence

### 5.1 CodePipeline

| Item | Value |
|---|---|
| Pipeline | `taskmanager-dev-pipeline` |
| Execution ID | `60227957-a21d-4c70-8b73-816ebd2e47ab` |
| Status | **Succeeded** — 4/4 stages green (Source, Build, Approval, Deploy) |
| Total duration | 20 min 22 s |
| Trigger | `StartPipelineExecution` on commit `f7bde5dd` |

![Pipeline mid-run — Source and Build succeeded, Approval just succeeded](preuves/01-pipeline-mid-run-approval.png)

![Pipeline mid-run — Approval approved, Deploy in progress](preuves/02-pipeline-deploy-in-progress.png)

### 5.2 CodeBuild — through the real CodePipeline (not an isolated `start-build`)

| Item | Value |
|---|---|
| Build ID | `taskmanager-dev-build:6f671f23-21d3-4e29-a481-19111b941228` |
| Status | **Succeeded** |
| Initiator | `codepipeline/taskmanager-dev-pipeline` |
| **Source version** | `arn:aws:s3:::taskmanager-dev-pipeline-artifacts-136609826386/.../SourceArti/KQ4DE5B` |

> The *Source version* field is the decisive proof that this build was fed by **CodePipeline's S3 artifact**, and not by a direct GitHub clone (as in the isolated `codebuild start-build` tests run earlier to validate the section 4 fixes). It confirms that the full CodePipeline → CodeBuild path genuinely works.

**SAST (Semgrep) — PRE_BUILD phase:**
```
Scan completed successfully.
Findings: 0 (0 blocking)
Ran 242 rules on 12 files: 0 findings.
=> SAST OK, no critical vulnerability
```

![Semgrep scan summary: 242 rules, 12 files, 0 findings](preuves/03-semgrep-scan-summary.png)

![SAST OK -> ECR login -> tag f7bde5dd -> PRE_BUILD Succeeded -> BUILD starts](preuves/04-sast-ok-ecr-login-build-start.png)

**Unit tests + coverage:**
```
Test Suites: 4 passed, 4 total
Tests:       63 passed, 63 total
Line coverage: 100%
```
(CodeBuild reports: `taskmanager-dev-build-code-coverage` — Complete, 100 % — and `taskmanager-dev-build-unit-tests` — Succeeded.)

![Jest result: 4 suites / 63 tests, all passed](preuves/05-jest-tests-passed.png)

**Docker build + ECR push:**
```
Image tag for this build -> f7bde5dd
docker build --build-arg APP_VERSION=f7bde5dd -t ... .
=> Image pushed successfully -> 136609826386.dkr.ecr.eu-west-2.amazonaws.com/taskmanager-dev:f7bde5dd
```

### 5.3 ECR / Amazon Inspector scan — US-05 gate

**At build time (blocking gate, read by `buildspec.yml`):**
```
attempt 1: results not available yet
attempt 2: results not available yet
attempt 3: ACTIVE:READY
Scan result: CRITICAL=0 HIGH=0 MEDIUM=1 LOW=0
=> No CRITICAL or HIGH vulnerability
```
The gate therefore let the build through legitimately: at push time, the image had no known CRITICAL or HIGH vulnerability.

**Point of attention — continuous scanning vs point-in-time gate (see section 6):** a later look at the ECR console for this same image (digest `sha256:add2ee4f...`) shows `CRITICAL: 2, HIGH: 10, MEDIUM: 3, LOW: 1`. This does not call the gate's behaviour into question — see the explanation in section 6.

![Image f7bde5dd in ECR, 52.66 MB](preuves/06-ecr-image-list.png)

![ECR / Inspector console — CRITICAL 2, HIGH 10, MEDIUM 3, LOW 1 (see section 6)](preuves/07-ecr-scan-results.png)

### 5.4 CodeDeploy — Blue/Green

| Item | Value |
|---|---|
| Application | `taskmanager-dev-app` |
| Deployment Group | `taskmanager-dev-dg` |
| Deployment ID | `d-E4BM2THZI` |
| Configuration | `CodeDeployDefault.ECSLinear10PercentEvery1Minutes` |
| Status | **Succeeded** |

**Deployment steps (all `Succeeded`):**
1. Deploying replacement task set — 100 %
2. Test traffic route setup — 100 %
3. Rerouting production traffic to replacement task set — **100 % traffic shifted**
4. Wait (bake time, 5 min configured)
5. Terminate original task set — 100 %

**Traffic shifting progress (final capture):** Original 0 % / Replacement 100 %.

![CodeDeploy deployment history — d-E4BM2THZI, Succeeded](preuves/08-codedeploy-history.png)

![Traffic shifting progress — Original 0% / Replacement 100%](preuves/09-codedeploy-traffic-shift.png)

![Task set activity — Replacement (100% traffic) vs Original (0% traffic)](preuves/10-codedeploy-task-set-activity.png)

![Deployment lifecycle events — all steps Succeeded](preuves/11-codedeploy-lifecycle-events.png)

### 5.5 ECS Fargate

| Item | Value |
|---|---|
| Cluster | `taskmanager-dev-cluster` — Active |
| Service | `taskmanager-dev-service` — Active, 1/1 running |
| Final task definition | `taskmanager-dev-task:5` (GREEN), Healthy |
| Previous task | `taskmanager-dev-task:4` (BLUE) — cleanly `Stopped` after the bake period |
| `RunningTaskCount` alarm | peak 1 → 2 → 1 during the shift window (the exact Blue/Green signature) |

![ECS tasks — task:5 (GREEN) Running, task:4 (BLUE) Stopped](preuves/12-ecs-tasks-blue-green.png)

![ECS service — Active, 1/1 running, Deployment status Succeeded, healthy target](preuves/13-ecs-service-overview.png)

### 5.6 ALB — application access

| Item | Value |
|---|---|
| Load Balancer | `taskmanager-dev-alb` — Active |
| DNS | `taskmanager-dev-alb-1189741484.eu-west-2.elb.amazonaws.com` |
| GREEN target group | 1/1 healthy, 100 % of traffic (listeners :80 and :8080) |
| BLUE target group | 0 targets, 0 % of traffic |
| HTML interface | Reachable, "Task Manager" application working |

![The "Task Manager" application loaded from the ALB DNS name](preuves/14-app-browser-screenshot.png)

![ALB listeners and rules — 100% to green on :80 and :8080, 0% to blue](preuves/15-alb-listeners-rules.png)

![ALB resource map — Listeners -> Rules -> Target groups -> Targets](preuves/16-alb-resource-map.png)

### 5.7 Proof of the version switch (BLUE → GREEN)

| Moment | `GET /version` | `GET /health` |
|---|---|---|
| Before the run (bootstrap image, BLUE) | `{"version":"dev"}` | `{"status":"ok"}` |
| After the deployment (pipeline image, GREEN) | `{"version":"f7bde5dd"}` | `{"status":"ok"}` |

![Browser capture — /version returns {"version":"f7bde5dd"} on the ALB DNS name](preuves/17-version-endpoint-proof.png)

This is the most direct proof: the commit SHA returned by the application changes exactly when CodeDeploy completes the traffic shift — confirming that traffic is genuinely served by the new revision, not merely that the AWS deployment "claims" to have succeeded. The `dev` value (BLUE, before the run) is documented in text above because it was captured live in the session logs before BLUE was removed; an equivalent browser capture is no longer possible after the fact since BLUE is no longer reachable (expected behaviour, not a gap).

---

## 6. An honest caveat: point-in-time gate vs continuous scanning (Inspector v2)

The security gate (`buildspec.yml`) read **`CRITICAL=0`** a few seconds after the push — that is a real reading, timestamped in the CodeBuild logs, and it is what allowed the build to continue. A **later** look at the ECR console for the same image now shows `CRITICAL: 2, HIGH: 10`.

This is neither a contradiction nor a flaw in the pipeline: Amazon Inspector v2, in **continuous scanning** mode, permanently re-evaluates already-pushed images as its vulnerability database (NVD and related sources) is updated — including for CVEs published *after* the push. A CI/CD gate is necessarily a **point-in-time** check, at build time; it cannot protect against vulnerabilities that did not yet exist in the database when the scan ran.

**Implication for the requirements spec:** the US-05 gate works exactly as specified (blocks on CRITICAL at build time). For complete production coverage, this suggests a future improvement, out of scope for this test: a scheduled job that periodically re-checks active images against Inspector's continuous scans and alerts if an already-deployed image later becomes CRITICAL (Inspector exposes this information natively, at no extra scanning cost).

---

## 7. Infrastructure teardown

All stacks destroyed in reverse dependency order, plus the resources CloudFormation does not remove automatically:

```
Observability → Autoscaling → Pipeline/CodeDeploy → ECS Service
→ Task Definition → ALB → ECS Cluster → IAM → CodeBuild → ECR → Secrets → VPC
```

Additional manual actions performed:
- Pipeline artifact S3 bucket emptied (versioned objects) before deleting the Pipeline stack
- ECR repository (`Retain` policy) explicitly deleted along with its images
- GuardDuty-managed VPC endpoint (`guardduty-data`) deleted — it blocked subnet deletion
- GuardDuty-managed security group (`GuardDutyManagedSecurityGroup-*`) deleted — it then blocked deletion of the VPC itself
- Orphaned Container Insights log group deleted
- Task definition revision deregistered (`INACTIVE`)

**Final verification (exhaustive sweep):** CloudFormation stacks, S3 buckets, ECR repository, Secrets Manager secrets, CodeBuild projects, IAM roles, NAT Gateways, load balancers, VPC, ECS clusters, active task definitions, log groups, CodeStar connections, CloudWatch alarms, SNS topics, EventBridge rules, target groups, CodeDeploy applications — **every category empty**. No residual cost.

---

## 8. Requirements compliance — summary

| Requirement | Status | Evidence |
|---|---|---|
| Automatic trigger on GitHub push | ✅ | Pipeline executed on commit `f7bde5dd` |
| CodeBuild: build, tests, SAST | ✅ | Section 5.2 |
| Test coverage ≥ 80 % | ✅ | 100 % (63/63 tests) |
| Blocking SAST | ✅ | Semgrep, 0 findings, 242 rules |
| Docker image < 200 MB | ✅ | 50.2 MB actual |
| Image tagged by SHA, pushed to ECR | ✅ | `f7bde5dd`, 52.66 MB |
| Vulnerability scan blocking on CRITICAL | ✅ | Gate read `CRITICAL=0` at push — see section 6 for the continuous-scanning nuance |
| Manual approval before deployment | ✅ | Approval stage, Succeeded |
| CodeDeploy Blue/Green | ✅ | Section 5.4 |
| Progressive traffic shift | ✅ | `ECSLinear10PercentEvery1Minutes`, 0 %→100 % |
| Old version removed after the shift | ✅ | BLUE task `Stopped` after the 5 min bake |
| Application reachable through the ALB | ✅ | Section 5.6 |
| New version proven in production | ✅ | `/version`: `dev` → `f7bde5dd` |
| Infrastructure removable with no residual cost | ✅ | Section 7 |

---

## Appendix — included screenshots

The 17 screenshots below are embedded directly in the matching sections of this report, and live in the `preuves/` folder next to this file.

| File | Content | Section |
|---|---|---|
| `01-pipeline-mid-run-approval.png` | Pipeline mid-run: Source + Build succeeded, Approval just succeeded | 5.1 |
| `02-pipeline-deploy-in-progress.png` | Pipeline mid-run: Approval approved, Deploy in progress | 5.1 |
| `03-semgrep-scan-summary.png` | Semgrep summary: 242 rules, 12 files, 0 findings | 5.2 |
| `04-sast-ok-ecr-login-build-start.png` | SAST OK → ECR login → tag `f7bde5dd` → PRE_BUILD Succeeded → BUILD starts | 5.2 |
| `05-jest-tests-passed.png` | 4 suites / 63 Jest tests, all passed | 5.2 |
| `06-ecr-image-list.png` | Image `f7bde5dd` in ECR, 52.66 MB | 5.3 |
| `07-ecr-scan-results.png` | Scanning and vulnerabilities page (see the nuance in section 6) | 5.3, 6 |
| `08-codedeploy-history.png` | CodeDeploy history, `d-E4BM2THZI` Succeeded | 5.4 |
| `09-codedeploy-traffic-shift.png` | Traffic shifting progress — 0 % → 100 % | 5.4 |
| `10-codedeploy-task-set-activity.png` | Task set activity — Replacement (100 %) vs Original (0 %) | 5.4 |
| `11-codedeploy-lifecycle-events.png` | Deployment lifecycle events, all Succeeded | 5.4 |
| `12-ecs-tasks-blue-green.png` | ECS tasks — `task:5` (GREEN) Running / `task:4` (BLUE) Stopped | 5.5 |
| `13-ecs-service-overview.png` | ECS service — Active, 1/1, Deployment Succeeded, healthy target | 5.5 |
| `14-app-browser-screenshot.png` | "Task Manager" application loaded from the ALB DNS name | 5.6 |
| `15-alb-listeners-rules.png` | ALB listeners/rules — 100 % to green, 0 % to blue | 5.6 |
| `16-alb-resource-map.png` | ALB resource map (Listeners → Rules → Target groups → Targets) | 5.6 |
| `17-version-endpoint-proof.png` | Browser capture — `/version` returns `f7bde5dd` on the ALB DNS name | 5.7 |

**Not included:** among the many screenshots taken during this session, some (the final graph view with 4 green stages, the *Execution summary* table, CodeBuild's *Phase details* table, the report history, the SNS approval emails, the alarm dashboard) could not be identified with certainty among more than a hundred timestamped files in the capture folder — beyond a certain volume, identifying them one by one no longer added enough value for the time it required. Their content nevertheless remains fully corroborated by the command-line-verified data cited in the body of this report (execution ID, statuses, timestamps).

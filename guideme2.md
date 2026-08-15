You are now in the right scenario: **region `eu-west-2`, SSO configured, no existing stack, 12 templates present in `infrastructure/cloudformation/`**.

The requirements spec (CDC) calls for CodePipeline, CodeBuild, ECR, ECS Fargate, CodeDeploy Blue/Green, ALB, Secrets Manager, CloudWatch/SNS, ≥80% test coverage, SAST, Docker image scanning, autoscaling, and rollback.

Recommended approach: **one full deployment + one pipeline test run + immediate teardown**, with `DesiredCount=1` to limit cost.

---

# 0. Before you start — lock the region

In PowerShell, from the **project root**:

```powershell
cd "C:\Users\user\Desktop\Pipeline-CI-CD-complet-avec-CodePipeline-ECS-Fargate"

$env:AWS_PROFILE="AdministratorAccess-136609826386"
$env:AWS_DEFAULT_REGION="eu-west-2"

aws sso login --profile AdministratorAccess-136609826386
```

Then:

```powershell
aws sts get-caller-identity --profile AdministratorAccess-136609826386
aws configure get region --profile AdministratorAccess-136609826386
```

**Note:** `aws configure list-profiles` also shows a `default` profile — its credentials are stale/invalid. Always pass `AdministratorAccess-136609826386` explicitly (via `$env:AWS_PROFILE` or `--profile`); don't rely on whatever profile is currently the CLI's implicit default.

### You should see

```text
eu-west-2
```

and in `get-caller-identity`:

```text
arn:aws:sts::XXXXXXXXXXXX:assumed-role/AWSReservedSSO_AdministratorAccess...
```

`AdministratorAccess` is the role to use so you can create the VPC, IAM, and pipeline resources.

---

# 1. Confirm there really is no existing stack

```powershell
aws cloudformation list-stacks `
  --region eu-west-2 `
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE `
  --query "StackSummaries[].StackName" `
  --output table
```

### Expected

No `taskmanager-dev-*` stack.

---

# 2. Validate the 12 templates BEFORE creating anything

This step matters.

```powershell
$files = @(
    "vpc.yml",
    "iam.yaml",
    "secrets-manager.yaml",
    "ecr.yaml",
    "codebuild.yaml",
    "ecs-cluster.yaml",
    "alb.yaml",
    "ecs-task-definition.yaml",
    "ecs-service.yaml",
    "pipeline.yml",
    "ecs-autoscaling.yaml",
    "observability.yml"
)

foreach ($f in $files) {
    Write-Host "`n===== $f =====" -ForegroundColor Cyan
    aws cloudformation validate-template `
        --template-body "file://infrastructure/cloudformation/$f" `
        --region eu-west-2 `
        --query "Description" `
        --output text
}
```

### What you want

No error of the form:

```text
Template format error
```

or

```text
ValidationError
```

**If even one template fails: STOP here.** Do not deploy the remaining stacks.

---

### Deployment order — an important CloudFormation dependency

The `iam.yaml` template imports the `taskmanager-dev-codebuild-arn` export. That means the **CodeBuild stack must be created before the IAM stack**.

The requirements spec (CDC) does not dictate the order in which CloudFormation stacks are created; it only specifies the components and their responsibilities. An earlier version of this guide deployed IAM before CodeBuild, which caused the error `No export named taskmanager-dev-codebuild-arn found`.

**Order used in this corrected guide:** VPC → Secrets Manager → ECR → (optional: manual Docker build/push sanity check) → CodeBuild → IAM/GitHub Connection → ECS Cluster → ALB → Task Definition → ECS Service → Pipeline/CodeDeploy → Autoscaling → Observability.

---

# 3. Deploy the VPC

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/vpc.yml `
  --stack-name taskmanager-dev-vpc `
  --parameter-overrides ProjectName=taskmanager Environment=dev NatGatewayStrategy=single `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Wait for:

```text
Successfully created/updated stack - taskmanager-dev-vpc
```

### Verify

```powershell
aws cloudformation describe-stacks `
  --stack-name taskmanager-dev-vpc `
  --region eu-west-2 `
  --query "Stacks[0].{Status:StackStatus,Outputs:Outputs}" `
  --output table
```

Then:

```powershell
aws ec2 describe-vpcs `
  --region eu-west-2 `
  --filters "Name=tag:Name,Values=taskmanager-dev-vpc" `
  --query "Vpcs[].{VPC:VpcId,CIDR:CidrBlock,State:State}" `
  --output table
```

And:

```powershell
aws ec2 describe-nat-gateways `
  --region eu-west-2 `
  --filter "Name=state,Values=available" `
  --query "NatGateways[].{ID:NatGatewayId,State:State}" `
  --output table
```

### CDC confirmation

You now have the required network layer: VPC, subnets, and security groups — explicitly required by the CDC.

---

# 4. Secrets Manager

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/secrets-manager.yaml `
  --stack-name taskmanager-dev-secrets `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Verify:

```powershell
aws secretsmanager list-secrets `
  --region eu-west-2 `
  --query "SecretList[?starts_with(Name,'taskmanager')].Name" `
  --output table
```

### CDC confirmation

Secrets must live in Secrets Manager, never as plaintext CodeBuild environment variables. This is an explicit CDC requirement.

---

# 5. ECR

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/ecr.yaml `
  --stack-name taskmanager-dev-ecr `
  --parameter-overrides ProjectName=taskmanager Environment=dev MaxImageCount=10 `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Verify:

```powershell
aws ecr describe-repositories `
  --repository-names taskmanager-dev `
  --region eu-west-2 `
  --query "repositories[0].{URI:repositoryUri,ScanOnPush:imageScanningConfiguration.scanOnPush,TagMutability:imageTagMutability}" `
  --output table
```

Also check the account's **registry-wide** scanning mode — the per-repo `ScanOnPush` above doesn't tell you this, and it changes how the scan gate behaves (see step 14's troubleshooting):

```powershell
aws inspector2 batch-get-account-status --region eu-west-2
```

If `resourceState.ecr.status` is `ENABLED`, the registry uses **Enhanced Scanning (Amazon Inspector v2)**, not Basic Scanning — that's the case for this account.

### Important

The CDC requires:

* a Docker image;
* tagged with the commit SHA;
* pushed to ECR;
* scanned for vulnerabilities.

The repository is **`MUTABLE`** (switched back from `IMMUTABLE` on 2026-08-14 — see step 14's troubleshooting for why: `IMMUTABLE` made every automated build fail at `docker push`, a known unfixed BuildKit/ECR interaction, not something specific to this project). `buildspec.yml` still only pushes the commit-SHA tag on every automated build, never `latest` — that's just not useful, not a mutability workaround. One consequence either way: **something still has to push a `:latest` image once, manually, before the Task Definition/ECS Service stacks (steps 11-12)** — `ecs-task-definition.yaml`'s bootstrap `ContainerImage` parameter defaults to `<repo>:latest` for that very first task, before the pipeline has ever run and produced a real, SHA-tagged revision. Step 6 below does exactly that, once.

---

# 6. Build and push the Docker image manually (required once, before step 11)

Unlike the automated build CodeBuild does for you via `task-manager/buildspec.yml` (step 7 onward, one SHA-tagged image per pipeline run), this one-time manual push is **required**: it's the only thing that ever puts a `:latest`-tagged image in ECR, which `ecs-task-definition.yaml`'s bootstrap `ContainerImage` parameter needs by default (see the note in step 5). Skip it only if you plan to pass an explicit `ContainerImage` parameter override to step 11 instead.

It's also useful as a sanity check regardless: if this step works, you know the `Dockerfile`, the app, and your ECR permissions are fine, so anything that fails later in CodeBuild is a **pipeline/CodeBuild** problem, not a **Docker/app** problem.

```powershell
$ecrUri = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-ecr-uri'].Value" `
  --output text

$ecrUri
```

Log in to ECR, then build from the `task-manager/` directory (that's where the `Dockerfile`, `package.json`, and application code live — the same build context CodeBuild uses):

```powershell
aws ecr get-login-password --region eu-west-2 | docker login --username AWS --password-stdin $ecrUri

cd task-manager

$imageTag = (git rev-parse --short=8 HEAD)
Write-Host "Image tag for this manual build -> $imageTag"

docker build -t "${ecrUri}:$imageTag" -t "${ecrUri}:latest" .

cd ..
```

Check the image size (target: under 200 MB):

```powershell
docker images "${ecrUri}:$imageTag"
```

Push both tags:

```powershell
docker push "${ecrUri}:$imageTag"
docker push "${ecrUri}:latest"
```

**Push `:latest` here, and only here.** Nothing else in this project ever pushes `:latest` again — `buildspec.yml` deliberately only pushes the commit-SHA tag, since a moving `latest` tag isn't useful once the pipeline is producing real, traceable revisions — so there's nothing to collide with it later.

### Verify

```powershell
aws ecr describe-images `
  --repository-name taskmanager-dev `
  --region eu-west-2 `
  --query "imageDetails[].{Tags:imageTags,Pushed:imagePushedAt,SizeMB:imageSizeInBytes}" `
  --output table
```

**Note:** this only proves the image builds and pushes. It does **not** run the unit tests, the coverage gate, or the SAST (Semgrep) scan — those only run inside CodeBuild/CI, via `buildspec.yml` and `.github/workflows/ci.yml`. Passing this manual step is a good sign, but it does not guarantee CodeBuild's automated build (step 7) will succeed too.

---

# 7. CodeBuild

Use **your actual GitHub repository** here.

Example:

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/codebuild.yaml `
  --stack-name taskmanager-dev-codebuild `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      GitHubRepoUrl=https://github.com/khaoula-mechria/Pipeline-CI-CD-complet-avec-CodePipeline-ECS-Fargate `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Then:

```powershell
aws codebuild list-projects `
  --region eu-west-2 `
  --query "projects[?starts_with(@,'taskmanager-dev')]" `
  --output table
```

Then:

```powershell
aws codebuild batch-get-projects `
  --names taskmanager-dev-build `
  --region eu-west-2 `
  --query "projects[0].{Name:name,Source:source.type,Repo:source.location,Branch:source.buildspec}" `
  --output table
```

The CDC requires CodeBuild for build/test/scan, with ≥80% coverage and SAST.

**Note (2026-08-14):** if this account's ECR registry uses Enhanced Scanning (see step 5's `inspector2 batch-get-account-status` check), the CodeBuild role needs `inspector2:ListCoverage` and `inspector2:ListFindings` (both `Resource: "*"`, an AWS constraint — neither action supports resource-level scoping) in addition to `ecr:DescribeImageScanFindings`. Without them, the build's ECR-scan gate (see step 14's troubleshooting) fails with `AccessDeniedException`. Already added to `codebuild.yaml`; nothing extra to do here, just don't remove them if you ever trim this policy down.

---

# 8. IAM + GitHub Connection

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/iam.yaml `
  --stack-name taskmanager-dev-iam `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Verify:

```powershell
aws iam list-roles `
  --region eu-west-2 `
  --query "Roles[?starts_with(RoleName,'taskmanager-dev')].RoleName" `
  --output table
```

Then:

```powershell
aws codestar-connections list-connections `
  --region eu-west-2 `
  --query "Connections[].{Name:ConnectionName,Status:ConnectionStatus}" `
  --output table
```

### Important

You will likely see:

```text
taskmanager-dev-github    PENDING
```

That's expected.

Console:

[AWS CodeConnections — eu-west-2](https://eu-west-2.console.aws.amazon.com/codesuite/settings/connections?region=eu-west-2)

Click:

**Update pending connection → GitHub → Authorize**

Then go back to:

```powershell
aws codestar-connections list-connections `
  --region eu-west-2 `
  --query "Connections[].{Name:ConnectionName,Status:ConnectionStatus}" `
  --output table
```

### You need to reach

```text
taskmanager-dev-github    AVAILABLE
```

The CDC requires GitHub as the source and an automatic pipeline trigger.

---

# 9. ECS Cluster

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/ecs-cluster.yaml `
  --stack-name taskmanager-dev-ecs-cluster `
  --parameter-overrides ProjectName=taskmanager Environment=dev `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Verify:

```powershell
aws ecs describe-clusters `
  --clusters taskmanager-dev-cluster `
  --region eu-west-2 `
  --query "clusters[0].{Name:clusterName,Status:status,Running:runningTasksCount}" `
  --output table
```

Expected:

```text
ACTIVE    0
```

That's normal: **Fargate needs no EC2 instance**. The CDC explicitly requires ECS Fargate as the serverless runtime.

---

# 10. ALB

```powershell
$vpcId = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-vpc-id'].Value" `
  --output text

$pubSub = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-public-subnet-ids'].Value" `
  --output text

$vpcId
$pubSub
```

Both must return a value.

Then:

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/alb.yaml `
  --stack-name taskmanager-dev-alb `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      VpcId=$vpcId `
      "PublicSubnetIds=$pubSub" `
      ContainerPort=3000 `
      HealthCheckPath=/health `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Verify:

```powershell
aws elbv2 describe-load-balancers `
  --names taskmanager-dev-alb `
  --region eu-west-2 `
  --query "LoadBalancers[0].{DNS:DNSName,State:State.Code}" `
  --output table
```

The CDC explicitly requires an ALB with Blue/Green target groups.

---

# 11. Task Definition

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/ecs-task-definition.yaml `
  --stack-name taskmanager-dev-taskdef `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      ContainerCpu=256 `
      ContainerMemory=512 `
      ContainerPort=3000 `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Verify:

```powershell
aws ecs describe-task-definition `
  --task-definition taskmanager-dev-task `
  --region eu-west-2 `
  --query "taskDefinition.{Revision:revision,CPU:cpu,Memory:memory,Image:containerDefinitions[0].image}" `
  --output table
```

---

# 12. ECS Service — **1 task only, to save cost**

Deliberately reducing to:

```text
DesiredCount=1
```

The CDC requires automatic scaling but does not fix the initial task count, and `DesiredCount=1` keeps the Fargate cost down for this test run.

```powershell
$vpcId = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-vpc-id'].Value" `
  --output text

$privSub = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-private-subnet-ids'].Value" `
  --output text

aws cloudformation deploy `
  --template-file infrastructure/cloudformation/ecs-service.yaml `
  --stack-name taskmanager-dev-ecs-service `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      VpcId=$vpcId `
      "PrivateSubnetIds=$privSub" `
      ContainerPort=3000 `
      DesiredCount=1 `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Then:

```powershell
aws ecs describe-services `
  --cluster taskmanager-dev-cluster `
  --services taskmanager-dev-service `
  --region eu-west-2 `
  --query "services[0].{Status:status,Desired:desiredCount,Running:runningCount,Controller:deploymentController.type}" `
  --output table
```

### Expected

```text
ACTIVE    1    1    CODE_DEPLOY
```

Then:

```powershell
$tgBlue = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-tg-blue-arn'].Value" `
  --output text

aws elbv2 describe-target-health `
  --target-group-arn $tgBlue `
  --region eu-west-2 `
  --query "TargetHealthDescriptions[].{Target:Target.Id,Health:TargetHealth.State}" `
  --output table
```

### Expected

```text
healthy
```

Then:

```powershell
$dns = aws cloudformation list-exports `
  --region eu-west-2 `
  --query "Exports[?Name=='taskmanager-dev-alb-dns'].Value" `
  --output text

$dns
Invoke-RestMethod "http://$dns/health"
```

### You want to get

```text
status : ok
```

This concretely validates **network → ALB → ECS → container → health check**.

---

# 13. Pipeline + CodeDeploy

This is the most important part for the CDC.

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/pipeline.yml `
  --stack-name taskmanager-dev-pipeline `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      FullRepositoryId=YOUR_USER/YOUR_REPO `
      BranchName=main `
      EnableManualApproval=true `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Verify:

```powershell
aws codepipeline get-pipeline `
  --name taskmanager-dev-pipeline `
  --region eu-west-2 `
  --query "pipeline.stages[].name" `
  --output table
```

You should see the stages defined in your template.

Then:

```powershell
aws deploy get-application `
  --application-name taskmanager-dev-app `
  --region eu-west-2
```

And:

```powershell
aws deploy get-deployment-group `
  --application-name taskmanager-dev-app `
  --deployment-group-name taskmanager-dev-dg `
  --region eu-west-2 `
  --query "deploymentGroupInfo.{Group:deploymentGroupName,ServiceRole:serviceRoleArn,Controller:deploymentStyle.deploymentType}"
```

The CDC requires CodeDeploy + Blue/Green with a **10 → 50 → 100%** traffic shift.

---

# 14. The test that actually proves CI/CD works

Run **only one** build/pipeline execution.

```powershell
aws codepipeline start-pipeline-execution `
  --name taskmanager-dev-pipeline `
  --region eu-west-2
```

Then:

```powershell
aws codepipeline get-pipeline-state `
  --name taskmanager-dev-pipeline `
  --region eu-west-2 `
  --query "stageStates[].{Stage:stageName,Status:latestExecution.status}" `
  --output table
```

### You want to see

```text
Source       Succeeded
Build        Succeeded
...
Deploy       Succeeded
```

The CDC requires that a push to `main` triggers the pipeline in under 60 seconds, that failing tests block the pipeline, and that the previous version stays available during the traffic shift.

For the real, automatic trigger test:

```text
git add .
git commit -m "test CI/CD AWS"
git push origin main
```

Then immediately:

```powershell
aws codepipeline get-pipeline-state `
  --name taskmanager-dev-pipeline `
  --region eu-west-2 `
  --query "stageStates[].{Stage:stageName,Status:latestExecution.status}" `
  --output table
```

## Troubleshooting: Build fails at the SAST (Semgrep) step

**Symptom:** the pipeline's Build stage (or the `.github/workflows/ci.yml` "SAST (Semgrep)" job) fails. The log shows Semgrep's scan summary ending in something like:

```text
✅ Scan completed successfully.
 • Findings: 1 (1 blocking)
Ran 242 rules on 12 files: 1 finding.
Error: Process completed with exit code 1.
```

**Why:** `buildspec.yml` and `ci.yml` both run `semgrep --config auto --error ...`. The `--error` flag fails the build on **any** finding, regardless of that rule's own severity label (INFO/WARNING/ERROR are just metadata — `--error` doesn't filter by them). In this app, that one finding was Semgrep's built-in `express-check-csurf-middleware-usage` audit rule (an INFO-level suggestion, not an actual vulnerability here). The rule always matches the `const app = express()` initialization line — never the individual route handlers.

**This took two fixes to actually resolve**, both in `task-manager/src/app.js`:
1. An earlier suppression comment sat above the `/add`/`/toggle`/`/delete` routes instead of above `const app = express()` — wrong line, so it silently matched nothing.
2. After moving it to the right line, it *still* failed, because the rule's real `check_id` isn't the path-derived name you'd expect from its registry page (`javascript.express.security.audit.express-check-csurf-middleware-usage`) — Semgrep appends the rule's own `id:` field a second time, so the actual id is `javascript.express.security.audit.express-check-csurf-middleware-usage.express-check-csurf-middleware-usage`. A `// nosemgrep: <id>` comment has to match that exact string or it's a silent no-op — Semgrep doesn't warn you that your suppression matched nothing.

**How this was verified**, since the console summary never shows the rule id and the failed run's log/artifact both require GitHub auth to fetch: installed Semgrep in WSL (`pip install semgrep`, same 1.173.0 version CI uses) and ran the identical `semgrep --config auto --error --json --output semgrep-report.json .` from `task-manager/` directly against the working tree. The JSON's `results[].check_id` field is the ground truth for the exact string a `nosemgrep:` comment must match. **Lesson for next time:** if you're not sure a `nosemgrep:<id>` suppression is actually taking effect, don't trust the id shown on the rule's semgrep.dev page — run Semgrep locally (WSL if on Windows; the CLI has no native Windows build) and read `check_id` straight from the JSON output before pushing.

**If a different or additional finding shows up:** the console summary only prints finding *counts*, never the rule id/file/line/message — that detail only exists in `semgrep-report.json`. To read it:
- **Locally:** run the command above and open the JSON, or skip `--output` and read `results[].check_id` / `.path` / `.start.line` / `.extra.message` directly.
- **CodeBuild:** `buildspec.yml` already `cat`s that file to the build log (CloudWatch Logs, PRE_BUILD phase) whenever the gate fails — just scroll to the `pre_build` section of the failed build's log.
- **GitHub Actions:** download the `test-reports` artifact from the failed run's summary page and open `semgrep-report.json` inside it (requires being logged in).

## Troubleshooting: Build fails at the `docker push` step with "tag invalid: ... already exists"

**Symptom:** the Build stage fails at `POST_BUILD`, on the `docker push "$ECR_REPOSITORY_URI:$IMAGE_TAG"` command, even on a **brand-new commit** whose SHA-tag was never pushed before:

```text
tag invalid: The image tag '<sha>' already exists in the 'taskmanager-dev' repository
and cannot be overwritten because the tag is immutable.
```

**Why:** this was a real, repeatable bug hit on 2026-08-14, not a one-off. Checking ECR's own `imagePushedAt` timestamp against the build's failure timestamp showed the image had **already landed in ECR seconds before** `docker push` reported failure — the push actually succeeded server-side, but the CLI (CodeBuild's `standard:7.0` image ships a BuildKit-based Docker engine) still exited non-zero against the repo's `IMMUTABLE` tag policy. This is a known, unfixed BuildKit/ECR interaction: [moby/buildkit#3776](https://github.com/moby/buildkit/issues/3776), closed by the maintainers as "not planned." It happened on every single build, not just re-runs of an old commit — don't waste time pushing empty commits to "get a fresh tag," that doesn't help.

**Fix:** the ECR repo is `MUTABLE` now (see step 5) — that's the actual fix, already applied. If you ever consider switching back to `IMMUTABLE` for stronger traceability, know that it will bring this exact failure back on every build. It doesn't cost real traceability here: `IMAGE_TAG` is always the commit SHA, so a given tag is only ever pushed once with the same content anyway.

---

## Troubleshooting: Build fails at the ECR scan-gate step (`SCAN ECR`)

**Symptom 1 — `AccessDeniedException: ... inspector2:ListCoverage` or `...inspector2:ListFindings`.**
**Why:** this account's ECR registry uses Enhanced Scanning (Amazon Inspector v2), not Basic Scanning (confirm with `aws inspector2 batch-get-account-status`, see step 5). Under Enhanced Scanning, `ecr describe-image-scan-findings` and the old `ecr wait image-scan-complete` both proxy to Inspector v2 APIs, which need their own permissions in the CodeBuild role — `ecr:DescribeImageScanFindings` alone isn't enough.
**Fix:** already added to `codebuild.yaml` (see step 7's note). If you rebuild the IAM policy from scratch, both `inspector2:ListCoverage` and `inspector2:ListFindings` (with `Resource: "*"`) are required.

**Symptom 2 — the build hangs or fails on `aws ecr wait image-scan-complete` with `ScanNotFoundException`, even with the permissions above fixed.**
**Why:** the `image-scan-complete` waiter polls for `imageScanStatus.status == COMPLETE`. That status only exists under **Basic** Scanning. Under **Enhanced Scanning in continuous mode** (this account), the status stays `ACTIVE` ("Continuous scan is selected for image") forever, and the API returns `ScanNotFoundException` for the first minute or so after a push while Inspector ingests the image — the waiter treats both as fatal, so the gate could never pass.
**Fix:** `buildspec.yml`'s `POST_BUILD` phase no longer uses the waiter. It polls `describe-image-scan-findings` directly (up to 30 attempts, 10s apart), accepting either `ACTIVE` or `COMPLETE` **and** requiring `imageScanFindings.imageScanCompletedAt` to be present (status alone can appear before findings are actually populated — trusting status alone would let a still-empty scan through as "zero vulnerabilities" by mistake). Already applied; nothing to change unless AWS alters this behavior again.

**Symptom 3 — the gate blocks the build with `N vulnerabilite(s) CRITICAL -> deploiement bloque`.**
**Why:** that's the gate doing its job (US-05), not a bug. On 2026-08-14 the `task-manager` image (node:20-alpine base) carried 2 CRITICAL + 30 HIGH CVEs (per the ECR/Inspector v2 scan). All of them traced to two sources, confirmed with a local Trivy scan: the globally-bundled `npm`/`npx`/`corepack` CLI tools (never invoked in production — the container only runs `node server.js`), and 2 unpatched Alpine OS packages (OpenSSL). None were in the app's own dependencies (`task-manager/package.json`), which came back clean both times.
**Fixed (2026-08-15, `task-manager/Dockerfile`, commit `ed352c1`):** `apk upgrade --no-cache` picks up the Alpine patch; `rm -rf` on npm/npx/corepack and their `/usr/local/lib/node_modules` entries removes the bundled CLI tools after `npm ci --omit=dev` (which still needs them) completes. Rescanned locally with Trivy afterward: **0 findings of any severity**, either target. Image size barely moved (47.6 → 50.2 MB via `docker inspect`, still well under the 200 MB target), and the app still passes its health check.
**Confirmed against the real scan (2026-08-15):** redeployed just `secrets` + `ecr` + `codebuild` (no VPC/ALB/ECS needed — see the standalone-build tip below) and ran `codebuild start-build` against the current GitHub source. Real Inspector v2 result: `CRITICAL=0 HIGH=0 MEDIUM=1 LOW=0` (even cleaner than the local Trivy scan, which found 0 across every severity). Full chain verified end-to-end: Docker build → push → Inspector scan → gate check → `BUILD SUCCEEDED`. This is the first fully green CodeBuild run this project has had.

**Tip — iterate on `buildspec.yml` without paying for the full stack:** `taskmanager-dev-build`'s CodeBuild project has `Source: GITHUB` + `Artifacts: NO_ARTIFACTS` and no `VpcConfig`, so it can run standalone, independent of the pipeline, ALB, ECS, or even the VPC stack:

```powershell
aws codebuild start-build --project-name taskmanager-dev-build --region eu-west-2
```

```powershell
aws codebuild batch-get-builds --ids <build-id> --region eu-west-2 `
  --query "builds[0].{Status:buildStatus,Phase:currentPhase}" --output table
```

This exercises the entire buildspec — SAST, tests, coverage, Docker build, ECR push, and the scan gate — against whatever's on the branch right now. Only `ecr`, `codebuild`, `secrets`, and `iam` need to be deployed for this to work. Use it to debug a buildspec change before spending a full pipeline execution (or the NAT/ALB cost of having the rest of the stack up) on it.

---

# 15. Autoscaling

To save cost:

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/ecs-autoscaling.yaml `
  --stack-name taskmanager-dev-autoscaling `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      MinCapacity=1 `
      MaxCapacity=2 `
      TargetCpuUtilization=70 `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Verify:

```powershell
aws application-autoscaling describe-scalable-targets `
  --service-namespace ecs `
  --resource-ids service/taskmanager-dev-cluster/taskmanager-dev-service `
  --region eu-west-2 `
  --query "ScalableTargets[0].{Min:MinCapacity,Max:MaxCapacity}" `
  --output table
```

### Expected

```text
1    2
```

This covers the CDC's HPA-like requirement.

---

# 16. Observability

```powershell
aws cloudformation deploy `
  --template-file infrastructure/cloudformation/observability.yml `
  --stack-name taskmanager-dev-observability `
  --parameter-overrides `
      ProjectName=taskmanager `
      Environment=dev `
      AlarmEmail=YOUR_EMAIL `
  --capabilities CAPABILITY_NAMED_IAM `
  --region eu-west-2
```

Verify:

```powershell
aws cloudwatch describe-alarms `
  --region eu-west-2 `
  --alarm-name-prefix taskmanager-dev `
  --query "MetricAlarms[].{Name:AlarmName,State:StateValue}" `
  --output table
```

Then:

```powershell
aws logs describe-log-groups `
  --region eu-west-2 `
  --query "logGroups[?contains(logGroupName,'taskmanager')].{Name:logGroupName,Retention:retentionInDays}" `
  --output table
```

### Expected

Retention:

```text
30
```

The CDC requires centralized logs with 30-day retention, a CloudWatch dashboard, pipeline metrics, and an alarm for pipelines running over 15 minutes.

And confirm the SNS email subscription:

```powershell
aws sns list-subscriptions `
  --region eu-west-2 `
  --query "Subscriptions[?contains(Endpoint,'@')].{Email:Endpoint,Status:SubscriptionArn}" `
  --output table
```

If you receive **AWS Notification – Subscription Confirmation**, click it.

---

# 17. CDC CHECKLIST — what needs to be visible

| CDC requirement    | Evidence to show                             |
| ------------------ | --------------------------------------------- |
| CloudFormation/IaC | 12 stacks `CREATE_COMPLETE`                   |
| VPC/subnets/SG     | VPC console + Resource Map                    |
| ECR                | repository + `ScanOnPush=true`                |
| ECS Fargate        | service `ACTIVE`, tasks `RUNNING`             |
| ALB                | DNS + target `healthy`                        |
| Secrets            | secrets present in Secrets Manager            |
| CodeBuild          | build `SUCCEEDED`                             |
| Tests ≥80%         | CodeBuild Reports / coverage                  |
| SAST               | CodeBuild logs + SAST step                    |
| CodePipeline       | pipeline with succeeded stages                |
| GitHub trigger     | push to `main` → pipeline runs                |
| CodeDeploy         | Blue/Green deployment                         |
| 10→50→100          | traffic-shifting screen                       |
| Rollback           | failed deployment then rollback               |
| Autoscaling        | `Min=1 Max=2`                                 |
| CloudWatch         | dashboard                                     |
| Logs               | `/ecs/...` and `/aws/codebuild/...`, 30 days  |
| SNS                | email received                                |
| Alarm >15 min      | CloudWatch alarm                              |

This checklist maps directly to the CDC's functional requirements.

---

# 18. BEFORE going over 1 hour: DELETE EVERYTHING

**Do not delete in an arbitrary order.**

```powershell
$stacks = @(
    "taskmanager-dev-observability",
    "taskmanager-dev-autoscaling",
    "taskmanager-dev-pipeline",
    "taskmanager-dev-ecs-service",
    "taskmanager-dev-taskdef",
    "taskmanager-dev-alb",
    "taskmanager-dev-ecs-cluster",
    "taskmanager-dev-iam",
    "taskmanager-dev-codebuild",
    "taskmanager-dev-ecr",
    "taskmanager-dev-secrets",
    "taskmanager-dev-vpc"
)

foreach ($s in $stacks) {
    Write-Host "DELETE $s" -ForegroundColor Yellow
    aws cloudformation delete-stack `
        --stack-name $s `
        --region eu-west-2

    aws cloudformation wait stack-delete-complete `
        --stack-name $s `
        --region eu-west-2
}
```

The reverse order is required because of the `Fn::ImportValue` dependencies between stacks.

### If `taskmanager-dev-vpc` ends up `DELETE_FAILED`

**Symptom:** `describe-stack-events` shows `PrivateSubnet1`/`PrivateSubnet2` failed to delete with `"has dependencies and cannot be deleted"`.

**Why:** if GuardDuty is enabled on this account, it auto-creates a `com.amazonaws.<region>.guardduty-data` interface VPC endpoint inside every VPC it monitors (tagged `GuardDutyManaged: true`). It isn't part of any CloudFormation stack, so CFN can't remove it, and its ENIs pin the private subnets.

**Fix:** find and delete it, then retry the stack delete.

```powershell
aws ec2 describe-vpc-endpoints `
  --region eu-west-2 `
  --filters "Name=service-name,Values=com.amazonaws.eu-west-2.guardduty-data" `
  --query "VpcEndpoints[?VpcId=='<taskmanager-vpc-id>'].VpcEndpointId" `
  --output text
```

```powershell
aws ec2 delete-vpc-endpoints --region eu-west-2 --vpc-endpoint-ids <id-from-above>
```

Wait ~1-2 minutes for the ENIs to detach, then re-run the `delete-stack` / `wait stack-delete-complete` pair from above for `taskmanager-dev-vpc`.

**If it then fails a second time, on the `Vpc` resource itself** ("has dependencies and cannot be deleted"), check for a leftover **GuardDuty-managed security group** — GuardDuty creates one alongside its VPC endpoint (named `GuardDutyManagedSecurityGroup-<vpc-id>`), and AWS won't delete a VPC while any non-default security group still exists in it, even an unattached one:

```powershell
aws ec2 describe-security-groups --region eu-west-2 `
  --filters "Name=vpc-id,Values=<taskmanager-vpc-id>" `
  --query "SecurityGroups[?GroupName!='default'].{Id:GroupId,Name:GroupName}" --output table
```

```powershell
aws ec2 delete-security-group --region eu-west-2 --group-id <id-from-above>
```

Then retry `delete-stack` / `wait stack-delete-complete` once more.

**Caution — don't touch VPCs you don't recognize.** While hunting this endpoint, it's easy to `describe-vpc-endpoints`/`describe-vpcs` and see *other* VPCs in the account with a similar `10.0.0.0/16` CIDR. That CIDR match is a coincidence, not a sign they're related to this project — check each VPC's `Name` tag before deleting anything on it. This account has at least one unrelated VPC (tagged `smartovate-cicd-vpc`) that must be left alone.

---

# 19. Final check — IMPORTANT

```powershell
aws cloudformation list-stacks `
  --region eu-west-2 `
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED `
  --query "StackSummaries[?starts_with(StackName,'taskmanager-dev')].{Stack:StackName,Status:StackStatus}" `
  --output table
```

Then:

```powershell
aws ec2 describe-nat-gateways `
  --region eu-west-2 `
  --filter "Name=state,Values=available,pending" `
  --query "NatGateways[].{ID:NatGatewayId,State:State}" `
  --output table
```

Then:

```powershell
aws elbv2 describe-load-balancers `
  --region eu-west-2 `
  --query "LoadBalancers[?contains(LoadBalancerName,'taskmanager')].LoadBalancerName" `
  --output table
```

Then:

```powershell
aws ecs list-tasks `
  --cluster taskmanager-dev-cluster `
  --region eu-west-2
```

### Final goal

```text
taskmanager-dev stacks: none
Available NAT Gateways: none
taskmanager ALBs: none
Running ECS tasks: none
```

---

## The 4 things to watch most closely

**1. Secrets Manager's 30-day recovery window blocks a fast redeploy.**
Deleting the `taskmanager-dev-secrets` stack doesn't immediately free the secret names (`taskmanager/dev/db`, `taskmanager/dev/api-key`) — AWS schedules them for deletion and holds the name for up to 30 days. Redeploying that stack again soon after a teardown fails with `... already scheduled for deletion`. If you hit this, force-delete both secrets before redeploying:
```powershell
aws secretsmanager delete-secret --secret-id taskmanager/dev/db --force-delete-without-recovery --region eu-west-2
aws secretsmanager delete-secret --secret-id taskmanager/dev/api-key --force-delete-without-recovery --region eu-west-2
```
Consider running this as part of step 18's teardown from now on, right after the `delete-stack` loop, so it never blocks the next session.

**2. GitHub Connection = `AVAILABLE`**
Don't start the pipeline until this shows `AVAILABLE`.

**3. Never leave the NAT Gateway running after the test.**
It's the main ongoing cost called out throughout this guide.

**4. GuardDuty can leave `taskmanager-dev-vpc` stuck in `DELETE_FAILED`.**
See step 18's dedicated troubleshooting note — delete the auto-created `guardduty-data` VPC endpoint, then retry.

### Approaches

* **Recommended for now:** deploy everything → 1 successful pipeline run → verify against the CDC checklist → delete everything.
* **Minimal budget:** stop after ECS + ALB, but then you haven't demonstrated the full CI/CD flow.
* **Maximum demonstration:** add a second deployment and trigger a rollback; only useful if you actually need to show the Blue/Green/rollback mechanism.

**Immediate next step (as of 2026-08-15):** all three CodeBuild-stage bugs (immutable-tag false failure, broken scan waiter, missing Inspector IAM permissions) plus the Dockerfile CVE fix are committed **and confirmed working end-to-end via a standalone `codebuild start-build`** against the real account (`CRITICAL=0 HIGH=0`, `BUILD SUCCEEDED` — see this section's Symptom 3). Only `secrets`/`ecr`/`codebuild` were deployed for that test; `vpc`/`iam`/`ecs-*`/`alb`/`pipeline`/`autoscaling`/`observability` are still torn down. Next real test: deploy the remaining stacks (steps 3, 8-16) and run an actual pipeline execution — this should be the first run to ever reach Approval/Deploy, which is still genuinely untested territory (CodeDeploy Blue/Green, the traffic shift, ECS/ALB health).

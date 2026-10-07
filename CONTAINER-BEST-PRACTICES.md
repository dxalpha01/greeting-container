# Supporting Changes for Container Best Practice

This document covers the deliverable **"any other changes to support best practice with containers"**. It describes every change outside the `Dockerfile` and `app/`: what each one is for, the practice it follows, and how to verify it. The `Dockerfile` itself is explained in [SOLUTION.md](SOLUTION.md#dockerfile-design).

## Summary

```text
.dockerignore                 # keeps the build context to what the image needs
constraints.txt               # locks the full dependency tree for reproducible builds
scripts/smoke-test.sh         # automated test of the image's behaviour and hardening
.github/workflows/ci.yml      # lints, builds, tests and scans the image on every push
.gitattributes                # keeps the shell script runnable when checked out on Windows
SOLUTION.md                   # how to configure, run, test and publish the image
CONTAINER-BEST-PRACTICES.md   # this document
```

The published image also follows registry practices that are not files in the repository; see [Publishing practices](#publishing-practices).

## `.dockerignore`: minimal build context

**Problem.** The original `Dockerfile` ran `COPY . .`, so everything in the repository went into the image: `.git` history, documentation, editor settings and anything else lying in the folder. That makes the image larger, invalidates the build cache whenever any file changes, and risks shipping secrets such as a stray `.env` file.

**Change.** `.dockerignore` uses an allow-list: it ignores everything (`*`), then re-includes only `app/` and `constraints.txt`. Python bytecode caches inside `app/` are excluded too.

**Why an allow-list.** A deny-list has to anticipate every file that should not be shipped. With an allow-list, new files added to the repository later stay out of the build by default.

**Verify.** The build output reports the context size. It is a few hundred bytes:

```sh
docker build -t sample-app:dev . 2>&1 | grep "transferring context"
```

## `constraints.txt`: reproducible dependencies

**Problem.** `app/requirements.txt` pins only `flask` and `gunicorn`. Their own dependencies (Werkzeug, Jinja2, click, MarkupSafe, itsdangerous, blinker and packaging) were unpinned, so two builds of the same commit could install different versions. That can introduce bugs or vulnerabilities without any code change.

**Change.** `constraints.txt` pins every package in the dependency tree. The `Dockerfile` installs with `pip install -r app/requirements.txt -c constraints.txt`. A constraints file only restricts versions; it never adds packages, so `app/requirements.txt` stays the source of truth for *what* is installed while `constraints.txt` decides *which version*. This keeps `app/` unmodified, as the task requires.

**Updating.** To upgrade dependencies, resolve them again for Linux and Python 3.12 and replace the pins:

```sh
pip install --dry-run --ignore-installed --report report.json \
  --python-version 3.12 --platform manylinux2014_x86_64 --only-binary=:all: \
  -r app/requirements.txt
```

**Verify.** pip is not in the runtime image, so list the installed packages with Python's standard library instead. The output matches `constraints.txt` exactly:

```sh
docker run --rm ghcr.io/dxalpha01/sample-app:v2 python -c "from importlib.metadata import distributions; print('\n'.join(sorted(f'{d.name}=={d.version}' for d in distributions())))"
```

## `scripts/smoke-test.sh`: automated image test

**Problem.** Without a test, "production-quality" is a claim. Regressions such as a change that makes the container run as root, or that breaks it on a read-only filesystem, would only be noticed after deployment.

**Change.** A script that builds the image (or takes an existing image name), runs it under the restrictions a hardened Kubernetes pod would apply, and checks the result. The container runs with a read-only root filesystem, all Linux capabilities dropped, `no-new-privileges`, and a non-default `PORT`. The script checks that:

-   the image is configured to run as UID 10001, and the process really does
-   no compilers, `curl` or `vim` are present, and pip has been removed
-   application files cannot be written by the app user
-   `/healthz`, `/` and `/info` respond correctly and honour the `GREETING` and `PORT` variables
-   access logs reach stdout, where `kubectl logs` can read them
-   Docker's `HEALTHCHECK` reports `healthy`
-   the container exits cleanly (exit code 0) within the stop timeout when sent `SIGTERM`

It exits non-zero if any check fails and prints the container logs. The CI workflow runs it unchanged.

**Evidence it catches problems.** All 12 checks pass against `ghcr.io/dxalpha01/sample-app:v2`. Against the original `Dockerfile`, the non-root, tooling and file-permission checks fail, and the container crashes on startup with a read-only filesystem because gunicorn cannot create its worker temporary files.

**Verify.**

```sh
./scripts/smoke-test.sh ghcr.io/dxalpha01/sample-app:v2
```

## `.github/workflows/ci.yml`: continuous integration

**Problem.** Checks that only run when someone remembers to run them stop protecting the image. A change that adds a vulnerable package, breaks the read-only filesystem support or introduces a `Dockerfile` anti-pattern should fail before it is merged, not after it is deployed.

**Change.** A GitHub Actions workflow runs on every push and pull request:

1.  **Lint** the `Dockerfile` with [Hadolint](https://github.com/hadolint/hadolint). Any finding fails the build.
2.  **Build** the image.
3.  **Smoke test** it with `scripts/smoke-test.sh`, exactly as a developer would locally.
4.  **Scan** it with [Trivy](https://trivy.dev/). The build fails on any HIGH or CRITICAL vulnerability that has a fix available. Findings with no fix are reported but don't block, because nothing can be done about them until the distribution publishes a fix.

**Hardening of the workflow itself:**

-   **Tools pinned by digest or commit.** Hadolint and Trivy run from container images pinned by digest, and `actions/checkout` is pinned to a commit SHA. A moved or hijacked tag cannot change what runs in CI. Third-party GitHub Actions have been compromised through retagged releases, so this avoids depending on any beyond `actions/checkout`.
-   **Least-privilege token.** The workflow's `GITHUB_TOKEN` is read-only (`permissions: contents: read`), and the checkout does not leave credentials in the workspace.
-   **Bounded runs.** A 15-minute timeout, and superseded runs on the same branch are cancelled.

Publishing and multi-architecture builds are deliberately left out of CI for now; see [Recommended next steps](#recommended-next-steps).

**Verify.** The workflow's runs are listed under the repository's **Actions** tab. Each step can also be run locally with Docker:

```sh
docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile
docker build -t sample-app:ci .
./scripts/smoke-test.sh sample-app:ci
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.75.0 image \
  --db-repository ghcr.io/aquasecurity/trivy-db:2 --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 sample-app:ci
```

## `.gitattributes`: portable scripts

**Problem.** Git on Windows can convert line endings to CRLF on checkout. A shell script with CRLF line endings fails in Linux containers and CI runners with errors such as `/usr/bin/env: 'bash\r': No such file or directory`.

**Change.** `.gitattributes` forces `*.sh` files to LF line endings on every platform. The script is also stored in Git as executable, so `./scripts/smoke-test.sh` works straight after a clone on Linux, macOS and CI runners.

## `SOLUTION.md`: operational documentation

**Problem.** An image is only usable if people know how to configure, run and verify it. The person deploying it in the next stage (Kubernetes) needs to know which variables it reads, which port it listens on, which user it runs as and how to probe its health.

**Change.** [SOLUTION.md](SOLUTION.md) documents:

-   the environment variables, their defaults and what they control
-   the security properties a Kubernetes manifest can rely on (UID 10001, read-only root filesystem, no capabilities needed, `/healthz` for probes)
-   the reasoning behind each `Dockerfile` decision
-   how to test the image by hand and with the smoke test
-   how versions are tagged, what changed in each version, and how to publish
-   the current vulnerability scan results

The original `README.md` (the task brief) is left unchanged.

## Publishing practices

These apply to the published image rather than to files in the repository.

-   **Immutable version tags.** Images are published with version tags, never `latest`. `v2` was published as a new tag rather than overwriting `v1`, so anything that references `v1` still gets exactly the image it was tested with. For full immutability, a deployment can also reference the image by digest.
-   **Linked to its source.** The `org.opencontainers.image.source` label links the GHCR package to this repository, so anyone pulling the image can find the code and `Dockerfile` that built it. The image also carries title, description and licence labels.
-   **Public and pullable without credentials.** The package visibility is public, so the Kubernetes cluster in the next stage needs no image-pull secret. This was verified by logging out of `ghcr.io` and pulling the image.
-   **Build provenance.** Docker BuildKit attached a provenance attestation recording how the image was built. These appear as `unknown/unknown` entries on the package page.
-   **Vulnerability scanned.** `v2` has no findings in any Python package and nothing fixable at HIGH or CRITICAL severity. The remaining findings are in Debian 13 packages with no fix published yet; see [SOLUTION.md](SOLUTION.md#vulnerability-scan).

## Recommended next steps

These are **not implemented**. They are what I would add before running this in a real production environment.

-   **Automate base image and dependency updates.** Because the base image is pinned by digest, it does not pick up security fixes on its own. Dependabot or Renovate can open pull requests when a new digest or package version is published, and the CI workflow would test each one.
-   **Release pipeline.** Extend CI so that pushing a Git tag such as `v3` builds the image for amd64 and arm64 and pushes it to GHCR, instead of publishing from a laptop.
-   **Signing and SBOM.** Sign the image with cosign and publish a software bill of materials (SBOM, a list of everything in the image), so the cluster can verify the image before running it.
-   **Smaller base image.** A distroless or similarly minimal base would remove most of the remaining operating-system packages, and with them most of the unfixed findings. It would also remove the shell that several smoke-test checks run inside the container, so those checks would need reworking.
-   **Kubernetes hardening (stage 2).** A pod `securityContext` with `runAsNonRoot`, `readOnlyRootFilesystem` and all capabilities dropped; CPU and memory requests and limits; liveness and readiness probes on `/healthz`; and a NetworkPolicy. The image already supports all of these.

# Solution: Containerising the Greeting App

This document describes my solution to the task in [README.md](README.md).

**Image:** [`ghcr.io/dxalpha01/sample-app:v2`](https://github.com/users/dxalpha01/packages/container/package/sample-app) (public, no credentials needed)

```sh
docker run --rm -p 8080:8080 -e GREETING="Hello" ghcr.io/dxalpha01/sample-app:v2
curl http://localhost:8080/
```

## What changed

```text
Dockerfile                    # rewritten: multi-stage, non-root production image
.dockerignore                 # new: only app/ and constraints.txt are sent to the build
constraints.txt               # new: pins the full dependency tree for reproducible builds
scripts/smoke-test.sh         # new: builds (or pulls) the image and checks it end to end
.github/workflows/ci.yml      # new: Hadolint, build, smoke test and Trivy scan on every push
.gitattributes                # new: keeps shell scripts on LF line endings
SOLUTION.md                   # new: this document
CONTAINER-BEST-PRACTICES.md   # new: why each supporting change was made, and next steps
app/                          # unmodified
```

[CONTAINER-BEST-PRACTICES.md](CONTAINER-BEST-PRACTICES.md) explains each supporting change in detail.

## Configuration

All settings are environment variables, so they can be set in a Kubernetes manifest without changing the image or its command.

| Variable            | Default                                                          | Purpose                             |
| ------------------- | ---------------------------------------------------------------- | ----------------------------------- |
| `GREETING`          | `Hello from the sample app!`                                     | Message returned by `GET /`         |
| `PORT`              | `8080`                                                           | Port gunicorn binds to on `0.0.0.0` |
| `WEB_CONCURRENCY`   | `2`                                                              | Number of gunicorn worker processes |
| `GUNICORN_CMD_ARGS` | `--worker-tmp-dir /dev/shm --access-logfile - --error-logfile -` | Extra gunicorn flags                |

For Kubernetes, use `/healthz` for liveness and readiness probes. The container runs as UID/GID `10001` and works with `readOnlyRootFilesystem: true`, `runAsNonRoot: true` and all capabilities dropped.

## Dockerfile design

### Smaller, safer image

-   **Current, slim base image, pinned by digest.** `python:3.12-slim-trixie` (Debian 13) replaces the full `python:3.12` image. Debian 12 left regular security support in July 2026 and now receives long-term-support updates only, so a new image should not start on it. The digest is the multi-architecture index, so builds are reproducible on both amd64 and arm64.
-   **Multi-stage build.** Dependencies are installed into a virtual environment in a `builder` stage. Only that environment and the application code are copied into the runtime stage.
-   **No build or debugging tools.** `build-essential`, `gcc`, `curl` and `vim` are removed. Flask and gunicorn are pure Python, so no compiler is needed, and fewer tools mean a smaller attack surface.
-   **No package installer at runtime.** pip is only needed to build the virtual environment. It is uninstalled from the virtual environment in the builder stage and from the base image's Python in the runtime stage, so it cannot be used to install anything into a running container. This also removed every fixable Python vulnerability that the `v1` scan found.
-   **Minimal build context.** `.dockerignore` excludes everything except `app/` and `constraints.txt`, so `.git`, documentation and local files never reach the image.

### Security

-   **Non-root user.** The container runs as a dedicated system user with a fixed UID (`10001`), so Kubernetes `runAsNonRoot` can verify it.
-   **Read-only application code.** Application files are owned by root and readable, but not writable, by the app user. `--chmod=u=rwX,go=rX` makes permissions independent of the build machine's umask.
-   **Read-only root filesystem.** Gunicorn's worker heartbeat files go to `/dev/shm`, so the container needs no writable paths. The original image crashes on a read-only filesystem.
-   **Health check without extra tools.** `HEALTHCHECK` calls `/healthz` with Python's built-in `urllib` rather than installing `curl`.

### Build efficiency and reproducibility

-   **Layer ordering.** Dependencies are installed before the application code is copied, so code changes don't reinstall dependencies.
-   **BuildKit cache and bind mounts.** pip's download cache persists between builds, and `requirements.txt` is bind-mounted rather than copied into a layer.
-   **Locked transitive dependencies.** `app/requirements.txt` only pins Flask and gunicorn. `constraints.txt` pins everything else (Werkzeug, Jinja2, click and so on), so two builds of the same commit produce the same dependency set.
-   **Bytecode precompiled at build time.** pip compiles `.pyc` files in the builder stage. `PYTHONDONTWRITEBYTECODE` is set only at runtime, where the app user cannot write them anyway.

### Runtime behaviour

-   **Gunicorn remains the container command** (`gunicorn --chdir app app:app`), and the original `/app/app` layout is kept, so manifests that reuse the original command still work.
-   **Gunicorn flags live in the environment.** If a Kubernetes manifest overrides `args`, the logging and `/dev/shm` settings survive.
-   **Logs to stdout/stderr** with unbuffered Python output, for `kubectl logs` and log collectors.
-   **Clean shutdown.** Gunicorn runs as PID 1 (exec-form `CMD`), so it receives `SIGTERM` directly and exits gracefully.
-   **OCI labels.** `org.opencontainers.image.source` links the GHCR package to this repository.

## Versioning

The version is not set in the `Dockerfile`. It is the image tag, chosen at build time with `-t`. Each release gets a new tag; existing tags are never overwritten, so a deployment that references a tag always gets the same image.

| Tag  | Base image                  | Changes                                                |
| ---- | --------------------------- | ------------------------------------------------------ |
| `v1` | `python:3.12-slim-bookworm` | First production image                                 |
| `v2` | `python:3.12-slim-trixie`   | Moved to Debian 13; removed pip from the runtime image |

`v2` is the version to deploy. `v1` is kept unchanged.

## Testing locally

The examples use `curl`. In Windows PowerShell, type `curl.exe`, because `curl` is an alias for `Invoke-WebRequest` there.

### Run and call the endpoints

```sh
docker run -d --name sample-app -p 8080:8080 -e GREETING="Hello" ghcr.io/dxalpha01/sample-app:v2

curl http://localhost:8080/          # {"hostname":"...","message":"Hello"}
curl http://localhost:8080/healthz   # {"status":"ok"}
curl http://localhost:8080/info      # {"greeting":"Hello","hostname":"...","port":8080}
```

### Inspect the running container

```sh
docker logs sample-app                                         # gunicorn start-up and access logs
docker exec sample-app id                                      # uid=10001(app) gid=10001(app)
docker inspect --format '{{.State.Health.Status}}' sample-app  # healthy (after about 30 seconds)
docker stop sample-app                                         # should stop within a second or two
docker rm sample-app
```

### Run it the way Kubernetes would

This uses a read-only filesystem, drops all capabilities and changes the port:

```sh
docker run --rm -p 9090:9090 -e PORT=9090 --read-only --cap-drop ALL --security-opt no-new-privileges ghcr.io/dxalpha01/sample-app:v2
curl http://localhost:9090/info      # "port":9090
```

To test a local build instead of the published image, build it first with `docker build -t sample-app:dev .` and use `sample-app:dev` in place of `ghcr.io/dxalpha01/sample-app:v2`.

### Run the smoke test

`scripts/smoke-test.sh` automates the checks above. It needs Docker and curl; on Windows, run it from Git Bash. With no argument it builds the image from this repository; with an argument it tests an existing image:

```sh
./scripts/smoke-test.sh                                    # build and test the local Dockerfile
./scripts/smoke-test.sh ghcr.io/dxalpha01/sample-app:v2    # test the published image
```

It runs the container with a read-only root filesystem, all capabilities dropped and a non-default `PORT`, then checks that:

-   the image is configured to run as UID 10001 and contains no compilers, `curl`, `vim` or pip
-   application files are not writable by the app user
-   `/healthz`, `/` and `/info` respond correctly and honour `GREETING` and `PORT`
-   access logs reach stdout and the Docker health check reports `healthy`
-   the container stops cleanly on `SIGTERM`

The script exits non-zero if any check fails and prints the container logs. Run against the original Dockerfile, it fails the non-root, tooling and file-permission checks, and the container crashes on a read-only filesystem.

## Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push and pull request. It lints the `Dockerfile` with Hadolint, builds the image, runs the smoke test, and scans the image with Trivy, failing on any HIGH or CRITICAL vulnerability that has a fix available. The tools are pinned by digest or commit. See [CONTAINER-BEST-PRACTICES.md](CONTAINER-BEST-PRACTICES.md#githubworkflowsciyml-continuous-integration) for details.

## Publishing

Log in to GHCR with a classic personal access token that has the `write:packages` scope, then build and push a new version tag:

```sh
echo "$GITHUB_TOKEN" | docker login ghcr.io -u dxalpha01 --password-stdin
docker build -t ghcr.io/dxalpha01/sample-app:v2 .
docker push ghcr.io/dxalpha01/sample-app:v2
```

## Vulnerability scan

`v2` was scanned with Trivy 0.75.0:

| Area                                  | `v1` (Debian 12, with pip)  | `v2` (Debian 13, no pip)  |
| ------------------------------------- | --------------------------- | ------------------------- |
| Python packages                       | 12, all in pip, all fixable | 0                         |
| Operating-system packages             | 264 (2 critical, 53 high)   | 165 (0 critical, 44 high) |
| HIGH or CRITICAL with a fix available | 0                           | 0                         |

-   **The application dependencies are clean.** Flask, Werkzeug, Jinja2 and gunicorn have no findings. Gunicorn's request-smuggling advisories ([CVE-2024-6827](https://github.com/advisories/GHSA-hc5x-x2vx-497g), [CVE-2024-1135](https://github.com/advisories/GHSA-w3h3-4rj7-4ph4)) affect versions below 22.0.0, so the pinned `22.0.0` is not affected.
-   **The remaining findings have no fix available yet.** They are in Debian 13 system packages such as `util-linux`, `ncurses` and `systemd` libraries, which the app does not call directly. Debian has not yet published fixed versions. Rebuilding the image picks up fixes once it does, and the CI scan fails if a fixable HIGH or CRITICAL finding appears.

Reproduce the scan:

```sh
docker run --rm aquasec/trivy:0.75.0 image --db-repository ghcr.io/aquasecurity/trivy-db:2 ghcr.io/dxalpha01/sample-app:v2
```

## Known issues

-   **Builds on Windows set the execute bit on application files.** Windows build contexts mark every file as executable, and `--chmod=u=rwX` preserves an existing execute bit. This is harmless because the files are still read-only to the app user. Builds on Linux, macOS or CI produce `0644` files.

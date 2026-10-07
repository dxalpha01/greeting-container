# Containerising the Greeting App

This is my write-up for the task described in [README.md](README.md). The short version: I rewrote the `Dockerfile` so the image is smaller, runs as a non-root user, builds reproducibly and works under the restrictions you'd expect in a hardened Kubernetes cluster. I then added a smoke test and a CI pipeline so those properties stay true.

The image is public, so you can pull it without logging in:

```sh
docker run --rm -p 8080:8080 -e GREETING="Hello" ghcr.io/dxalpha01/sample-app:v2
curl http://localhost:8080/
```

You can find it on the [GHCR package page](https://github.com/users/dxalpha01/packages/container/package/sample-app). `v2` is the version to use.

## What I changed

I didn't touch anything in `app/`. Everything else I added or changed is listed here:

```text
Dockerfile                    # rewritten
.dockerignore                 # new: only app/ and constraints.txt go into the build
constraints.txt               # new: pins every dependency, not just the top-level ones
scripts/smoke-test.sh         # new: runs the image and checks it behaves as described below
.github/workflows/ci.yml      # new: lints, builds, tests and scans the image on every push
.gitattributes                # new: keeps the shell script working when checked out on Windows
SOLUTION.md                   # new: this document
CONTAINER-BEST-PRACTICES.md   # new: the reasoning behind each supporting file, and next steps
```

[CONTAINER-BEST-PRACTICES.md](CONTAINER-BEST-PRACTICES.md) goes into more detail on the supporting files. This document focuses on the image itself and how to use it.

## Configuring the container

Everything is controlled through environment variables, so whoever deploys it can change the behaviour from a Kubernetes manifest without rebuilding the image or touching its command.

| Variable            | Default                                                          | What it does                        |
| ------------------- | ---------------------------------------------------------------- | ----------------------------------- |
| `GREETING`          | `Hello from the sample app!`                                     | The message returned by `GET /`     |
| `PORT`              | `8080`                                                           | The port gunicorn listens on        |
| `WEB_CONCURRENCY`   | `2`                                                              | How many gunicorn worker processes  |
| `GUNICORN_CMD_ARGS` | `--worker-tmp-dir /dev/shm --access-logfile - --error-logfile -` | Extra gunicorn settings (see below) |

If you're writing the Kubernetes manifest, the useful facts are: use `/healthz` for the liveness and readiness probes, and the container runs as UID and GID `10001`. It works with `runAsNonRoot: true`, `readOnlyRootFilesystem: true` and all capabilities dropped; the smoke test checks the Docker equivalents of all three.

## How the Dockerfile works, and why

### Where I started

The original `Dockerfile` worked, but it built on the full `python:3.12` image and installed `gcc`, `build-essential`, `curl` and `vim` on top. It copied the whole repository into the image and ran everything as root. None of those tools are needed to run a Flask app: Flask and gunicorn are pure Python, so there's nothing to compile. Each of them is extra size and extra attack surface.

### A smaller, current base image

I switched to `python:3.12-slim-trixie`, the slim variant of the official Python image on Debian 13. I originally used Debian 12 (`bookworm`) for `v1`. I moved to Debian 13 for `v2` because Debian 12's regular security support ended in July 2026, and it's hard to justify starting a new production image on a release that only gets long-term-support updates.

The base image is pinned by digest as well as by tag. The tag `3.12-slim-trixie` moves whenever Docker publishes an update, but the digest always refers to the same image, so every build starts from exactly the same place. The digest I pinned is the multi-architecture one, so this works on both amd64 and arm64 machines.

### Two build stages

The `Dockerfile` has two stages. The first one, `builder`, creates a Python virtual environment and installs the dependencies into it. The second one, which becomes the final image, starts again from a clean base and copies across only that virtual environment and the application code. Anything used during the build stays behind.

pip is one of those things. It's needed to install the dependencies, but once they're installed it has no job left to do, and a package installer inside a running container is a tool an attacker could use. So I uninstall it from the virtual environment at the end of the build stage, and from the base image's own Python in the final stage. That also cleared every fixable Python vulnerability that my scan of `v1` had found, all of which were in pip.

I also added a `.dockerignore` that works as an allow-list. It excludes everything except `app/` and `constraints.txt`, so `.git`, documentation and anything else lying around never reach the build.

### Running safely

The container runs as a dedicated user with a fixed ID, `10001`, rather than root. Using a number rather than just a name matters in Kubernetes: `runAsNonRoot` can only verify that a container isn't root if the image declares a numeric user.

The application files are owned by root and are readable but not writable by that user, so a compromised process can't modify the code it's running. I set the permissions explicitly with `--chmod=u=rwX,go=rX` so the result doesn't depend on how the files happened to be checked out on whichever machine did the build.

One change was needed for read-only filesystems. Gunicorn's worker processes regularly write small heartbeat files so the main process can tell they're still alive. By default these go to a normal temporary directory, which doesn't exist when the root filesystem is read-only. The original image simply crashes in that situation. I pointed them at `/dev/shm`, which is in memory and always writable, so the container no longer needs any writable disk at all.

The health check calls `/healthz` using Python's built-in `urllib`, so I didn't have to install `curl` just for that.

### Faster, repeatable builds

The dependencies are installed before the application code is copied in. Docker caches each step, so if you only change `app.py`, the rebuild skips the dependency installation entirely. pip's download cache is also kept between builds using a BuildKit cache mount. `requirements.txt` is mounted into the install step rather than copied into the image.

Repeatability was the other gap. `app/requirements.txt` pins Flask and gunicorn, but not the packages they depend on, such as Werkzeug, Jinja2 and click. Two builds a month apart could quietly end up with different versions. The task said not to modify `app/`, so I added `constraints.txt` at the root, which pins the complete dependency tree. pip reads it alongside `requirements.txt`: `requirements.txt` still decides what gets installed, and `constraints.txt` decides which version.

### Behaving well at runtime

Gunicorn is still the container's command (`gunicorn --chdir app app:app`), as the task asked. I kept the application at `/app/app`, the same location as the original image, so any manifest that copies the original command still works.

I put gunicorn's settings in the `GUNICORN_CMD_ARGS` environment variable rather than on the command line. Kubernetes lets a manifest replace a container's command arguments, and if the settings lived there they'd disappear along with them, including the `/dev/shm` fix. In an environment variable, they survive.

Logs go to standard output and error with Python's output buffering turned off, so they show up in `docker logs` and `kubectl logs` straight away. Gunicorn runs as the container's main process, so when Kubernetes asks it to stop, it receives the signal directly, finishes any requests in progress and exits cleanly.

Finally, the image carries standard labels, including one that links the GHCR package back to this repository, so anyone who finds the image can find the code that built it.

## Versions

The version isn't written in the `Dockerfile`. It's the tag I give the image when I build it, using `-t`. I never overwrite a tag once it's published: a deployment that references `v1` will always get exactly the image that was tested as `v1`.

| Tag  | Base image                  | What changed                                           |
| ---- | --------------------------- | ------------------------------------------------------ |
| `v1` | `python:3.12-slim-bookworm` | First production image                                 |
| `v2` | `python:3.12-slim-trixie`   | Moved to Debian 13; removed pip from the runtime image |

## Trying it yourself

A note for Windows users: in PowerShell, type `curl.exe` rather than `curl`, because there `curl` is a shortcut for a different command, `Invoke-WebRequest`.

### Start it and call the endpoints

```sh
docker run -d --name sample-app -p 8080:8080 -e GREETING="Hello" ghcr.io/dxalpha01/sample-app:v2

curl http://localhost:8080/          # {"hostname":"...","message":"Hello"}
curl http://localhost:8080/healthz   # {"status":"ok"}
curl http://localhost:8080/info      # {"greeting":"Hello","hostname":"...","port":8080}
```

### Look inside it

```sh
docker logs sample-app                                         # gunicorn's start-up and access logs
docker exec sample-app id                                      # uid=10001(app) gid=10001(app)
docker inspect --format '{{.State.Health.Status}}' sample-app  # "healthy", after about 30 seconds
docker stop sample-app                                         # should stop within a second or two
docker rm sample-app
```

### Run it the way a locked-down cluster would

This makes the filesystem read-only, removes every Linux capability and moves the app to a different port:

```sh
docker run --rm -p 9090:9090 -e PORT=9090 --read-only --cap-drop ALL --security-opt no-new-privileges ghcr.io/dxalpha01/sample-app:v2
curl http://localhost:9090/info      # "port":9090
```

To try your own build instead of the published one, run `docker build -t sample-app:dev .` first and use `sample-app:dev` in place of the GHCR name.

### Run the smoke test

`scripts/smoke-test.sh` does all of the above automatically. You'll need Docker and curl; on Windows, run it from Git Bash. Without an argument it builds the image from this repository first. With an image name, it tests that image instead:

```sh
./scripts/smoke-test.sh                                    # build and test the local Dockerfile
./scripts/smoke-test.sh ghcr.io/dxalpha01/sample-app:v2    # test the published image
```

It runs the container with a read-only filesystem, no capabilities and a non-default port, then checks that:

-   the image runs as UID 10001, and contains no compilers, `curl`, `vim` or pip
-   the app user can't modify the application files
-   `/healthz`, `/` and `/info` respond correctly and pick up `GREETING` and `PORT`
-   access logs reach standard output, and Docker's health check reports `healthy`
-   the container shuts down cleanly when asked to stop

If anything fails, the script says which check failed, prints the container's logs and exits with an error. To make sure it actually catches problems, I ran it against an image built from the original commit. That image fails the non-root, tooling, pip and file-permission checks, then crashes as soon as it starts on a read-only filesystem.

## Continuous integration

Checks only help if they run, so [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push and pull request. It lints the `Dockerfile` with Hadolint, builds the image, runs the smoke test and scans the result with Trivy. The scan fails the build if it finds a HIGH or CRITICAL vulnerability that has a fix available. The tools are pinned to exact versions so that a change upstream can't silently alter what the pipeline runs. [CONTAINER-BEST-PRACTICES.md](CONTAINER-BEST-PRACTICES.md#githubworkflowsciyml-continuous-integration) has the details.

## Publishing a new version

Log in to GHCR with a classic personal access token that has the `write:packages` scope, then build and push with a new tag:

```sh
echo "$GITHUB_TOKEN" | docker login ghcr.io -u dxalpha01 --password-stdin
docker build -t ghcr.io/dxalpha01/sample-app:v2 .
docker push ghcr.io/dxalpha01/sample-app:v2
```

## Vulnerability scan

I scanned both versions with Trivy 0.75.0:

| Area                                  | `v1` (Debian 12, with pip)  | `v2` (Debian 13, no pip)  |
| ------------------------------------- | --------------------------- | ------------------------- |
| Python packages                       | 12, all in pip, all fixable | 0                         |
| Operating-system packages             | 264 (2 critical, 53 high)   | 165 (0 critical, 44 high) |
| HIGH or CRITICAL with a fix available | 0                           | 0                         |

The application's own dependencies are clean: Flask, Werkzeug, Jinja2 and gunicorn have no findings. I specifically checked gunicorn's request-smuggling advisories, [CVE-2024-6827](https://github.com/advisories/GHSA-hc5x-x2vx-497g) and [CVE-2024-1135](https://github.com/advisories/GHSA-w3h3-4rj7-4ph4), because they're the obvious concern for a Python web server. Both only affect versions below 22.0.0, and this image uses 22.0.0.

The 165 findings that remain are in Debian 13 system packages, such as `util-linux`, `ncurses` and the `systemd` libraries, which the app doesn't use directly. Debian hasn't published fixes for any of them yet. Rebuilding the image picks the fixes up once it does. In the meantime, the CI scan will fail as soon as a fixable HIGH or CRITICAL issue appears.

To run the scan yourself:

```sh
docker run --rm aquasec/trivy:0.75.0 image --db-repository ghcr.io/aquasecurity/trivy-db:2 ghcr.io/dxalpha01/sample-app:v2
```

## Known quirks

If you build the image on Windows, the application files end up marked as executable. Windows doesn't have Unix-style permissions, so Docker treats every file it sends from a Windows machine as executable, and my `--chmod` setting keeps that bit rather than removing it. It's harmless, because the files are still read-only to the app user, and builds on Linux, macOS or in CI produce normal non-executable files.

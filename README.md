# Polarion Docker

Run Polarion ALM in OCI-compatible containers on macOS, Windows, and Linux. This repository provides a flexible Dockerfile and setup scripts to easily containerize a fresh Polarion installation.

## 🌟 Features

The Docker image and its entrypoint scripts (`polarion_starter.sh` & `entrypoint.d/`) automatically handle many complex configurations that are usually manual:

- **Modular Entrypoint System**: Startup logic is split into lightweight scripts in `/opt/polarion/entrypoint.d/` for easy extensibility.
- **WebSocket Support**: Automatically configures Apache `ProxyPassMatch` to enable Polarion LiveDoc collaboration and other real-time features.
- **SVN HTTP Aliases**: Exposes the bundled Subversion repository externally under both `/repo` and `/repo-local`.
- **PostgreSQL Auto-Config**: Sets up `listen_addresses` and `pg_hba.conf` to allow external connections (essential for container networking).
- **URL Correction**: Automatically fixes `localhost` references in configuration files to `127.0.0.1` for proper container behavior.
- **Remote Debugging (JDWP)**: One-click remote debugging support on port 5005.
- **Memory Management**: Easy configuration of JVM memory via `JAVA_OPTS`.

## 🚀 Getting Started

### Runtime Support

| Runtime           | Status                       | Notes                                                                                                                               |
| :---------------- | :--------------------------- | :---------------------------------------------------------------------------------------------------------------------------------- |
| Docker            | Primary                      | Supported for local development, Docker Compose, and CI publishing workflows.                                                       |
| Podman            | Secondary                    | Supported for local builds.                                                                                                         |
| Apple `container` | Local Apple silicon workflow | Supported for local macOS 26+ development through CLI commands and VS Code tasks. Docker Compose is not available for this runtime. |

There are two ways to use this image: building it yourself (recommended for most users) or requesting access to pre-built images.

### Option A: Local Build (Recommended)

Since Polarion requires a license and the installation media is proprietary, you can build this Docker image locally using your own Polarion ZIP file.

1.  **Download** the Polarion for Linux ZIP distribution (e.g., `Polarion-2512.zip`) from Siemens.
2.  **Place** the downloaded ZIP file in the data directory of this repository.
    - _Note: The build script automatically picks up any file matching `polarion_.zip`.\*
    - _Note: On Linux systems with SELinux enabled, set the context on `data` with `chcon -Rt 'container_file_t' data/`._
3.  **Place** your license files in the repo:
    - Put the Polarion core XML license in `files/` as `polarion.lic`. The start scripts sync XML `polarion.lic` files from `files/` into `/opt/polarion/polarion/license/polarion.lic`.
    - Put the avasis extension license in `data/` as `avasis.licence`. The start scripts sync it into `/opt/polarion/polarion/license/avasis.licence`.
    - If you omit `files/polarion.lic` for local development, `bash scripts/polarionctl.sh start` auto-starts the local 30-day trial when Polarion lands on the activation page.
4.  **Build** the Docker image:
    ```bash
    # With Docker
    docker build -t polarion .
    # With Podman
    podman build --network private -t polarion .
    # With Apple container
    container system start
    container builder start --cpus 8 --memory 4g
    container build --platform linux/amd64 -t polarion:local .
    container builder stop
    ```

### Option B: Pre-built Images

Pre-built images are hosted on the GitHub Container Registry (`ghcr.io/phillipboesger/polarion-docker`).
**Note:** Access to these images is **restricted**. You must request access from the repository owner to pull them.

If you have access:

1.  **Create a Personal Access Token (PAT)**:
    - Go to **GitHub Settings** > **Developer settings** > **Personal access tokens** > **Tokens (classic)**.
    - Generate a new token with the `read:packages` scope selected.
2.  **Login to the registry**:
    Replace `YOUR_GITHUB_TOKEN` and `YOUR_GITHUB_USERNAME` with your details:
    ```bash
    echo "YOUR_GITHUB_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
    ```
3.  **Run the container**:
    This command pulls the latest image and starts Polarion immediately:
    ```bash
docker run -d \
    --name polarion \
    --platform linux/amd64 \
    --memory 4g \
    -p 80:80 \
    -p 5433:5433 \
    -p 5005:5005 \
    -e JAVA_OPTS="-Xmx3g -Xms3g" \
    -e JDWP_ENABLED=true \
    --volume polarion_repo:/opt/polarion/data/svn \
    --volume polarion_extensions:/opt/polarion/polarion/extensions \
    --volume polarion_workspace:/opt/polarion/data/workspace \
    ghcr.io/phillipboesger/polarion-docker:latest
    ```
    _(Replace `polarion:latest` with the appropriate image name depending on how you built or pulled it)_

For Apple `container`, authenticate and run the same OCI image with explicit local port publishing:

```bash
container registry login ghcr.io
container run -d \
    --name polarion \
    --platform linux/amd64 \
    --rosetta \
    --cpus 8 \
    --memory 4g \
    -p 127.0.0.1:8080:80 \
    -p 127.0.0.1:5433:5433 \
    -p 127.0.0.1:5005:5005 \
    -e JAVA_OPTS="-Xmx3g -Xms3g" \
    -e JDWP_ENABLED=true \
    -v polarion_repo:/opt/polarion/data/svn \
    -v polarion_extensions:/opt/polarion/polarion/extensions \
    -v polarion_workspace:/opt/polarion/data/workspace \
    ghcr.io/phillipboesger/polarion-docker:latest
```

### Via Docker Compose

A `docker-compose.yml` is included for convenience.

Note: Docker Compose files in this repository are Docker-only. Apple `container` support is provided through direct CLI commands and the VS Code tasks documented in [docs/apple-container.md](./docs/apple-container.md).

1.  Clone this repository.
2.  Verify the `image` name in `docker-compose.yml` matches your local build (e.g., change to `polarion`) or the remote registry if you have access.
3.  Start the container:
    ```bash
    docker-compose up -d
    ```

The checked-in Compose files cap the Polarion container at `4g` RAM, default the JVM to `-Xmx3g -Xms3g`, and persist the Polarion workspace to avoid unnecessary full reindexing after container recreation.

## ⚙️ Configuration & Customization

### Modular Customization

The entrypoint system allows you to inject custom startup logic without modifying the base image. The container looks for scripts in `/opt/polarion/entrypoint.d/` and executes them in alphanumeric order.

To add your own configuration:

1.  Create a shell script (e.g., `90-custom-setup.sh`).
2.  Mount it into the container:
    ```yaml
    volumes:
      - ./my-script.sh:/opt/polarion/entrypoint.d/90-custom-setup.sh
    ```

### Environment Variables

| Variable        | Description                                  | Default                       |
| :-------------- | :------------------------------------------- | :---------------------------- |
| `JAVA_OPTS`     | Java memory and VM arguments                 | `-Xmx3g -Xms3g`               |
| `JDWP_ENABLED`  | Enable Java Debug Wire Protocol              | `true`                        |
| `ALLOWED_HOSTS` | Comma-separated list of allowed host headers | `localhost,127.0.0.1,0.0.0.0` |

### External SVN Endpoints

After startup, Apache serves the bundled Subversion repository through both of these authenticated endpoints:

- `http://<host>/repo`
- `http://<host>/repo-local`

On first start with a new or empty SVN volume, the startup scripts seed the bundled repository data. On later restarts and redeployments with an initialized SVN volume, they leave the repository content in place and normalize the password files both before and after Polarion service startup so the built-in service user remains `polarion` / `aurora` and the bootstrap admin remains `admin` / `admin`, while preserving other existing entries. Polarion's internal `/repo` and `/installrepo` access keep reading the runtime file at `/srv/polarion/svn/passwd`, while the external helper path `/repo-local` reads a dedicated Apache copy at `/etc/apache2/polarion-svn-http.passwd`. The scripts also re-apply `polarion:www-data` ownership plus group-write permissions across the mounted SVN data so Apache WebDAV commits can create transaction files under `repo/db`.

If an existing runtime has drifted and Apache basic auth no longer accepts `admin/admin` or `polarion/aurora`, run:

```bash
bash scripts/polarionctl.sh repair-auth
```

The `start` action runs the same normalization automatically after HTTP becomes reachable.

## 🛠️ Development & Debugging

### Remote Debugging (JDWP)

The container exposes port **5005** for Java remote debugging.

1.  Ensure `JDWP_ENABLED` is `true`.
2.  Connect your IDE (Eclipse, IntelliJ, VS Code) to `localhost:5005`.

Included `.vscode/launch.json` configuration:

```json
{
  "name": "Debug Polarion Container",
  "type": "java",
  "request": "attach",
  "hostName": "127.0.0.1",
  "port": 5005
}
```

### Plugin Development

For developing custom plugins with live reloading, refer to [PLUGIN-DEVELOPMENT.md](./PLUGIN-DEVELOPMENT.md).

### Apple `container` Workflow

If you are developing on Apple silicon with macOS 26 or later, see [docs/apple-container.md](./docs/apple-container.md) for the Apple `container` quickstart and the included VS Code tasks for:

- system start
- builder start
- image build
- Polarion start and stop
- live logs and error logs
- one-click redeploy into a running Apple `container` instance

## 🖥️ Platform Support

- **macOS (Apple Silicon)**: Supported via Docker `--platform linux/amd64` and via Apple `container` on macOS 26+ using `--platform linux/amd64 --rosetta`.
- **macOS (Intel)**: Supported natively.
- **Windows (WSL2)**: Recommended for best performance.
- **Linux**: Native support.

## 🔍 Troubleshooting

- **Port Conflicts:** Ensure ports 80, 5005, and 5433 are free.
- **Memory:** Docker, Compose, and Apple `container` use the same `4g` container RAM and `-Xmx3g -Xms3g` defaults unless you override them explicitly.
- **Apple `container` builder:** `bash scripts/polarionctl.sh build-image` starts the builder on demand with a `4g` cap and stops it again after the image build finishes.
- **Workspace persistence:** `bash scripts/polarionctl.sh start` now mounts a persistent workspace volume so successful starts do not trigger a fresh full reindex on every restart.
- **Apple `container` first start:** A cold `linux/amd64` start on Apple silicon can spend multiple minutes in image unpacking before the container becomes visible or HTTP responds.
- **Access Denied:** If pulling `ghcr.io/...` fails, ensure you have requested and been granted access by the owner, or build locally (Option A).

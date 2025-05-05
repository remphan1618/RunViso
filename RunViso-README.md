# VisoMaster Runtime Setup for Vast.ai (RunViso)

This repository provides the configuration for deploying VisoMaster on Vast.ai using a **runtime setup** approach. Instead of building a large Docker image with all dependencies, this uses a minimal base image containing essential services (Jupyter Lab, KasmVNC, Caddy) and relies on an interactive Jupyter Notebook (`RunViso-SetupGuide.ipynb`) to guide the user through installing VisoMaster and its dependencies *after* the instance starts.

**Architecture:**

1.  **Minimal Docker Image:** Built using `RunViso-Dockerfile`. Contains Ubuntu, Miniconda, KasmVNC, Caddy, Supervisor, and Git. It copies the `RunViso-SetupGuide.ipynb` directly into the image's `/workspace`. It's small and fast to build/pull.
2.  **Supervisor:** Manages background services (`RunViso-Supervisord.conf`):
    *   `kasmvnc`: Provides the remote desktop GUI environment.
    *   `jupyterlab`: Runs the Jupyter Lab server, accessible via Caddy.
    *   `caddy`: Acts as the reverse proxy and secure entry point (using `RunViso-Caddyfile`), integrating with Vast.ai's "Open Button" and providing access to Jupyter, VNC, and logs.
3.  **Setup Notebook (`RunViso-SetupGuide.ipynb`):** This is the primary tool for the user, copied into `/workspace` during the build. Accessed via Jupyter Lab, it interactively guides through:
    *   Creating the `viso_env` Conda environment (Python 3.10).
    *   Installing specific Conda CUDA/cuDNN versions.
    *   Installing Python dependencies via `pip` from a user-uploaded `requirements.txt`.
    *   Checking for user-uploaded VisoMaster code and assets (`dependencies/` folder).
    *   Running the `download_models.py` script.
    *   Providing instructions to launch VisoMaster within the KasmVNC session.
    *   Offering troubleshooting tools (log viewer, service status, GPU check).
4.  **Persistent Storage:** `/workspace` is used for all user data, including the setup notebook, uploaded code/assets, downloaded models, and any VisoMaster output.

**Setup Steps:**

1.  **Prepare Your Repository:**
    *   Place `RunViso-Dockerfile`, `RunViso-Supervisord.conf`, `RunViso-Caddyfile`, and `RunViso-SetupGuide.ipynb` in the root of your Git repository.
    *   Ensure `RunViso-SetupGuide.ipynb` is the correct, updated notebook file.

2.  **Build and Push the Docker Image:**
    *   Ensure you have Docker installed.
    *   Log in to Docker Hub: `docker login`
    *   Navigate to your repository root in your terminal.
    *   Build the image (replace `your_dockerhub_username/visomaster-runtime:latest` with your desired tag):
        ```bash
        docker build -t your_dockerhub_username/visomaster-runtime:latest -f RunViso-Dockerfile .
        ```
    *   Push the image:
        ```bash
        docker push your_dockerhub_username/visomaster-runtime:latest
        ```
    *   *(Optional: Use a GitHub Actions workflow to automate this on code changes.)*

3.  **Launch on Vast.ai:**
    *   Go to the Vast.ai Create Instance page.
    *   **Select Template:** Choose a base template or configure manually.
    *   **Edit Image & Config:** Click "Edit Image & Config".
        *   **Docker Image Name:** Enter the tag you pushed (e.g., `your_dockerhub_username/visomaster-runtime:latest`).
        *   **Launch Mode:** Select "Run interactive shell server, show Jupyter/SSH/VNC link".
        *   **Use Jupyter/proxy style startup script:** Ensure this is **checked**.
        *   **Environment Variables:**
            *   Add `PORTAL_CONFIG`: Define the services Caddy should expose. Example:
              ```json
              {"version":2,"port":11111,"services":[{"name":"VNC","uri":"/vnc/","proto":"http","rewrite":true,"auth":true},{"name":"Jupyter","uri":"/jupyter/","proto":"http","rewrite":true,"auth":true},{"name":"Logs","uri":"/logs/","auth":true}]}
              ```
              *(Adjust names/URIs if needed, ensure ports match internal services)*
        *   **On-start script:** Leave blank.
        *   **Docker run command arguments:** Leave blank.
    *   **Select Instance:** Choose an instance with sufficient GPU, RAM, and disk space. Ensure `/workspace` has enough space.
    *   **Rent Instance.**

4.  **Run the Setup Notebook:**
    *   Once the instance is 'Running', click the **'Open'** button. This takes you to the Caddy portal.
    *   Click the **'Jupyter'** link in the portal.
    *   In the Jupyter Lab interface, open the `RunViso-SetupGuide.ipynb` file located in the main `/workspace` directory.
    *   Follow the instructions within the notebook, running cells sequentially to install VisoMaster and its dependencies.
    *   Upload your `requirements.txt`, VisoMaster source code (into `/workspace/VisoMaster`), and asset files (into `/workspace/dependencies`) when prompted by the notebook.

5.  **Launch VisoMaster:**
    *   Follow the final instructions in the notebook (Section 4) to access KasmVNC via the Caddy portal and run the VisoMaster launch command within the KasmVNC terminal.

**Logging:**

*   All service logs (Supervisor, Caddy, Jupyter, KasmVNC) are stored in `/var/log/supervisor/`.
*   Access logs via:
    *   The 'Logs' link in the Caddy Portal (provides file browsing).
    *   The Troubleshooting section in the `RunViso-SetupGuide.ipynb`.
    *   Browsing `/var/log/supervisor/` in the Jupyter Lab file browser.

**Key Files:**

*   `RunViso-Dockerfile`: Defines the minimal base image, copies notebook.
*   `RunViso-Supervisord.conf`: Manages background services.
*   `RunViso-Caddyfile`: Configures the Caddy reverse proxy and portal.
*   `RunViso-SetupGuide.ipynb`: The interactive setup guide (must be in repo root).
*   `RunViso-README.md`: This file.
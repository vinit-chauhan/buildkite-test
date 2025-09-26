# Run local Buildkite Agent

## Steps
1. Run config_ssh.sh to setup SSH keys
2. Add SSH key to GitHub account
3. `docker compose build`
4. `docker compose up -d`
5. Verify agent is running: `docker compose logs -f buildkite-agent`
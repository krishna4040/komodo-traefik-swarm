# Docker Swarm Platform

Self-hosted container platform on VPS nodes, built from four layers. Set them up in this order:

| # | Layer | Directory | Purpose |
|---|---|---|---|
| 1 | [Docker](#1-docker) | `swarm/install-docker.sh` | Container runtime on every node |
| 2 | [Traefik](#2-traefik) | `traefik/` | Reverse proxy with automatic Let's Encrypt TLS |
| 3 | [Komodo](#3-komodo) | `komodo/` | Web UI to manage servers, stacks and deployments |
| 4 | [Docker Swarm](#4-docker-swarm) | `swarm/` | Multi-node orchestration (firewall + cluster init) |

Docker Swarm is a container orchestration tool, similar to Kubernetes. It is built into Docker Engine and is relatively simple to set up and operate. It provides cluster management, service scheduling, scaling, service discovery and overlay networking.

```
.
├── swarm/
│   ├── install-docker.sh         # Docker installer (Ubuntu/Debian)
│   └── setup-firewall-rule.sh    # Swarm iptables rules
├── traefik/
│   ├── compose.yaml
│   └── .env.example
└── komodo/
    ├── compose.yaml
    └── .env.example
```

## Prerequisites

- One or more Ubuntu/Debian VPS nodes with root/sudo access. The first node is the **manager**; Traefik and Komodo run on it.
- DNS `A` records pointing to the manager's public IP, for example:
  - `traefik.example.com` (dashboard)
  - `komodo.example.com`
- Ports **80** and **443** reachable on the manager (cloud firewall and host firewall). Port 80 is needed for the Let's Encrypt HTTP challenge.

---

## 1. Docker

Run on **every node**:

```bash
sudo bash swarm/install-docker.sh
```

The script removes conflicting packages, installs Docker CE with the Compose and Buildx plugins, enables the service, adds your sudo user to the `docker` group and runs `hello-world`. Log out and back in for the group change to take effect.

Verify:

```bash
docker --version
docker compose version
```

---

## 2. Traefik

Traefik terminates TLS and routes traffic to containers on the shared `proxy` network. Traefik creates that network, so **start it before Komodo**.

```bash
cd traefik
cp .env.example .env
```

Edit `.env`:

| Variable | Description |
|---|---|
| `ACME_EMAIL` | Email for Let's Encrypt registration |
| `TRAEFIK_HOST` | Dashboard hostname (e.g. `traefik.example.com`) |
| `TRAEFIK_AUTH_USER` | Dashboard basic-auth username |
| `TRAEFIK_AUTH_PASSWORD_HASH` | Password **hash only**, with every `$` doubled to `$$` |
| `TRAEFIK_DASHBOARD_ENABLED` | `true` to enable the dashboard, `false` to disable |

The compose file builds the credential as `${TRAEFIK_AUTH_USER}:${TRAEFIK_AUTH_PASSWORD_HASH}`, so do **not** include the `admin:` prefix that appears in the `.env.example` placeholder. Generate the hash:

```bash
openssl passwd -apr1 'your-password' | sed 's/\$/$$/g'
```

Start:

```bash
docker compose up -d
docker compose logs -f traefik
```

Verify: `https://<TRAEFIK_HOST>` prompts for basic auth and shows the dashboard. Certificates are stored in the `letsencrypt` volume.

---

## 3. Komodo

Komodo has three parts: **Core** (API and UI, exposed through Traefik), **Periphery** (agent that talks to the Docker socket) and a FerretDB/Postgres database on an internal-only network.

```bash
cd komodo
cp .env.example .env
```

Edit `.env`:

| Variable | Description |
|---|---|
| `KOMODO_DOMAIN` | Hostname used in the Traefik router rule (e.g. `komodo.example.com`) |
| `KOMODO_HOST` | Public URL, including scheme (e.g. `https://komodo.example.com`) |
| `KOMODO_DATABASE_USERNAME` / `KOMODO_DATABASE_PASSWORD` | Database credentials. Change the default password to a long random alphanumeric string |
| `KOMODO_INIT_ADMIN_USERNAME` / `KOMODO_INIT_ADMIN_PASSWORD` | First admin account |
| `KOMODO_JWT_SECRET` | Random secret, e.g. `openssl rand -hex 32` |
| `KOMODO_WEBHOOK_SECRET` | Random secret, e.g. `openssl rand -hex 32` |
| `KOMODO_BACKUPS_PATH` | Host directory for backups (default `/opt/komodo/backups`) |
| `PERIPHERY_ROOT_DIRECTORY` | Host directory for Periphery data (default `/etc/komodo`) |
| `TZ` | Timezone |

Avoid special characters in the database password, because it is embedded in a connection URL.

Create the host directories, then start:

```bash
sudo mkdir -p /opt/komodo/backups /etc/komodo
docker compose up -d
docker compose logs -f core
```

Verify: open `https://<KOMODO_DOMAIN>` and log in with the init admin credentials. The `Local` server should show as connected.

Notes:
- Core and Periphery exchange public keys through the shared `komodo-keys` volume, so no manual key setup is needed on the local node.
- `KOMODO_DISABLE_USER_REGISTRATION=true` blocks self sign-up. Leave it on.
- Periphery mounts `/var/run/docker.sock`, which is effectively root on the host. Keep Komodo behind strong credentials.

---

## 4. Docker Swarm

Only needed for a multi-node cluster. Docker must already be installed on every node (step 1). IPs below are examples; replace them with your own.

### 4.1 Manager node firewall rules

Allow ingress traffic from **all worker public IPs** on the following ports:

| Protocol | Port | Purpose |
|---|---:|---|
| TCP | 2377 | Swarm management and worker joining |
| TCP | 7946 | Node communication |
| UDP | 7946 | Node discovery |
| UDP | 4789 | Overlay network traffic |

Configure these rules in:
- Cloud firewall (OCI Security List / NSG)
- Manager VPS host firewall (iptables)

### 4.2 Worker node firewall rules

Allow ingress traffic from:
- Manager public IP
- All other worker public IPs (excluding the current worker)

Required ports:

| Protocol | Port | Purpose |
|---|---:|---|
| TCP | 7946 | Node communication |
| UDP | 7946 | Node discovery |
| UDP | 4789 | Overlay network traffic |

**Note:** TCP 2377 does not need to be opened for inbound connections on worker nodes. Workers initiate outbound TCP connections to the manager on port 2377.

Configure these rules in:
- Cloud firewall (OCI Security List / NSG)
- Worker VPS host firewall (iptables)

### 4.3 Firewall configuration script

Use the same script on all nodes, changing the role and IP arguments as appropriate.

**Important:** On workers, `--worker-ip` must list the *other* workers, excluding the current worker.

#### On Manager

```bash
sudo bash swarm/setup-firewall-rule.sh \
  --role manager \
  --manager-ip 130.210.50.139 \
  --worker-ip 130.210.9.232 \
  --worker-ip 130.210.9.233
```

#### On Worker 1 (130.210.9.232)

```bash
sudo bash swarm/setup-firewall-rule.sh \
  --role worker \
  --manager-ip 130.210.50.139 \
  --worker-ip 130.210.9.233
```

#### On Worker 2 (130.210.9.233)

```bash
sudo bash swarm/setup-firewall-rule.sh \
  --role worker \
  --manager-ip 130.210.50.139 \
  --worker-ip 130.210.9.232
```

View rules:

```bash
sudo iptables -L -n -v
```

### 4.4 Initialize the swarm

On the manager:

```bash
sudo docker swarm init --advertise-addr 130.210.50.139
```

Get the worker join command:

```bash
sudo docker swarm join-token worker
```

On each worker, run the generated join command.

### 4.5 Verify the cluster

On the manager:

```bash
sudo docker node ls
```

### 4.6 Persist firewall rules

After testing connectivity, persist the iptables rules on **every node**:

```bash
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

### 4.7 Add the swarm nodes to Komodo (optional)

Once the swarm is up, install a Periphery agent on each worker and add it as a server in the Komodo UI (**Servers → New Server**), so you can manage the whole cluster from one place.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Komodo fails with `network proxy declared as external, but could not be found` | Traefik has not been started yet. Run `docker compose up -d` in `traefik/` first |
| Certificate not issued | DNS `A` record points to this node, ports 80/443 are open, and `docker compose logs traefik` shows ACME errors |
| Dashboard returns 401 for the correct password | `TRAEFIK_AUTH_PASSWORD_HASH` still has the `admin:` prefix, or its `$` characters are not doubled to `$$` |
| Worker cannot join the swarm | Manager allows TCP 2377 from the worker IP, and the join command used the manager's reachable address |
| Swarm services cannot reach each other across nodes | UDP 4789 and TCP/UDP 7946 are open between all nodes |

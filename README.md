# Docker Swarm Platform

Self-hosted container platform on VPS nodes, built from four layers. Set them up in this order (Traefik needs the swarm overlay network, so Swarm comes before it):

| # | Layer | Directory | Purpose |
|---|---|---|---|
| 1 | [Docker](#1-docker) | `swarm/install-docker.sh` | Container runtime on every node |
| 2 | [Docker Swarm](#2-docker-swarm) | `swarm/` | Cluster init, firewall, and the shared `proxy` overlay network |
| 3 | [Traefik](#3-traefik) | `traefik/` | Swarm-aware reverse proxy with automatic Let's Encrypt TLS |
| 4 | [Komodo](#4-komodo) | `komodo/` | Web UI to manage servers, stacks and deployments |

Docker Swarm is a container orchestration tool, similar to Kubernetes. It is built into Docker Engine and is relatively simple to set up and operate. It provides cluster management, service scheduling, scaling, service discovery and overlay networking.

```
.
├── swarm/
│   ├── install-docker.sh         # Docker installer (Ubuntu/Debian)
│   └── setup-firewall-rule.sh    # Swarm iptables rules
├── traefik/
│   ├── stack.yaml                # deployed with `docker stack deploy`
│   └── .env.example
└── komodo/
    ├── stack.yaml                # deployed with `docker stack deploy`
    └── .env.example
```

## Prerequisites

- One or more Ubuntu/Debian VPS nodes with root/sudo access. The first node is the **manager**; Traefik and Komodo run on it. A single-node swarm works too: skip the worker steps.
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

## 2. Docker Swarm

Docker must already be installed on every node (step 1). IPs below are examples; replace them with your own. For a single-node setup, only do 2.4 and 2.8.

### 2.1 Manager node firewall rules

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

### 2.2 Worker node firewall rules

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

### 2.3 Firewall configuration script

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

### 2.4 Initialize the swarm

On the manager:

```bash
sudo docker swarm init --advertise-addr 130.210.50.139
```

Get the worker join command:

```bash
sudo docker swarm join-token worker
```

On each worker, run the generated join command.

### 2.5 Verify the cluster

On the manager:

```bash
sudo docker node ls
```

### 2.6 Persist firewall rules

After testing connectivity, persist the iptables rules on **every node**:

```bash
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

### 2.7 Create the shared proxy network

On the manager, create the attachable overlay network used by Traefik, Komodo and your apps. `--opt encrypted` encrypts VXLAN traffic between nodes, which matters when nodes talk over public IPs.

```bash
docker network create --driver overlay --attachable --opt encrypted proxy
```

`--attachable` also lets standalone `docker run` / `docker compose` containers join it when needed.

### 2.8 Add the swarm nodes to Komodo (optional)

Once Komodo is running (step 4), install a Periphery agent on each worker and add it as a server in the Komodo UI (**Servers → New Server**), so you can manage the whole cluster from one place.

---

## 3. Traefik

Traefik runs as a **swarm stack** pinned to the manager. It terminates TLS and routes to any service on the `proxy` overlay network, on any node, using the Swarm provider.

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
| `TRAEFIK_AUTH_PASSWORD_HASH` | Password **hash only**, single-quoted, with single `$` |
| `TRAEFIK_DASHBOARD_ENABLED` | `true` to enable the dashboard, `false` to disable |

The stack builds the credential as `${TRAEFIK_AUTH_USER}:${TRAEFIK_AUTH_PASSWORD_HASH}`, so do **not** include a `user:` prefix. Generate the hash:

```bash
openssl passwd -apr1 'your-password'
```

`docker stack deploy` does not read `.env` itself, so export the variables first:

```bash
set -a; source .env; set +a
docker stack deploy -c stack.yaml traefik
```

Verify:

```bash
docker service ls
docker service logs -f traefik_traefik
```

`https://<TRAEFIK_HOST>` should prompt for basic auth and show the dashboard.

### Exposing a swarm service through Traefik

Attach the service to the external `proxy` network and put the labels under `deploy.labels`. The `loadbalancer.server.port` label is mandatory in swarm mode.

```yaml
services:
  app:
    image: traefik/whoami
    networks: [proxy]
    deploy:
      replicas: 3
      labels:
        - traefik.enable=true
        - traefik.http.routers.app.rule=Host(`app.example.com`)
        - traefik.http.routers.app.entrypoints=websecure
        - traefik.http.routers.app.tls.certresolver=letsencrypt
        - traefik.http.services.app.loadbalancer.server.port=80

networks:
  proxy:
    external: true
```

Replicas can run on any node; Traefik reaches them over the overlay.

---

## 4. Komodo

Komodo is deployed as a **swarm stack** on the manager. Core (API and UI) is exposed through Traefik on the `proxy` overlay; Periphery (agent with Docker socket access) and the FerretDB/Postgres database sit on a private internal overlay (`komodo-internal`).

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
| `KOMODO_BACKUPS_PATH` | Manager host directory for backups (default `/opt/komodo/backups`) |
| `PERIPHERY_ROOT_DIRECTORY` | Manager host directory for Periphery data (default `/etc/komodo`) |
| `TZ` | Timezone |

Avoid special characters in the database password, because it is embedded in a connection URL.

Create the host directories **on the manager**, load the variables, and deploy:

```bash
sudo mkdir -p /opt/komodo/backups /etc/komodo
set -a; source .env; set +a
docker stack deploy -c stack.yaml komodo
```

Verify:

```bash
docker stack services komodo
docker service logs -f komodo_komodo-core
```

Open `https://<KOMODO_DOMAIN>` and log in with the init admin credentials. The `Local` server should show as connected. Postgres, FerretDB and Core start in no fixed order, so Core may restart once or twice until the database is ready.

Notes:
- Every Komodo service is pinned to the manager: the `komodo-keys` volume (Core and Periphery public keys), the database volumes and the bind mounts are all node-local.
- Core is named `komodo-core` rather than `core` so its DNS name cannot collide with another stack's `core` service on the shared `proxy` network.
- `KOMODO_DISABLE_USER_REGISTRATION=true` blocks self sign-up. Leave it on.
- Periphery mounts `/var/run/docker.sock`, which is effectively root on the host. Keep Komodo behind strong credentials.
- This Periphery only manages the manager. Workers get their own Periphery agent, added as a server in Komodo (see step 2.8).

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Stack deploy fails with `network "proxy" is declared as external, but could not be found` | The overlay network is missing. Run the command in step 2.7 on the manager |
| Komodo Core keeps restarting | Check `docker service logs komodo_komodo-core`; usually the database is still starting or `KOMODO_DATABASE_PASSWORD` differs from the one Postgres first initialised with (the volume keeps the old one) |
| Komodo stack task is `rejected` with a bind mount error | `KOMODO_BACKUPS_PATH` and `PERIPHERY_ROOT_DIRECTORY` must exist on the manager before deploying |
| `docker network create` says `proxy` already exists | An old bridge `proxy` exists from an earlier compose setup. Stop the old Traefik and Komodo containers (`docker compose down`), run `docker network rm proxy`, then recreate it as an overlay |
| Service not routed by Traefik | It is on the `proxy` network, has `traefik.enable=true`, labels are under `deploy.labels`, and `loadbalancer.server.port` is set |
| Certificate not issued | DNS `A` record points to the manager, ports 80/443 are open, and `docker service logs traefik_traefik` shows ACME errors |
| Dashboard returns 401 for the correct password | `TRAEFIK_AUTH_PASSWORD_HASH` has a `user:` prefix, is not single-quoted, or `$` characters were doubled to `$$` |
| Worker cannot join the swarm | Manager allows TCP 2377 from the worker IP, and the join command used the manager's reachable address |
| Services cannot reach each other across nodes | UDP 4789 and TCP/UDP 7946 are open between all nodes |

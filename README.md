# Docker, Prometheus and Grafana on an Azure VM

Provision an Ubuntu virtual machine (VM) on Azure with Terraform, then run a
containerized Python web app alongside Prometheus and Grafana with Docker
Compose — and deliberately break it to practice diagnosing production-style
failures from logs and dashboards.

> **The point of this repo is the `incidents/` folder.** A working demo proves
> you can follow instructions. A written incident report proves you can find a
> root cause.

|                                  |                                                                       |
| -------------------------------- | --------------------------------------------------------------------- |
| **Cloud**                        | Microsoft Azure (East US 2)                                           |
| **Infrastructure as Code (IaC)** | Terraform (`azurerm` ~> 4.0)                                          |
| **Compute**                      | Ubuntu 24.04 LTS, `Standard_D2as_v7` (2 vCPU, 8 GB RAM)               |
| **Containers**                   | Docker, Docker Compose                                                |
| **App**                          | Python 3.12 + Flask, custom Dockerfile                                |
| **Monitoring**                   | Prometheus 2.53 (metrics), Grafana 11.1 (dashboards)                  |
| **Cost**                         | About $0.10/hour while running. `az vm deallocate` stops the billing. |
| **Author**                       | Fabrizio Mastrogiovanni                                               |

---

## Table of Contents

1. [The Problem](#1-the-problem)
2. [Architecture](#2-architecture)
3. [Repository Structure](#3-repository-structure)
4. [Part A — Provision with Terraform](#4-part-a--provision-with-terraform)
5. [Part B — The App and the Dockerfile](#5-part-b--the-app-and-the-dockerfile)
6. [Part C — The Monitoring Stack](#6-part-c--the-monitoring-stack)
7. [Part D — Breaking It on Purpose](#7-part-d--breaking-it-on-purpose)
8. [Troubleshooting — Every Error I Hit](#8-troubleshooting--every-error-i-hit)
9. [Teardown](#9-teardown)
10. [What I Learned](#10-what-i-learned)
11. [What I Would Do Differently](#11-what-i-would-do-differently)

---

## 1. The Problem

[#1-the-problem](#1-the-problem)

Most container tutorials end at "it works." That teaches you the happy path and
nothing else. In real operations the app is already running — the job is
figuring out *why it stopped*, using logs, metrics, and a terminal.

This project builds the full stack from nothing, then removes the happy path on
purpose:

| Failure introduced                       | What it forces you to understand                                 |
| ---------------------------------------- | ---------------------------------------------------------------- |
| App bound to the container's loopback    | "Container is Up" is not "app is reachable"                      |
| Disk filled to 100%                      | A full disk produces a dozen unrelated-looking errors            |
| Monitoring target pointed at a bad name  | A flat dashboard can mean broken measurement, not a broken app   |
| Memory cap below what the app needs      | A restart loop is often a kill from outside, not a crash         |

Each one is written up in `incidents/` in the format an on-call engineer would
actually use: symptom, what was checked in order, root cause, fix, prevention.

---

## 2. Architecture

[#2-architecture](#2-architecture)

### 2.1 What Terraform provisions

```
flowchart TB
    DEV["My Mac<br/>terraform apply"]
    subgraph RG["rg-docker-lab-fabrizio (East US 2)"]
        subgraph VNET["vnet-docker-lab 10.20.0.0/16"]
            subgraph SNET["snet-app 10.20.1.0/24"]
                VM["vm-docker-lab<br/>Ubuntu 24.04 · D2as_v7<br/>Managed identity"]
            end
        end
        NSG["nsg-docker-lab<br/>Allow 22, 8080, 9090, 3000<br/>from my IP only"]
        PIP["pip-docker-lab<br/>Static public IP"]
        NIC["nic-docker-lab"]
    end
    DEV -->|"SSH :22"| PIP
    PIP --> NIC
    NIC --> VM
    NSG -.->|"attached to"| NIC
```

The network security group (NSG) is a list of allow and deny rules. Every port
is closed to the internet; only my own address gets in, and only on four ports.

### 2.2 Inside the VM — three containers, one private network

```
flowchart LR
    USER(["Browser"])
    subgraph VM["vm-docker-lab"]
        subgraph NET["Docker network: app_default"]
            APP["app<br/>Flask :8080<br/>/ and /metrics"]
            PROM["prometheus :9090<br/>scrapes app:8080<br/>every 10s"]
            GRAF["grafana :3000<br/>queries prometheus:9090"]
        end
    end
    USER -->|":8080"| APP
    USER -->|":3000"| GRAF
    PROM -->|"scrape"| APP
    GRAF -->|"query"| PROM
```

**The key detail:** containers reach each other by **service name**, not by IP
address and not by `localhost`. Prometheus scrapes `app:8080`; Grafana queries
`http://prometheus:9090`. Docker runs an internal DNS server that resolves
those names. Using `localhost` inside a container means *that container only* —
which is exactly the mistake Incident 01 reproduces.

---

## 3. Repository Structure

[#3-repository-structure](#3-repository-structure)

```
.
├── terraform/
│   ├── providers.tf          → azurerm ~> 4.0
│   ├── variables.tf          → name, region, VM size, my IP, SSH key path
│   ├── main.tf               → resource group, VNet, subnet, NSG, IP, NIC, VM
│   ├── outputs.tf            → public IP and ready-to-paste SSH command
│   ├── cloud-init.yaml       → installs Docker on first boot
│   └── .terraform.lock.hcl   → committed on purpose; pins provider versions
│
├── app/
│   ├── app.py                → Flask app exposing / and /metrics
│   ├── requirements.txt      → pinned versions
│   ├── Dockerfile            → pinned base image, layer caching, non-root user
│   ├── docker-compose.yaml   → app + Prometheus + Grafana
│   └── prometheus.yml        → scrape config
│
├── incidents/
│   └── 01-bind-address.md    → the write-ups; more below
│
└── .gitignore                → excludes state, tfvars, SSH keys
```

---

## 4. Part A — Provision with Terraform

[#4-part-a--provision-with-terraform](#4-part-a--provision-with-terraform)

```bash
cd terraform
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

cat > terraform.tfvars <<EOF
my_ip   = "$(curl -4 -s ifconfig.me)/32"
vm_size = "Standard_D2as_v7"
EOF

terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

**Expected:** 8 resources added in about 2 minutes.

```bash
terraform output public_ip
ssh azureuser@<public-ip>
docker --version        # cloud-init needs ~1 min after first boot
```

![Terraform apply and first SSH login]

Three design decisions worth defending:

- **`curl -4`** forces an IPv4 address. Without it the command can return an
  IPv6 address, and `/32` is IPv4-only notation — Azure rejects it. (See
  Troubleshooting #2.)
- **`file(pathexpand(var.ssh_public_key_path))`** — Terraform doesn't expand
  `~`. That's a shell shortcut, not a path.
- **`identity { type = "SystemAssigned" }`** gives the VM its own Azure login
  with no password to store, ready for a container registry to trust later.

---

## 5. Part B — The App and the Dockerfile

[#5-part-b--the-app-and-the-dockerfile](#5-part-b--the-app-and-the-dockerfile)

The app is deliberately tiny: one route that returns text and increments a
counter, and one `/metrics` route that publishes that counter in the format
Prometheus reads.

The Dockerfile is where the real decisions live:

```dockerfile
FROM python:3.12-slim          # pinned — "latest" drifts silently

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1         # logs appear immediately in "docker logs"

WORKDIR /app

COPY requirements.txt .        # dependencies BEFORE code…
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .                  # …so editing code doesn't reinstall packages

RUN useradd --create-home appuser
USER appuser                   # root inside a container is a real risk

EXPOSE 8080
CMD ["python", "app.py"]
```

| Line                          | Why it's there                                                                       |
| ----------------------------- | ------------------------------------------------------------------------------------ |
| Pinned base image             | An unpinned tag means the build changes months later with no code change             |
| `PYTHONUNBUFFERED=1`          | Without it, Python buffers output and `docker logs` looks empty during an incident   |
| Requirements copied first     | Docker caches each step; code edits then rebuild in about a second instead of a minute |
| Non-root `USER`               | Limits what a compromised process can do                                             |

Result: a 185 MB image that builds in 12 seconds cold, about 1 second warm.

---

## 6. Part C — The Monitoring Stack

[#6-part-c--the-monitoring-stack](#6-part-c--the-monitoring-stack)

```bash
cd ~/app
docker compose up -d --build
docker compose ps
```

Three containers, one command. Then, from a browser (only my IP is allowed):

| Service    | URL                    | Check                                    |
| ---------- | ---------------------- | ---------------------------------------- |
| App        | `http://<ip>:8080`     | returns `hello from the lab`             |
| Prometheus | `http://<ip>:9090`     | **Status → Targets** → `lab-app` is `UP` |
| Grafana    | `http://<ip>:3000`     | admin login, Prometheus data source      |

Generate traffic so the metrics move:

```bash
while true; do curl -s localhost:8080 > /dev/null; sleep 0.2; done
```

**Prometheus, querying the raw counter:**

![Prometheus showing app_requests_total](<img width="1903" height="1034" alt="4C7D51E0-FE3D-44E6-8B71-5BF124678457" src="https://github.com/user-attachments/assets/58a5b36c-d688-4d7a-ac10-46cc29a81e5b" />
)

The result is labeled `{instance="app:8080", job="lab-app"}` — proof the scrape
is reaching the app container by service name.

**Grafana, graphing requests per second** with `rate(app_requests_total[1m])`:

![Grafana dashboard](<img width="1911" height="993" alt="0103DF36-F639-4AC8-B137-5B04D38B84AD" src="https://github.com/user-attachments/assets/b13f8a26-de0e-4f1c-ad4d-4f1fa822f870" />
)

`rate()` converts an ever-increasing counter into a per-second rate. Graphing
the raw counter would just show a line climbing forever, which tells you
nothing about current load.

**All resources in the Azure portal:**

![Azure resources](<img width="3386" height="1824" alt="image" src="https://github.com/user-attachments/assets/07334644-1533-4826-a767-73ac2d0f9b2c" />
)

---

## 7. Part D — Breaking It on Purpose

[#7-part-d--breaking-it-on-purpose](#7-part-d--breaking-it-on-purpose)

Each failure is introduced deliberately, then diagnosed as if the cause were
unknown. Full write-ups are in [`incidents/`](incidents/).

### Incident 01 — App reachable inside the container, not outside

**Introduced by** setting `BIND_HOST=127.0.0.1` in `docker-compose.yaml`.

**Symptom:** `curl: (56) Recv failure: Connection reset by peer`, while
`docker compose ps` showed the container `Up 7 seconds` with port 8080
published.

**Diagnosis path:**

```bash
docker compose ps            # Up, not crashed → not an application crash
docker compose logs app      # → "Running on http://127.0.0.1:8080"
```

That log line *is* the root cause, one command in. Compare it to a healthy
start, which reads `Running on all addresses (0.0.0.0)`.

**Root cause:** `127.0.0.1` inside a container means that container's own
loopback interface. Publishing the port changes nothing, because nothing
outside the container can ever reach that address.

**An unexpected lesson.** Trying to confirm from inside failed twice:

```
OCI runtime exec failed: exec: "curl": executable file not found in $PATH
OCI runtime exec failed: exec: "ss": executable file not found in $PATH
```

The `python:3.12-slim` base image contains no diagnostic tools. **The
diagnostic tools you reach for often aren't in a slim image.** Three ways
around it, in order of preference:

```bash
# 1. Use what IS in the image
docker compose exec app python -c \
  "import urllib.request;print(urllib.request.urlopen('http://localhost:8080').read())"

# 2. Check from the host instead
sudo ss -tlnp | grep 8080

# 3. Attach a throwaway toolbox container sharing the app's network
docker run --rm -it --network container:app-app-1 nicolaka/netshoot ss -tlnp
```

Option 3 is the production answer: keep the image small, bring the tools in
temporarily rather than shipping them forever.

### Incidents 02–04

| # | Failure                  | The command that finds it                                         |
| - | ------------------------ | ----------------------------------------------------------------- |
| 02 | Disk filled to 100%      | `df -h`, then `du -sh` and `docker system df` to find the eater   |
| 03 | Scrape target unresolved | Prometheus **Targets** page + `getent hosts` inside the container |
| 04 | Killed for memory        | `docker inspect … --format '{{.State.OOMKilled}}'` → `true`       |

---

## 8. Troubleshooting — Every Error I Hit

[#8-troubleshooting--every-error-i-hit](#8-troubleshooting--every-error-i-hit)

Every row below actually happened during this build.

| # | Error                                                                | Cause                                                                                          | Fix                                                                            |
| - | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| 1 | `Invalid value for "path": no file exists at "~/.ssh/id_rsa.pub"`    | Terraform doesn't expand `~` — that's a shell feature, not a real path                        | `file(pathexpand(var.ssh_public_key_path))`                                    |
| 2 | `SecurityRuleInvalidAddressPrefix … 2603:900b:…/32`                  | `curl ifconfig.me` returned an IPv6 address; `/32` is IPv4 notation                            | `curl -4 -s ifconfig.me`                                                       |
| 3 | `SkuNotAvailable … Capacity Restrictions: Standard_B2s … eastus2`    | Azure had no B2s capacity in that region. **Platform problem, not a code problem.**            | `az vm list-skus` to find an available size; change one line in `tfvars`       |
| 4 | `OperationNotAllowed … exceeding approved Total Regional Cores quota` | Picked a VM needing 128 cores against a 32-core account limit. **Account limit, not capacity.** | Filter the size list by vCPU count; pick a 2-core size                        |
| 5 | Private key written into `terraform.tfvars`                          | `ssh-keygen -f terraform.tfvars` means "write the key to this exact file" — it overwrote it    | Delete both files, regenerate with `-f ~/.ssh/id_rsa`, add `id_rsa*` to ignore |
| 6 | `mapping key "environment" already defined at line 19`               | Added a second `environment:` block to a service that already had one                          | YAML forbids duplicate keys in one block — `cat -n` the file and remove it     |
| 7 | `cd: too many arguments`                                             | Path contains spaces (`Cloud Engineering Labs`) and wasn't quoted                              | Quote the path, or use Tab completion                                          |
| 8 | Terminal printing `y` endlessly                                      | Typed `yes` at a shell prompt instead of Terraform's confirmation prompt — `yes` is a command  | Ctrl + C. Terraform's prompt is the one reading `Enter a value:`               |

**Three of these look identical at a glance and have completely different
fixes.** #2 is a wrong value, #3 is a temporary platform condition, #4 is an
account limit. Telling them apart by reading the full error — not just the red
headline — is the actual skill.

---

## 9. Teardown

[#9-teardown](#9-teardown)

```bash
# Pause and stop the compute charge, keep everything else
az vm deallocate -g rg-docker-lab-fabrizio -n vm-docker-lab
az vm start      -g rg-docker-lab-fabrizio -n vm-docker-lab

# Or destroy it all — must run from the folder holding the state file
cd terraform
terraform destroy
az group list --query "[?contains(name,'docker-lab')].name" -o table   # empty
```

`terraform destroy` only knows what it created by reading the state file in the
current directory. Run it anywhere else and it finds nothing.

---

## 10. What I Learned

[#10-what-i-learned](#10-what-i-learned)

- **"Container is Up" answers one question out of three.** The process can be
  running, the bind address wrong, and the port unpublished — three
  independent layers, three different symptoms.
- **Read the whole error, not the headline.** Every Azure failure here named
  the exact value it rejected and, in the quota case, both the limit and the
  amount requested.
- **Not all failures are code failures.** Capacity restriction, quota limit,
  and invalid value look similar and need three different responses: retry,
  request more, or fix the input.
- **Slim images are slim on purpose.** No `curl`, no `ss`. Plan how you'll
  debug a container before you need to.
- **Service names, not `localhost`.** Inside a Docker network, `localhost`
  means the container itself. Cross-container traffic uses service names.
- **`rate()` exists because counters only go up.** Graphing a raw counter shows
  a line climbing forever and hides current load.
- **A shell command can quietly destroy a file.** `ssh-keygen -f terraform.tfvars`
  overwrote my variables file with a private key. `.gitignore` caught it by
  luck; `git status` before committing caught it properly.
- **Layer order in a Dockerfile is a performance decision.** Copying
  dependencies before code turned minute-long rebuilds into second-long ones.

---

## 11. What I Would Do Differently

[#11-what-i-would-do-differently](#11-what-i-would-do-differently)

**Production readiness**

- Replace Flask's development server with **Gunicorn**. Flask says so itself on
  every start, and shipping the dev server is a real mistake people make.
- Add a **healthcheck** to the Compose file so Docker knows whether the app is
  actually serving, not just running.
- Add **log rotation** (`max-size`, `max-file` in `/etc/docker/daemon.json`).
  Container logs grow forever by default — the direct cause of Incident 02.
- Put **Grafana's password in a secret**, not an environment variable in a file
  committed to Git.
- Serve the dashboards over **HTTPS** behind a reverse proxy instead of plain
  HTTP on an open port.

**Engineering practices**

- Use a **remote state backend** (Azure Storage with locking) instead of local
  state, so the project survives losing my laptop.
- Add a **CI pipeline** running `terraform fmt -check`, `validate`, `tflint`,
  and a security scanner on every push.
- **Provision the app with the VM** using cloud-init or Ansible instead of
  copying files by hand over SSH.
- Add **Prometheus alert rules** so a target going down pages someone, instead
  of waiting for a human to notice a flat graph.

---

**Author:** Fabrizio Mastrogiovanni ·
[GitHub](https://github.com/fabrizio-mastrogiovanni) ·
[LinkedIn](https://www.linkedin.com/in/fabrizio-mastrogiovanni-499335276/)


<img width="1215" height="424" alt="elastic_ascii_banner" src="https://github.com/user-attachments/assets/f0e7e014-73e6-4ca5-a9e1-af8539971f2b" />

# Elastic Stack On-Prem Installer

An interactive, single-file bash installer for self-hosted Elastic Stack deployments on Linux.

## What it installs

| Component | Default port |
|---|---|
| Elasticsearch | 9200 |
| Kibana | 5601 |
| Fleet Server (Elastic Agent) | 8220 |

## Supported platforms

- **RHEL family:** RHEL, CentOS, Rocky Linux, AlmaLinux
- **Debian family:** Ubuntu, Debian

## Requirements

- Root or `sudo` access
- `systemd`
- `curl`
- `python3` (used for JSON parsing during setup)
- Minimum 4 GB RAM recommended (installer will warn if below this)
- Minimum 20 GB free on `/var/lib` recommended

## Usage

```bash
sudo bash install.sh
```

The installer is fully interactive — no flags or config files required.

## What the installer does

1. Detects the OS and configures the appropriate Elastic package repository
2. Prompts for:
   - Elastic Stack version (latest v9, previous v9 minor, latest v8, or custom)
   - Deployment topology (single-node POC or multi-node cluster)
   - Components to install (single-node installs all three automatically)
   - Bind IP addresses for each service, or `0.0.0.0` for all interfaces
   - Optional custom passwords for the `elastic` and `kibana_system` users
3. Installs selected packages
4. Writes configuration files for Elasticsearch and Kibana
5. Starts services in dependency order: Elasticsearch → Kibana → Fleet Server
6. Auto-generates the `elastic` superuser password and optionally applies a custom one
7. Generates a Kibana enrollment token and enrolls Kibana with Elasticsearch
8. Generates a Fleet Server service token and starts Fleet Server via `elastic-agent`
9. Opens required firewall ports (supports `firewalld` and `ufw`)
10. Prints a full credential and access URL summary, saved to a local file

## Output files

Both files are written to the same directory as the script:

| File | Contents |
|---|---|
| `elastic-install-<timestamp>.log` | Full step-by-step install log including all credentials |
| `elastic-install-summary.txt` | Access URLs, credentials, and next-step guidance |

## Credentials shown after install

- `elastic` superuser password
- `kibana_system` user password (if custom password was set)
- Kibana enrollment token
- Fleet Server service token
- CA certificate path (for HTTPS connections to Elasticsearch)

## Multi-node deployments

For multi-node clusters, run the script on each node individually. The script will prompt for:
- Node role (master+data, master-only, data-only, coordinating-only)
- Cluster name and node name
- Seed hosts for cluster discovery
- Initial master nodes (for first-time cluster bootstrap)

> **Important:** After the cluster is healthy and green, remove `cluster.initial_master_nodes` from `elasticsearch.yml` on all nodes and restart Elasticsearch to prevent accidental re-bootstrap.

## Security

- TLS is enabled by default on all Elasticsearch HTTP and transport connections
- Kibana uses an enrollment token to establish a trusted connection to Elasticsearch
- Fleet Server communicates with Elasticsearch over TLS using the CA certificate
- `xpack.encryptedSavedObjects.encryptionKey` is automatically generated and set in `kibana.yml` (required for Fleet)

## Troubleshooting

Check the install log for detailed output from every step:

```bash
cat elastic-install-*.log
```

Check service status and logs:

```bash
systemctl status elasticsearch kibana elastic-agent
journalctl -u elasticsearch -n 100 --no-pager
journalctl -u kibana -n 100 --no-pager
```

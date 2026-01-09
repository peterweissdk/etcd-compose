# 💾 etcd Docker Compose

[![Static Badge](https://img.shields.io/badge/Docker-Compose-white?style=flat&logo=docker&logoColor=white&logoSize=auto&labelColor=black)](https://docker.com/)
[![Static Badge](https://img.shields.io/badge/etcd-white?style=flat&logo=etcd&logoColor=white&logoSize=auto&labelColor=black)](https://etcd.io)
[![Static Badge](https://img.shields.io/badge/Linux-white?style=flat&logo=linux&logoColor=white&logoSize=auto&labelColor=black)](https://www.linux.org/)
[![Static Badge](https://img.shields.io/badge/GPL-V3-white?style=flat&logo=gnu&logoColor=white&logoSize=auto&labelColor=black)](https://www.gnu.org/licenses/gpl-3.0.en.html/)

A streamlined setup for deploying an **etcd** distributed key-value store cluster using Docker Compose.

## ✨ Features

- **Interactive Setup** — Guided script for cluster configuration
- **Multi-node Support** — Configure 1-9 node clusters
- **Container Management** — Create or reset etcd containers
- **Automatic Configuration** — Generates `.env` file with cluster settings
- **Retry Logic** — Automatic retry on container startup failures

## 🚀 Quick Start

1. **Run the setup script:**
   ```bash
   ./etcd-compose.sh
   ```

2. **Follow the prompts to configure:**
   - Number of nodes in the cluster
   - Node names and IP addresses
   - etcd version and token

3. **The script will:**
   - Generate the `.env` configuration file
   - Start the etcd container
   - Update cluster state after successful startup

## 🔧 Configuration

All configuration is stored in the `.env` file:

| Variable | Description | Default |
|----------|-------------|---------|
| `ETCD_VERSION` | etcd Docker image version | `v3.6.0` |
| `TOKEN` | Cluster token (same on all nodes) | — |
| `CLUSTER_STATE` | `new` for initial setup, `existing` after | `new` |
| `REGISTRY` | Docker registry for etcd image | `gcr.io/etcd-development/etcd` |
| `DATA_DIR` | Host path for etcd data | `/var/lib/etcd` |
| `NAME_1`, `NAME_2`, ... | Node names | — |
| `HOST_1`, `HOST_2`, ... | Node IP addresses | — |
| `CLUSTER` | Cluster member URLs | Auto-generated |

## 📝 Directory Structure

```
etcd-compose/
├── docker-compose.yml   # Docker Compose service definition
├── .env                 # Environment variables (generated)
├── etcd-compose.sh      # Interactive setup script
└── README.md            # This file
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 🆘 Support

If you encounter any issues or need support, please file an issue on the GitHub repository.

## 📄 License

This project is licensed under the GNU GENERAL PUBLIC LICENSE v3.0 - see the [LICENSE](LICENSE) file for details.
# 💾 etcd Cluster with TLS - Docker Compose Setup
[![Static Badge](https://img.shields.io/badge/etcd-Cluster-white?style=flat&logo=etcd&logoColor=white&logoSize=auto&labelColor=black)](https://etcd.io/)
[![Static Badge](https://img.shields.io/badge/Docker-Compose-white?style=flat&logo=docker&logoColor=white&logoSize=auto&labelColor=black)](https://docker.com/)
[![Static Badge](https://img.shields.io/badge/Library-white?style=flat&logo=openssl&logoColor=white&logoSize=auto&labelColor=black)](https://openssl.org/)
[![Static Badge](https://img.shields.io/badge/Linux-white?style=flat&logo=linux&logoColor=white&logoSize=auto&labelColor=black)](https://www.linux.org/)
[![Static Badge](https://img.shields.io/badge/GPL-V3-white?style=flat&logo=gnu&logoColor=white&logoSize=auto&labelColor=black)](https://www.gnu.org/licenses/gpl-3.0.en.html/)

This guide documents how to deploy a 2-node etcd cluster with mutual TLS authentication using Docker Compose.

## 📋 Overview

- **etcd version**: v3.6.8
- **Nodes**: 2 (etcd-01 @ 10.0.0.10, etcd-02 @ 10.0.0.11)
- **TLS**: Mutual TLS for both client and peer communication
- **OpenSSL**: Used for certificate generation


---
## 🔧 Configuration

### **Part 1: TLS Certificate Generation**

**💡 Important**: Use the same CA for all nodes, and client certificates!


### 1.1 Create Directory Structure

```bash
mkdir -vp certs/{ca,server,client,peer}
cd certs
```

### 1.2 Certificate Authority (CA)

Initialize CA database files:

```bash
touch ca/db.index
echo '01' > ca/ca.srl
```

Create `ca/openssl-ca.cnf`:

```ini
[ ca ]
default_ca = ca_config

[ ca_config ]
dir      = .
database = $dir/db.index
serial   = $dir/ca.srl
name_opt = ca_default
cert_opt = ca_default
preserve = no

[req]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_ca

[dn]
countryName            = DK
stateOrProvinceName    = Zealand
localityName           = Copenhagen
organizationName       = foo
organizationalUnitName = Security
emailAddress           = admin@foo.dk
commonName             = etcd-ca

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = CA:TRUE
```

Generate CA key and certificate:

```bash
openssl genrsa -out ca/ca.key 4096

openssl req -x509 -config ca/openssl-ca.cnf -new -nodes -key ca/ca.key -out ca/ca.pem -days 3650
```

### 1.3 Server Certificate

Create `server/openssl-server.cnf`:

```ini
[ req ]
distinguished_name = dn
req_extensions     = req_ext
prompt             = no

[ dn ]
countryName            = DK
stateOrProvinceName    = Zealand
localityName           = Copenhagen
organizationName       = foo
organizationalUnitName = Security
emailAddress           = admin@foo.dk
commonName             = etcd-01

[ req_ext ]
basicConstraints = CA:FALSE
extendedKeyUsage = clientAuth, serverAuth
keyUsage         = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName   = @alt_names

[ alt_names ]
DNS.1 = etcd-01
DNS.2 = etcd-02
IP.1 = 127.0.0.1
IP.2 = 10.0.0.10
IP.3 = 10.0.0.11
```

Generate server certificate:

```bash
openssl genrsa -out server/server.key 4096

openssl req -new -key server/server.key -out server/server.csr -config server/openssl-server.cnf

openssl x509 -req -in server/server.csr -CA ca/ca.pem -CAkey ca/ca.key -out server/server.pem -days 3650 -extfile server/openssl-server.cnf -extensions req_ext
```

### 1.4 Peer Certificate

Create `peer/openssl-peer.cnf`:

```ini
[ req ]
distinguished_name = dn
req_extensions     = req_ext
prompt             = no

[ dn ]
countryName            = DK
stateOrProvinceName    = Zealand
localityName           = Copenhagen
organizationName       = foo
organizationalUnitName = Security
emailAddress           = admin@foo.dk
commonName             = etcd-01

[ req_ext ]
basicConstraints = CA:FALSE
extendedKeyUsage = clientAuth, serverAuth
keyUsage         = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName   = @alt_names

[ alt_names ]
DNS.1 = etcd-01
DNS.2 = etcd-02
IP.1 = 127.0.0.1
IP.2 = 10.0.0.10
IP.3 = 10.0.0.11
```

Generate peer certificate:

```bash
openssl genrsa -out peer/peer.key 4096

openssl req -new -key peer/peer.key -out peer/peer.csr -config peer/openssl-peer.cnf

openssl x509 -req -in peer/peer.csr -CA ca/ca.pem -CAkey ca/ca.key -out peer/peer.pem -days 3650 -extfile peer/openssl-peer.cnf -extensions req_ext
```

### 1.5 Client Certificate

Create `client/openssl-client.cnf`:

```ini
[ req ]
distinguished_name  = req_dn
req_extensions      = req_ext
prompt              = no

[ req_dn ]
countryName            = DK
stateOrProvinceName    = Zealand
localityName           = Copenhagen
organizationName       = foo
organizationalUnitName = Security
emailAddress           = admin@foo.dk
commonName             = etcd-client

[ req_ext ]
basicConstraints       = CA:FALSE
extendedKeyUsage       = clientAuth
keyUsage               = digitalSignature, keyEncipherment
```

Generate client certificate:

```bash
openssl genrsa -out client/etcd-client.key 4096

openssl req -new -key client/etcd-client.key -out client/etcd-client.csr -config client/openssl-client.cnf

openssl x509 -req -in client/etcd-client.csr -CA ca/ca.pem -CAkey ca/ca.key -out client/etcd-client.pem -days 3650 -extfile client/openssl-client.cnf -extensions req_ext
```

---

### **Part 2: Docker Compose Configuration**

### Node 1 (etcd-01) - docker-compose.yml

Deploy on host with IP `10.0.0.10`:

```yaml
services:
  etcd:
    image: gcr.io/etcd-development/etcd:v3.6.8
    container_name: etcd-v3.6.8
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./etcd-data:/etcd-data
      - ./certs:/certs
    healthcheck:
      test:
        - CMD
        - etcdctl
        - --endpoints=https://10.0.0.10:2379
        - --cacert=/certs/ca/ca.pem
        - --cert=/certs/client/etcd-client.pem
        - --key=/certs/client/etcd-client.key
        - endpoint
        - health
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    command: |
      /usr/local/bin/etcd
      --name etcd-01
      --data-dir /etcd-data
      --listen-client-urls https://10.0.0.10:2379
      --advertise-client-urls https://10.0.0.10:2379
      --listen-peer-urls https://10.0.0.10:2380
      --initial-advertise-peer-urls https://10.0.0.10:2380
      --initial-cluster etcd-01=https://10.0.0.10:2380,etcd-02=https://10.0.0.11:2380
      --initial-cluster-token superSecretToken
      --initial-cluster-state new
      --log-level info
      --logger zap
      --log-outputs stderr
      --client-cert-auth=true
      --trusted-ca-file=/certs/ca/ca.pem
      --cert-file=/certs/server/server.pem
      --key-file=/certs/server/server.key
      --peer-client-cert-auth=true
      --peer-trusted-ca-file=/certs/ca/ca.pem
      --peer-cert-file=/certs/peer/peer.pem
      --peer-key-file=/certs/peer/peer.key
```

### Node 2 (etcd-02) - docker-compose.yml

Deploy on host with IP `10.0.0.11`:

```yaml
services:
  etcd:
    image: gcr.io/etcd-development/etcd:v3.6.8
    container_name: etcd-v3.6.8
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./etcd-data:/etcd-data
      - ./certs:/certs
    healthcheck:
      test:
        - CMD
        - etcdctl
        - --endpoints=https://10.0.0.11:2379
        - --cacert=/certs/ca/ca.pem
        - --cert=/certs/client/etcd-client.pem
        - --key=/certs/client/etcd-client.key
        - endpoint
        - health
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    command: |
      /usr/local/bin/etcd
      --name etcd-02
      --data-dir /etcd-data
      --listen-client-urls https://10.0.0.11:2379
      --advertise-client-urls https://10.0.0.11:2379
      --listen-peer-urls https://10.0.0.11:2380
      --initial-advertise-peer-urls https://10.0.0.11:2380
      --initial-cluster etcd-01=https://10.0.0.10:2380,etcd-02=https://10.0.0.11:2380
      --initial-cluster-token superSecretToken
      --initial-cluster-state new
      --log-level info
      --logger zap
      --log-outputs stderr
      --client-cert-auth=true
      --trusted-ca-file=/certs/ca/ca.pem
      --cert-file=/certs/server/server.pem
      --key-file=/certs/server/server.key
      --peer-client-cert-auth=true
      --peer-trusted-ca-file=/certs/ca/ca.pem
      --peer-cert-file=/certs/peer/peer.pem
      --peer-key-file=/certs/peer/peer.key
```

### Key Configuration Options

| Option | Description |
|--------|-------------|
| `--name` | Unique name for each etcd member |
| `--initial-cluster` | Comma-separated list of all cluster members |
| `--initial-cluster-token` | Shared token for cluster bootstrap (change for security) |
| `--initial-cluster-state` | Use `new` for initial bootstrap, `existing` when adding members |
| `--client-cert-auth` | Require client certificates for authentication |
| `--peer-client-cert-auth` | Require peer certificates for inter-node communication |

---

### **Part 3: Deployment**

### 3.1 Copy Certificates to Each Node

Ensure the `certs/` directory (with CA, server, and peer certificates) is present on both nodes.

### 3.2 Start the Cluster

On each node:

```bash
docker compose up -d
```

### 3.3 Verify Cluster Health

**Option 1: Using local etcdctl**

```bash
etcdctl --endpoints=https://10.0.0.10:2379,https://10.0.0.11:2379 \
  --cacert=/path/to/certs/ca/ca.pem \
  --cert=/path/to/certs/client/etcd-client.pem \
  --key=/path/to/certs/client/etcd-client.key \
  endpoint health -w table
```

**Option 2: Using docker exec**

```bash
docker exec etcd-v3.6.8 etcdctl \
  --endpoints=https://10.0.0.10:2379,https://10.0.0.11:2379 \
  --cacert=/certs/ca/ca.pem \
  --cert=/certs/client/etcd-client.pem \
  --key=/certs/client/etcd-client.key \
  endpoint health -w table
```

Expected output:

```
+---------------------------+--------+-------------+-------+
|         ENDPOINT          | HEALTH |    TOOK     | ERROR |
+---------------------------+--------+-------------+-------+
| https://10.0.0.10:2379    |   true |  10.123ms   |       |
| https://10.0.0.11:2379    |   true |  12.456ms   |       |
+---------------------------+--------+-------------+-------+
```

### 3.4 Check Cluster Members

**Option 1: Using local etcdctl**

```bash
etcdctl --endpoints=https://10.0.0.10:2379 \
  --cacert=/path/to/certs/ca/ca.pem \
  --cert=/path/to/certs/client/etcd-client.pem \
  --key=/path/to/certs/client/etcd-client.key \
  member list -w table
```

**Option 2: Using docker exec**

```bash
docker exec etcd-v3.6.8 etcdctl \
  --endpoints=https://10.0.0.10:2379 \
  --cacert=/certs/ca/ca.pem \
  --cert=/certs/client/etcd-client.pem \
  --key=/certs/client/etcd-client.key \
  member list -w table
```

---
## 📝 Directory Structure

```
.
├── docker-compose.yml
├── certs/
│   ├── ca/
│   │   ├── ca.key
│   │   ├── ca.pem
│   │   ├── ca.srl
│   │   ├── db.index
│   │   └── openssl-ca.cnf
│   ├── server/
│   │   ├── server.key
│   │   ├── server.pem
│   │   ├── server.csr
│   │   └── openssl-server.cnf
│   ├── peer/
│   │   ├── peer.key
│   │   ├── peer.pem
│   │   ├── peer.csr
│   │   └── openssl-peer.cnf
│   └── client/
│       ├── etcd-client.key
│       ├── etcd-client.pem
│       ├── etcd-client.csr
│       └── openssl-client.cnf
└── etcd-data/
```
---
## 📜 Certificate Types Explained

**Server Certificate** (`server.pem`)
- Used by etcd to authenticate itself to **clients** connecting on port 2379
- When a client (like `etcdctl` or Kubernetes API server) connects, etcd presents this certificate to prove its identity
- The client verifies the certificate against the trusted CA
- Configured via `--cert-file` and `--key-file`

**Peer Certificate** (`peer.pem`)
- Used for **inter-node communication** between etcd cluster members on port 2380
- Each etcd node uses this to authenticate itself to other etcd nodes during:
  - Leader election
  - Log replication (Raft consensus)
  - Cluster membership changes
- Configured via `--peer-cert-file` and `--peer-key-file`

**Client Certificate** (`etcd-client.pem`)
- Used by **applications and tools** to authenticate themselves to etcd
- Required when `--client-cert-auth=true` is enabled (mutual TLS)
- Common clients include:
  - `etcdctl` CLI tool
  - **Kubernetes components** (see below)
  - Application services that read/write to etcd

#### Kubernetes and etcd Client Certificates

In a Kubernetes cluster, etcd is the backing store for all cluster data. The following components require client certificates to communicate with etcd:

| Component | Purpose |
|-----------|---------|
| **kube-apiserver** | Primary client - stores all cluster state (pods, services, secrets, configmaps) |
| **etcd backup tools** | Tools like `etcdctl` for snapshots and disaster recovery |
| **etcd defrag jobs** | Maintenance operations to compact the database |

**Important**: The client certificate must be signed by the **same CA** that signed the etcd server certificate. etcd only trusts certificates signed by its own CA (configured via `--trusted-ca-file`).

To configure Kubernetes to authenticate to etcd, copy the generated etcd client certificate files to the Kubernetes control plane node(s) and configure kube-apiserver:

1. Copy the etcd client certificates to the control plane:
   ```bash
   # Copy from your etcd certificate directory to Kubernetes PKI
   cp certs/ca/ca.pem /etc/kubernetes/pki/etcd/ca.crt
   cp certs/client/etcd-client.pem /etc/kubernetes/pki/apiserver-etcd-client.crt
   cp certs/client/etcd-client.key /etc/kubernetes/pki/apiserver-etcd-client.key
   
   # Set proper permissions
   chmod 644 /etc/kubernetes/pki/etcd/ca.crt
   chmod 644 /etc/kubernetes/pki/apiserver-etcd-client.crt
   chmod 600 /etc/kubernetes/pki/apiserver-etcd-client.key
   ```

2. Configure kube-apiserver with the etcd client certificate:
   ```yaml
   # kube-apiserver flags
   --etcd-servers=https://10.0.0.10:2379,https://10.0.0.11:2379
   --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
   --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
   --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
   ```
---

## 🔍 Troubleshooting

### View Logs

```bash
docker logs etcd-v3.6.8
```

### Common Issues

1. **Certificate errors**: Ensure all SANs (Subject Alternative Names) include the correct IPs and hostnames
2. **Connection refused**: Verify `network_mode: host` and correct IP bindings
3. **Cluster not forming**: Check that `--initial-cluster-token` matches on all nodes
4. **Client or Peer certificate authentication failed**: Ensure the client/peer certificate is signed by the same CA as the server certificate

---

## ⚠️ Security Notes

- Store private keys securely and restrict file permissions (`chmod 600`)
- Change `--initial-cluster-token` to a unique, secure value
- Rotate certificates before expiration (currently set to 3650 days / 10 years)
- Consider using a proper PKI infrastructure for production environments
---
## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 🆘 Support

If you encounter any issues or need support, please file an issue on the GitHub repository.

## 📄 License

This project is licensed under the GNU GENERAL PUBLIC LICENSE v3.0 - see the [LICENSE](LICENSE) file for details.
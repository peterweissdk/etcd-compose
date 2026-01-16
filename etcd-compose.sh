#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
COMPOSE_TLS_FILE="${SCRIPT_DIR}/docker-compose.tls.yml"
COMPOSE_CA_FILE="${SCRIPT_DIR}/docker-compose.ca.yml"
CONTAINER_NAME="etcd"
PKI_DIR="${SCRIPT_DIR}/pki"
CERT_DIR="${PKI_DIR}/certs"
BIN_DIR="${SCRIPT_DIR}/bin"

# Check if cfssl is installed, if not download it
check_cfssl() {
    if [ ! -x "${BIN_DIR}/cfssl" ] || [ ! -x "${BIN_DIR}/cfssljson" ]; then
        echo "cfssl tools not found. Installing..."
        "${SCRIPT_DIR}/scripts/install-cfssl.sh" "$BIN_DIR"
    fi
}

# cfssl command wrapper
cfssl_cmd() {
    "${BIN_DIR}/cfssl" "$@"
}

# cfssljson command wrapper
cfssljson_cmd() {
    "${BIN_DIR}/cfssljson" "$@"
}

# Exit codes
EXIT_SUCCESS=0
EXIT_USER_ABORT=1
EXIT_CONTAINER_FAILED=2
EXIT_SETUP_FAILED=3

# Function to check container state
get_container_state() {
    local state
    state=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null) || true
    if [ -n "$state" ]; then
        echo "$state"
    else
        echo "not_found"
    fi
}

# Function to show container status
show_container_status() {
    echo ""
    echo "=== etcd Container Status ==="
    docker ps -a --filter "name=^${CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
}

# Function to stop container if running
stop_container() {
    local state
    state=$(get_container_state)
    if [ "$state" = "running" ]; then
        echo "Stopping etcd container..."
        docker stop "$CONTAINER_NAME" > /dev/null
        echo "Container stopped."
    fi
}

# Function to remove container
remove_container() {
    echo "Removing etcd container..."
    docker rm "$CONTAINER_NAME" > /dev/null
    echo "Container removed."
}

# Function to prompt yes/no
prompt_yes_no() {
    local prompt="$1"
    local response
    while true; do
        read -rp "$prompt [y/n]: " response
        case "$response" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# Function to setup SSH key and copy to remote host
setup_ssh_to_node1() {
    local node1_ip="$1"
    local ssh_user="${2:-$(whoami)}"
    
    echo ""
    echo "=== Setting up SSH connection to Node 1 ==="
    echo ""
    
    # Check if SSH key exists, if not generate one
    if [ ! -f "$HOME/.ssh/id_rsa" ] && [ ! -f "$HOME/.ssh/id_ed25519" ]; then
        echo "No SSH key found. Generating new SSH key..."
        ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -q
        echo "SSH key generated: $HOME/.ssh/id_ed25519"
    else
        echo "SSH key already exists."
    fi
    
    # Test SSH connection first
    echo ""
    echo "Testing SSH connection to ${ssh_user}@${node1_ip}..."
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${ssh_user}@${node1_ip}" "echo 'SSH connection successful'" 2>/dev/null; then
        echo "✓ SSH connection already configured."
        return 0
    fi
    
    # SSH key not copied yet, use ssh-copy-id
    echo ""
    echo "SSH key not yet authorized on Node 1."
    echo "Running ssh-copy-id to copy your public key to Node 1..."
    echo "You will be prompted for the password for ${ssh_user}@${node1_ip}"
    echo ""
    
    if ssh-copy-id "${ssh_user}@${node1_ip}"; then
        echo ""
        echo "✓ SSH key copied successfully."
        return 0
    else
        echo ""
        echo "✗ Failed to copy SSH key to Node 1."
        return 1
    fi
}

# Function to download PKI files from Node 1 via SSH
download_pki_from_node1() {
    local node1_ip="$1"
    local ssh_user="${2:-$(whoami)}"
    local remote_pki_dir="${3:-/home/${ssh_user}/Git/docker-compose/etcd-compose/pki}"
    
    echo ""
    echo "=== Downloading PKI files from Node 1 ==="
    echo ""
    
    # Create local PKI directory
    mkdir -p "${PKI_DIR}"
    
    # Files to download
    local files_to_copy=(
        "ca-config.json"
        "ca-chain.pem"
        "intermediate-ca.pem"
        "intermediate-ca-key.pem"
        "server-csr.json"
        "peer-csr.json"
        "client-csr.json"
        "multirootca-config.json"
    )
    
    echo "Downloading PKI files from ${ssh_user}@${node1_ip}:${remote_pki_dir}..."
    
    local failed=false
    for file in "${files_to_copy[@]}"; do
        echo "  Copying ${file}..."
        if scp -q "${ssh_user}@${node1_ip}:${remote_pki_dir}/${file}" "${PKI_DIR}/" 2>/dev/null; then
            echo "    ✓ ${file}"
        else
            echo "    ✗ ${file} (not found or failed)"
            # ca-chain.pem and intermediate CA files are critical
            if [[ "$file" == "ca-chain.pem" ]] || [[ "$file" == "intermediate-ca.pem" ]] || [[ "$file" == "intermediate-ca-key.pem" ]]; then
                failed=true
            fi
        fi
    done
    
    if [ "$failed" = true ]; then
        echo ""
        echo "✗ Failed to download critical PKI files from Node 1."
        return 1
    fi
    
    # Set permissions
    chmod 644 "${PKI_DIR}"/*.pem 2>/dev/null || true
    chmod 600 "${PKI_DIR}"/*-key.pem 2>/dev/null || true
    chmod 644 "${PKI_DIR}"/*.json 2>/dev/null || true
    
    echo ""
    echo "✓ PKI files downloaded successfully."
    return 0
}

# Function to prompt for input with optional default
prompt_input() {
    local prompt="$1"
    local default="$2"
    local response
    if [ -n "$default" ]; then
        read -rp "$prompt [$default]: " response
        echo "${response:-$default}"
    else
        while true; do
            read -rp "$prompt: " response
            if [ -n "$response" ]; then
                echo "$response"
                break
            else
                echo "Value cannot be empty." >&2
            fi
        done
    fi
}

# Function to run etcd setup
run_etcd_setup() {
    echo ""
    echo "=== etcd Setup ==="
    
    # Handle .env file
    if [ -f "$ENV_FILE" ]; then
        echo "Existing .env file detected. Clearing contents..."
        > "$ENV_FILE"
    else
        echo "Creating new .env file..."
        touch "$ENV_FILE"
    fi
    
    # Prompt for number of nodes
    local num_nodes
    while true; do
        read -rp "How many nodes in the cluster? [1-9]: " num_nodes
        if [[ "$num_nodes" =~ ^[1-9]$ ]]; then
            break
        else
            echo "Please enter a number between 1 and 9."
        fi
    done
    
    # Write static header
    echo "REGISTRY=gcr.io/etcd-development/etcd" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Collect node names and hosts
    declare -a names
    declare -a hosts
    
    echo ""
    echo "Enter the name and host for THIS node (where the container will run):"
    names[1]=$(prompt_input "Set NAME_1 (this node)")
    hosts[1]=$(prompt_input "Set HOST_1 (this node)")
    
    # Collect remaining nodes if more than 1
    if [ "$num_nodes" -gt 1 ]; then
        echo ""
        echo "Enter names and hosts for the other cluster nodes:"
        for ((i=2; i<=num_nodes; i++)); do
            names[$i]=$(prompt_input "Set NAME_$i")
            hosts[$i]=$(prompt_input "Set HOST_$i")
        done
    fi
    
    # Prompt for other settings
    echo ""
    local etcd_version
    etcd_version=$(prompt_input "Set ETCD_VERSION" "v3.6.0")
    
    local token
    token=$(prompt_input "Set TOKEN")
    
    local data_dir
    data_dir=$(prompt_input "Set DATA_DIR" "/var/lib/etcd")
    
    # Write to .env file
    echo "# etcd configuration" >> "$ENV_FILE"
    echo "ETCD_VERSION=$etcd_version" >> "$ENV_FILE"
    echo "TOKEN=$token" >> "$ENV_FILE"
    echo "CLUSTER_STATE=new" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Write node names
    echo "# Node names" >> "$ENV_FILE"
    for ((i=1; i<=num_nodes; i++)); do
        echo "NAME_$i=${names[$i]}" >> "$ENV_FILE"
    done
    echo "" >> "$ENV_FILE"
    
    # Write node hosts
    echo "# Node hosts" >> "$ENV_FILE"
    for ((i=1; i<=num_nodes; i++)); do
        echo "HOST_$i=${hosts[$i]}" >> "$ENV_FILE"
    done
    echo "" >> "$ENV_FILE"
    
    # Build and write CLUSTER variable
    local cluster=""
    local protocol="http"
    for ((i=1; i<=num_nodes; i++)); do
        if [ $i -gt 1 ]; then
            cluster+=","
        fi
        cluster+="\${NAME_$i}=${protocol}://\${HOST_$i}:2380"
    done
    echo "# Cluster definition" >> "$ENV_FILE"
    echo "CLUSTER=$cluster" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Write data directory
    echo "# Data directory on host" >> "$ENV_FILE"
    echo "DATA_DIR=$data_dir" >> "$ENV_FILE"
    
    echo ""
    echo ".env file created successfully."
    echo "This node will use NAME_1 (${names[1]}) and HOST_1 (${hosts[1]})."
    
    # Prompt to start container
    echo ""
    if prompt_yes_no "Start etcd container now?"; then
        cd "$SCRIPT_DIR"
        
        local max_attempts=3
        local attempt=1
        local state=""
        
        while [ $attempt -le $max_attempts ]; do
            echo "Starting etcd container (attempt $attempt of $max_attempts)..."
            docker compose up -d
            
            # Wait a moment for container to start
            sleep 2
            
            # Check if container is running
            state=$(get_container_state)
            
            if [ "$state" = "running" ]; then
                echo ""
                echo "✓ etcd container is running successfully!"
                show_container_status
                
                # Update CLUSTER_STATE to existing
                echo "Updating CLUSTER_STATE to 'existing' in .env file..."
                sed -i 's/CLUSTER_STATE=new/CLUSTER_STATE=existing/' "$ENV_FILE"
                echo "CLUSTER_STATE updated."
                
                exit $EXIT_SUCCESS
            else
                echo "Attempt $attempt failed."
                if [ $attempt -lt $max_attempts ]; then
                    echo "Retrying..."
                    sleep 2
                fi
            fi
            
            ((attempt++))
        done
        
        # All attempts failed
        echo ""
        echo "✗ etcd container failed to start after $max_attempts attempts."
        show_container_status
        echo ""
        if prompt_yes_no "Run setup again?"; then
            run_etcd_setup
        else
            exit $EXIT_CONTAINER_FAILED
        fi
    else
        echo "Container not started."
        exit $EXIT_USER_ABORT
    fi
}

# Function to run etcd TLS setup
run_etcd_tls_setup() {
    echo ""
    echo "=== etcd TLS Cluster Setup ==="
    echo ""
    echo "This will set up an etcd node with TLS encryption."
    echo ""
    echo "Node 1 is the CA server (runs multirootca)."
    echo "Other nodes request certificates from the CA server."
    echo ""
    
    # Ask which node this is
    local this_node
    while true; do
        read -rp "Which node is this? [1-9]: " this_node
        if [[ "$this_node" =~ ^[1-9]$ ]]; then
            break
        else
            echo "Please enter a number between 1 and 9."
        fi
    done
    
    local is_ca_server=false
    if [ "$this_node" -eq 1 ]; then
        is_ca_server=true
        echo ""
        echo "This is Node 1 - will set up CA server and generate certificates."
    else
        echo ""
        echo "This is Node $this_node - will request certificates from CA server."
    fi
    
    # Handle .env file
    if [ -f "$ENV_FILE" ]; then
        echo ""
        echo "Existing .env file detected. Clearing contents..."
        > "$ENV_FILE"
    else
        echo "Creating new .env file..."
        touch "$ENV_FILE"
    fi
    
    # Prompt for number of nodes
    local num_nodes
    while true; do
        read -rp "How many nodes in the cluster? [1-9]: " num_nodes
        if [[ "$num_nodes" =~ ^[1-9]$ ]]; then
            if [ "$this_node" -gt "$num_nodes" ]; then
                echo "This node ($this_node) cannot be greater than total nodes ($num_nodes)."
            else
                break
            fi
        else
            echo "Please enter a number between 1 and 9."
        fi
    done
    
    # Write static header
    echo "REGISTRY=gcr.io/etcd-development/etcd" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Collect node names and hosts
    declare -a names
    declare -a hosts
    
    echo ""
    echo "Enter the name and host for all cluster nodes:"
    for ((i=1; i<=num_nodes; i++)); do
        if [ "$i" -eq "$this_node" ]; then
            names[$i]=$(prompt_input "Set NAME_$i (THIS node)")
            hosts[$i]=$(prompt_input "Set HOST_$i (THIS node)")
        else
            names[$i]=$(prompt_input "Set NAME_$i")
            hosts[$i]=$(prompt_input "Set HOST_$i")
        fi
    done
    
    # Prompt for other settings
    echo ""
    local etcd_version
    etcd_version=$(prompt_input "Set ETCD_VERSION" "v3.6.0")
    
    local token
    token=$(prompt_input "Set TOKEN")
    
    local data_dir
    local default_data_dir="/var/lib/etcd"
    
    # Check if existing database exists at default location
    if [ -d "$default_data_dir" ] && [ "$(ls -A "$default_data_dir" 2>/dev/null)" ]; then
        echo ""
        echo "WARNING: Existing etcd database found at ${default_data_dir}"
        echo ""
        if prompt_yes_no "Delete existing database at ${default_data_dir}?"; then
            echo "Deleting existing database..."
            sudo rm -rf "${default_data_dir:?}"/*
            echo "Database deleted."
            data_dir=$(prompt_input "Set DATA_DIR" "$default_data_dir")
        else
            echo ""
            echo "You must specify a different DATA_DIR location."
            while true; do
                data_dir=$(prompt_input "Set DATA_DIR (cannot be ${default_data_dir})")
                if [ "$data_dir" = "$default_data_dir" ]; then
                    echo "ERROR: Cannot use ${default_data_dir} - existing database not deleted."
                else
                    break
                fi
            done
        fi
    else
        data_dir=$(prompt_input "Set DATA_DIR" "$default_data_dir")
    fi
    
    local cert_dir
    cert_dir=$(prompt_input "Set CERT_DIR (certificate directory on host)" "/etc/etcd/pki")
    
    # For non-CA nodes, get CA server URL
    local ca_server_url=""
    if [ "$is_ca_server" = false ]; then
        ca_server_url="https://${hosts[1]}:8888"
        echo ""
        echo "CA server URL: $ca_server_url"
    fi
    
    # Write to .env file
    echo "# etcd configuration" >> "$ENV_FILE"
    echo "ETCD_VERSION=$etcd_version" >> "$ENV_FILE"
    echo "TOKEN=$token" >> "$ENV_FILE"
    echo "CLUSTER_STATE=new" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Write TLS configuration
    echo "# TLS configuration" >> "$ENV_FILE"
    echo "TLS_ENABLED=true" >> "$ENV_FILE"
    echo "PKI_DIR=${PKI_DIR}" >> "$ENV_FILE"
    echo "CERT_DIR=${cert_dir}" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Write node names
    echo "# Node names" >> "$ENV_FILE"
    for ((i=1; i<=num_nodes; i++)); do
        echo "NAME_$i=${names[$i]}" >> "$ENV_FILE"
    done
    echo "" >> "$ENV_FILE"
    
    # Write node hosts
    echo "# Node hosts" >> "$ENV_FILE"
    for ((i=1; i<=num_nodes; i++)); do
        echo "HOST_$i=${hosts[$i]}" >> "$ENV_FILE"
    done
    echo "" >> "$ENV_FILE"
    
    # Build and write CLUSTER variable with HTTPS
    local cluster=""
    for ((i=1; i<=num_nodes; i++)); do
        if [ $i -gt 1 ]; then
            cluster+=","
        fi
        cluster+="\${NAME_$i}=https://\${HOST_$i}:2380"
    done
    echo "# Cluster definition (TLS)" >> "$ENV_FILE"
    echo "CLUSTER=$cluster" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"
    
    # Write data directory
    echo "# Data directory on host" >> "$ENV_FILE"
    echo "DATA_DIR=$data_dir" >> "$ENV_FILE"
    
    echo ""
    echo ".env file created successfully with TLS configuration."
    echo ""
    
    # Ensure cfssl is available
    check_cfssl
    
    # Node-specific setup
    if [ "$is_ca_server" = true ]; then
        # === NODE 1: Full CA setup ===
        echo "=== Initializing PKI Infrastructure (Node 1 - CA Server) ==="
        echo ""
        
        # Install and enable SSH server so other nodes can connect
        echo "Ensuring SSH server is installed and running..."
        if ! systemctl is-active --quiet sshd 2>/dev/null && ! systemctl is-active --quiet ssh 2>/dev/null; then
            echo "SSH server not running. Installing and enabling..."
            if command -v apt-get &>/dev/null; then
                sudo apt-get update -qq && sudo apt-get install -y -qq openssh-server
                sudo systemctl enable --now ssh
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y -q openssh-server
                sudo systemctl enable --now sshd
            elif command -v yum &>/dev/null; then
                sudo yum install -y -q openssh-server
                sudo systemctl enable --now sshd
            elif command -v pacman &>/dev/null; then
                sudo pacman -S --noconfirm --quiet openssh
                sudo systemctl enable --now sshd
            elif command -v zypper &>/dev/null; then
                sudo zypper install -y -q openssh
                sudo systemctl enable --now sshd
            else
                echo "WARNING: Could not detect package manager. Please install SSH server manually."
            fi
        fi
        
        # Verify SSH is running
        if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
            echo "✓ SSH server is running."
        else
            echo "WARNING: SSH server may not be running. Other nodes may not be able to connect."
        fi
        echo ""
        
        # Generate Root CA
        echo "Generating Root CA certificate (valid for 10 years)..."
        cfssl_cmd gencert -initca "${PKI_DIR}/root-ca-csr.json" | \
            cfssljson_cmd -bare "${PKI_DIR}/root-ca"
        echo "Root CA generated."
        
        # Generate Intermediate CA
        echo ""
        echo "Generating Intermediate CA certificate (valid for 8 years)..."
        cfssl_cmd gencert -initca "${PKI_DIR}/intermediate-ca-csr.json" | \
            cfssljson_cmd -bare "${PKI_DIR}/intermediate-ca-csr"
        
        cfssl_cmd sign \
            -ca "${PKI_DIR}/root-ca.pem" \
            -ca-key "${PKI_DIR}/root-ca-key.pem" \
            -config "${PKI_DIR}/ca-config.json" \
            -profile intermediate \
            "${PKI_DIR}/intermediate-ca-csr.csr" | \
            cfssljson_cmd -bare "${PKI_DIR}/intermediate-ca"
        
        # Copy the key from the CSR step (cfssl sign doesn't output a key)
        cp "${PKI_DIR}/intermediate-ca-csr-key.pem" "${PKI_DIR}/intermediate-ca-key.pem"
        echo "Intermediate CA generated."
        
        # Create CA chain
        echo ""
        echo "Creating CA chain..."
        cat "${PKI_DIR}/intermediate-ca.pem" "${PKI_DIR}/root-ca.pem" > "${PKI_DIR}/ca-chain.pem"
        echo "CA chain created."
        
        # Generate CA server certificate for multirootca
        echo ""
        echo "Generating CA server certificate..."
        cfssl_cmd gencert \
            -ca "${PKI_DIR}/intermediate-ca.pem" \
            -ca-key "${PKI_DIR}/intermediate-ca-key.pem" \
            -config "${PKI_DIR}/ca-config.json" \
            -hostname "localhost,127.0.0.1,${hosts[1]}" \
            -profile server \
            "${PKI_DIR}/server-csr.json" | \
            cfssljson_cmd -bare "${PKI_DIR}/ca-server"
        echo "CA server certificate generated."
        
        # Set CA permissions
        chmod 644 "${PKI_DIR}"/*.pem 2>/dev/null || true
        chmod 600 "${PKI_DIR}"/*-key.pem 2>/dev/null || true
        
        # Generate certificates for this node (Node 1)
        echo ""
        echo "Generating etcd certificates for ${names[1]}..."
        mkdir -p "${CERT_DIR}/${names[1]}"
        
        # Server cert
        cfssl_cmd gencert \
            -ca "${PKI_DIR}/intermediate-ca.pem" \
            -ca-key "${PKI_DIR}/intermediate-ca-key.pem" \
            -config "${PKI_DIR}/ca-config.json" \
            -hostname "localhost,127.0.0.1,${names[1]},${hosts[1]}" \
            -profile server \
            "${PKI_DIR}/server-csr.json" | \
            cfssljson_cmd -bare "${CERT_DIR}/${names[1]}/server"
        
        # Peer cert
        cfssl_cmd gencert \
            -ca "${PKI_DIR}/intermediate-ca.pem" \
            -ca-key "${PKI_DIR}/intermediate-ca-key.pem" \
            -config "${PKI_DIR}/ca-config.json" \
            -hostname "${names[1]},${hosts[1]}" \
            -profile peer \
            "${PKI_DIR}/peer-csr.json" | \
            cfssljson_cmd -bare "${CERT_DIR}/${names[1]}/peer"
        
        # Copy CA chain
        cp "${PKI_DIR}/ca-chain.pem" "${CERT_DIR}/${names[1]}/"
        echo "Node certificates generated."
        
        # Set node cert permissions
        chmod 644 "${CERT_DIR}/${names[1]}"/*.pem 2>/dev/null || true
        chmod 600 "${CERT_DIR}/${names[1]}"/*-key.pem 2>/dev/null || true
        
        # Copy certificates to host cert directory
        echo ""
        echo "Copying certificates to ${cert_dir}..."
        sudo mkdir -p "$cert_dir"
        sudo cp "${CERT_DIR}/${names[1]}/"*.pem "$cert_dir/"
        sudo chmod 644 "$cert_dir"/*.pem
        sudo chmod 600 "$cert_dir"/*-key.pem
        echo "Certificates copied."
        
        # Start multirootca server
        echo ""
        if prompt_yes_no "Start multirootca CA server?"; then
            echo "Starting multirootca server..."
            PKI_DIR="$PKI_DIR" docker compose -f "$COMPOSE_CA_FILE" up -d
            sleep 2
            
            if docker ps --format '{{.Names}}' | grep -q '^multirootca$'; then
                echo "✓ multirootca CA server is running on port 8888."
            else
                echo "✗ Failed to start multirootca server."
            fi
        fi
    else
        # === OTHER NODES: Request certificates from CA server ===
        echo "=== Setting up Node $this_node ==="
        echo ""
        
        local node_name="${names[$this_node]}"
        local node_ip="${hosts[$this_node]}"
        local node1_ip="${hosts[1]}"
        
        # Check if CA chain exists, if not download from Node 1 via SSH
        if [ ! -f "${PKI_DIR}/ca-chain.pem" ]; then
            echo "PKI files not found locally. Will download from Node 1 via SSH."
            echo ""
            
            # Get SSH user for Node 1
            local ssh_user
            ssh_user=$(prompt_input "SSH username for Node 1 (${node1_ip})" "$(whoami)")
            
            # Get remote PKI directory path
            local remote_pki_dir
            remote_pki_dir=$(prompt_input "PKI directory path on Node 1" "/home/${ssh_user}/Git/docker-compose/etcd-compose/pki")
            
            # Setup SSH connection
            if ! setup_ssh_to_node1 "$node1_ip" "$ssh_user"; then
                echo ""
                echo "Failed to setup SSH connection to Node 1."
                echo "Please ensure:"
                echo "  1. SSH server is running on Node 1"
                echo "  2. You have valid credentials for ${ssh_user}@${node1_ip}"
                exit $EXIT_SETUP_FAILED
            fi
            
            # Download PKI files
            if ! download_pki_from_node1 "$node1_ip" "$ssh_user" "$remote_pki_dir"; then
                echo ""
                echo "Failed to download PKI files from Node 1."
                echo "Please ensure the TLS setup has been completed on Node 1 first."
                exit $EXIT_SETUP_FAILED
            fi
        else
            echo "PKI files found locally."
        fi
        
        echo "Generating certificates for ${node_name} (${node_ip})..."
        mkdir -p "${CERT_DIR}/${node_name}"
        
        # Check if we can use local signing (intermediate CA files present)
        if [ -f "${PKI_DIR}/intermediate-ca.pem" ] && [ -f "${PKI_DIR}/intermediate-ca-key.pem" ]; then
            echo "Using local CA files for signing..."
            
            # Server cert
            cfssl_cmd gencert \
                -ca "${PKI_DIR}/intermediate-ca.pem" \
                -ca-key "${PKI_DIR}/intermediate-ca-key.pem" \
                -config "${PKI_DIR}/ca-config.json" \
                -hostname "localhost,127.0.0.1,${node_name},${node_ip}" \
                -profile server \
                "${PKI_DIR}/server-csr.json" | \
                cfssljson_cmd -bare "${CERT_DIR}/${node_name}/server"
            
            # Peer cert
            cfssl_cmd gencert \
                -ca "${PKI_DIR}/intermediate-ca.pem" \
                -ca-key "${PKI_DIR}/intermediate-ca-key.pem" \
                -config "${PKI_DIR}/ca-config.json" \
                -hostname "${node_name},${node_ip}" \
                -profile peer \
                "${PKI_DIR}/peer-csr.json" | \
                cfssljson_cmd -bare "${CERT_DIR}/${node_name}/peer"
        else
            echo "Using remote CA server for signing: $ca_server_url"
            
            # Server cert - generate key and CSR, sign remotely
            cfssl_cmd genkey "${PKI_DIR}/server-csr.json" | \
                cfssljson_cmd -bare "${CERT_DIR}/${node_name}/server"
            
            cfssl_cmd sign \
                -remote "$ca_server_url" \
                -label "etcd-intermediate-ca" \
                -profile "server" \
                -hostname "localhost,127.0.0.1,${node_name},${node_ip}" \
                "${CERT_DIR}/${node_name}/server.csr" | \
                cfssljson_cmd -bare "${CERT_DIR}/${node_name}/server"
            
            # Peer cert
            cfssl_cmd genkey "${PKI_DIR}/peer-csr.json" | \
                cfssljson_cmd -bare "${CERT_DIR}/${node_name}/peer"
            
            cfssl_cmd sign \
                -remote "$ca_server_url" \
                -label "etcd-intermediate-ca" \
                -profile "peer" \
                -hostname "${node_name},${node_ip}" \
                "${CERT_DIR}/${node_name}/peer.csr" | \
                cfssljson_cmd -bare "${CERT_DIR}/${node_name}/peer"
        fi
        
        # Copy CA chain
        cp "${PKI_DIR}/ca-chain.pem" "${CERT_DIR}/${node_name}/"
        echo "Node certificates generated."
        
        # Set permissions
        chmod 644 "${CERT_DIR}/${node_name}"/*.pem 2>/dev/null || true
        chmod 600 "${CERT_DIR}/${node_name}"/*-key.pem 2>/dev/null || true
        
        # Copy certificates to host cert directory
        echo ""
        echo "Copying certificates to ${cert_dir}..."
        sudo mkdir -p "$cert_dir"
        sudo cp "${CERT_DIR}/${node_name}/"*.pem "$cert_dir/"
        sudo chmod 644 "$cert_dir"/*.pem
        sudo chmod 600 "$cert_dir"/*-key.pem
        echo "Certificates copied."
    fi
    
    # Prompt to start etcd container (common for all nodes)
    echo ""
    if prompt_yes_no "Start etcd container with TLS?"; then
        cd "$SCRIPT_DIR"
        
        local max_attempts=3
        local attempt=1
        local state=""
        
        while [ $attempt -le $max_attempts ]; do
            echo "Starting etcd container with TLS (attempt $attempt of $max_attempts)..."
            docker compose -f "$COMPOSE_TLS_FILE" up -d
            
            sleep 3
            
            state=$(get_container_state)
            
            if [ "$state" = "running" ]; then
                echo ""
                echo "✓ etcd container is running with TLS!"
                show_container_status
                
                # Update CLUSTER_STATE to existing
                echo "Updating CLUSTER_STATE to 'existing' in .env file..."
                sed -i 's/CLUSTER_STATE=new/CLUSTER_STATE=existing/' "$ENV_FILE"
                echo "CLUSTER_STATE updated."
                
                echo ""
                echo "=== TLS Setup Complete (Node $this_node) ==="
                echo ""
                if [ "$is_ca_server" = true ]; then
                    echo "CA Server: https://${hosts[1]}:8888"
                fi
                echo "etcd endpoint: https://${hosts[$this_node]}:2379"
                
                exit $EXIT_SUCCESS
            else
                echo "Attempt $attempt failed."
                if [ $attempt -lt $max_attempts ]; then
                    echo "Retrying..."
                    sleep 2
                fi
            fi
            
            ((attempt++))
        done
        
        echo ""
        echo "✗ etcd container failed to start after $max_attempts attempts."
        show_container_status
        echo ""
        if prompt_yes_no "Run TLS setup again?"; then
            run_etcd_tls_setup
        else
            exit $EXIT_CONTAINER_FAILED
        fi
    else
        echo ""
        echo "=== TLS Setup Complete (container not started) ==="
        echo ""
        echo "To start the etcd container later:"
        echo "  docker compose -f docker-compose.tls.yml up -d"
        exit $EXIT_USER_ABORT
    fi
}

# Function to handle reset
handle_reset() {
    echo ""
    if ! prompt_yes_no "Are you sure you want to reset the etcd database? This will delete all data."; then
        echo "Reset cancelled."
        exit $EXIT_USER_ABORT
    fi
    
    stop_container
    remove_container
    
    echo ""
    if prompt_yes_no "Create a new etcd database?"; then
        run_etcd_setup
    else
        echo "Exiting without creating new database."
        exit $EXIT_USER_ABORT
    fi
}

# Main script logic
echo "==============================="
echo "  etcd Docker Compose Manager"
echo "==============================="

# Check if docker is available
if ! command -v docker &> /dev/null; then
    echo "Error: docker is not installed or not in PATH"
    exit $EXIT_SETUP_FAILED
fi

# Check if user has permission to run docker
if ! docker info &> /dev/null; then
    echo "Error: Cannot connect to Docker daemon."
    echo "Please run this script with sudo or add your user to the docker group."
    exit $EXIT_SETUP_FAILED
fi

# Check container state
container_state=$(get_container_state)

if [ "$container_state" != "not_found" ]; then
    # Container exists (running or stopped)
    show_container_status
    
    echo "Existing etcd container detected."
    echo ""
    echo "Options:"
    echo "1) Reset etcd database"
    echo "2) Exit"
    echo ""
    
    while true; do
        read -rp "Choose an option [1-2]: " choice
        case "$choice" in
            1)
                handle_reset
                break
                ;;
            2)
                echo "Exiting."
                exit $EXIT_SUCCESS
                ;;
            *)
                echo "Please enter 1 or 2."
                ;;
        esac
    done
else
    # No container found
    echo ""
    echo "No etcd container detected."
    echo ""
    echo "Options:"
    echo "1) Set up a new etcd cluster (no encryption)"
    echo "2) Set up a new etcd cluster with TLS encryption"
    echo "3) Exit"
    echo ""
    
    while true; do
        read -rp "Choose an option [1-3]: " choice
        case "$choice" in
            1)
                run_etcd_setup
                break
                ;;
            2)
                run_etcd_tls_setup
                break
                ;;
            3)
                echo "Exiting."
                exit $EXIT_SUCCESS
                ;;
            *)
                echo "Please enter 1, 2, or 3."
                ;;
        esac
    done
fi
